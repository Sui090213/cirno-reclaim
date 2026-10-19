/*
 * cirno_pageout.c - 把目标进程的私有匿名页换出到 zram / swap
 *
 * 原理：pidfd_open(2) + process_madvise(2) + MADV_PAGEOUT
 *   1. 打开目标进程的 pidfd（需要 CAP_SYS_PTRACE，root 有）；
 *   2. 解析 /proc/<pid>/smaps，只挑可写、私有、有常驻匿名页的映射；
 *   3. 按「常驻匿名页」分配预算，按 1MB 分块提交 MADV_PAGEOUT；
 *   4. 用 VmSwap 前后差值报告真正换出的字节数。
 *
 * 为什么按常驻匿名页算预算、按 VmSwap 报结果：
 *   process_madvise 的返回值是「建议过的地址范围长度」，不是实际换出量。
 *   映射里没有常驻的部分、没有 swap 时，它照样返回整段长度。
 *   早先版本用返回值记账，导致 --max-mb 形同虚设（一次换出远超预算），
 *   没有 swap 的机器上也会报告几百 MB 的「换出」。
 *
 * 安全边界：
 *   - 只处理匿名页（Anonymous > 0），不碰文件映射的代码/资源；
 *   - 跳过 stack / vdso / vvar / GPU / dalvik-jit / /dev/ / /system/ / /apex/；
 *   - 不结束进程、不发信号，进程随时可以把页换回来。
 *
 * 用法：
 *   cirno_pageout --probe                 # 探测内核是否支持，0 = 支持
 *   cirno_pageout --pid <pid> --max-mb 64 # 换出，最多 64MB，输出实际换出的字节数
 *   cirno_pageout --pid <pid> --include-art
 *                                         # 连 ART 堆一起换出（只用于已冻结的进程，
 *                                         # 与 Android 对缓存进程做的 full compaction 一致）
 *   cirno_pageout --pid <pid> --list      # 只看候选映射
 *
 * 构建（aarch64 静态）：
 *   zig cc -target aarch64-linux-musl -static -Os -s -o cirno_pageout cirno_pageout.c
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif

#ifndef SYS_pidfd_open
#ifdef __NR_pidfd_open
#define SYS_pidfd_open __NR_pidfd_open
#else
#define SYS_pidfd_open 434
#endif
#endif

#ifndef SYS_process_madvise
#ifdef __NR_process_madvise
#define SYS_process_madvise __NR_process_madvise
#else
#define SYS_process_madvise 440
#endif
#endif

#define CHUNK_BYTES (1024 * 1024)   /* 每个 iovec 1MB */
#define MAX_BATCH   256             /* 每次 syscall 最多 256 个 iovec */

struct range {
    unsigned long start;
    unsigned long end;
    unsigned long long anon;        /* 常驻匿名页字节数 */
};

static const char *skip_paths[] = {
    "/dev/", "/system/", "/apex/", "/vendor/", "/product/", "/odm/",
    "/data/dalvik-cache/", "/data/app/", "/data/misc/", "/memfd:",
    "[stack", "[vvar", "[vdso", "[vectors", "[vsyscall",
    "[anon:dalvik", "[anon:jit", NULL
};

/* 运行中的进程换出 ART 堆会在下次 GC 时整片换回来，所以默认跳过；
 * 冻结的进程不跑 GC，可以放开 */
static int include_art = 0;

static int path_skipped(const char *path)
{
    int i;
    if (path == NULL || path[0] == '\0')
        return 0;

    if (include_art && strncmp(path, "[anon:dalvik", 12) == 0)
        return 0;

    for (i = 0; skip_paths[i] != NULL; i++) {
        if (strncmp(path, skip_paths[i], strlen(skip_paths[i])) == 0)
            return 1;
    }
    /* 允许 [heap] 和 [anon:*] 这类匿名映射 */
    if (path[0] == '[')
        return 0;
    /* 有真实路径名的映射一律跳过（代码、资源、GPU buffer 等） */
    return 1;
}

static int push_range(struct range **arr, size_t *n, size_t *alloc,
                      unsigned long start, unsigned long end,
                      unsigned long long anon)
{
    if (*n == *alloc) {
        size_t nalloc = *alloc ? *alloc * 2 : 64;
        struct range *tmp = realloc(*arr, nalloc * sizeof(**arr));
        if (tmp == NULL)
            return -1;
        *arr = tmp;
        *alloc = nalloc;
    }
    (*arr)[*n].start = start;
    (*arr)[*n].end = end;
    (*arr)[*n].anon = anon;
    (*n)++;
    return 0;
}

static int collect_ranges(pid_t pid, struct range **out, size_t *count)
{
    char path[64];
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    FILE *fp;
    size_t n = 0, alloc = 0;
    struct range *arr = NULL;

    unsigned long cur_start = 0, cur_end = 0;
    unsigned long long cur_anon = 0;
    int cur_ok = 0;
    char cur_path[512];

    snprintf(path, sizeof(path), "/proc/%d/smaps", (int)pid);
    fp = fopen(path, "re");
    if (fp == NULL)
        return -1;

    cur_path[0] = '\0';

    while ((len = getline(&line, &cap, fp)) > 0) {
        unsigned long s, e;
        char perms[8];

        if (sscanf(line, "%lx-%lx %7s", &s, &e, perms) == 3) {
            /* 老内核没有 VmFlags 行：上一个 VMA 在这里提交 */
            if (cur_ok && cur_anon > 0 && cur_end > cur_start) {
                if (push_range(&arr, &n, &alloc, cur_start, cur_end, cur_anon) != 0) {
                    free(arr);
                    free(line);
                    fclose(fp);
                    return -1;
                }
            }
            cur_start = s;
            cur_end = e;
            cur_ok = (perms[0] == 'r' && perms[1] == 'w' && perms[3] == 'p');
            cur_anon = 0;
            cur_path[0] = '\0';

            /* 截取可选的路径名 */
            {
                char *p = strchr(line, '/');
                char *b = strchr(line, '[');
                char *src = NULL;
                if (p != NULL && (b == NULL || p < b))
                    src = p;
                else if (b != NULL)
                    src = b;
                if (src != NULL) {
                    size_t l = strlen(src);
                    if (l >= sizeof(cur_path))
                        l = sizeof(cur_path) - 1;
                    memcpy(cur_path, src, l);
                    cur_path[l] = '\0';
                    if (l > 0 && cur_path[l - 1] == '\n')
                        cur_path[l - 1] = '\0';
                }
            }

            if (cur_ok && path_skipped(cur_path))
                cur_ok = 0;
            continue;
        }

        if (!cur_ok)
            continue;

        if (strncmp(line, "Anonymous:", 10) == 0) {
            cur_anon = strtoull(line + 10, NULL, 10) * 1024ULL;
        } else if (strncmp(line, "VmFlags:", 8) == 0) {
            /* VmFlags 是每个 VMA 的最后一行 */
            if (cur_anon > 0 && cur_end > cur_start) {
                if (push_range(&arr, &n, &alloc, cur_start, cur_end, cur_anon) != 0) {
                    free(arr);
                    free(line);
                    fclose(fp);
                    return -1;
                }
            }
            cur_ok = 0;
        }
    }

    if (cur_ok && cur_anon > 0 && cur_end > cur_start) {
        if (push_range(&arr, &n, &alloc, cur_start, cur_end, cur_anon) != 0) {
            free(arr);
            free(line);
            fclose(fp);
            return -1;
        }
    }

    free(line);
    fclose(fp);

    *out = arr;
    *count = n;
    return 0;
}

/* /proc/<pid>/status 里的 VmSwap（KB）；读不到返回 -1 */
static long long read_vmswap_kb(pid_t pid)
{
    char path[64];
    char buf[256];
    FILE *fp;
    long long kb = -1;

    snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
    fp = fopen(path, "re");
    if (fp == NULL)
        return -1;
    while (fgets(buf, sizeof(buf), fp) != NULL) {
        if (strncmp(buf, "VmSwap:", 7) == 0) {
            kb = strtoll(buf + 7, NULL, 10);
            break;
        }
    }
    fclose(fp);
    return kb;
}

static long one_call(int pidfd, struct iovec *iov, int cnt)
{
    long ret;
    do {
        ret = syscall(SYS_process_madvise, pidfd, iov, (unsigned long)cnt, MADV_PAGEOUT, 0);
    } while (ret < 0 && errno == EINTR);
    return ret;
}

static int probe(void)
{
    int fd;
    void *page;
    struct iovec iov;
    long ret;
    int err;

    fd = (int)syscall(SYS_pidfd_open, (pid_t)getpid(), 0);
    if (fd < 0) {
        fprintf(stderr, "probe: pidfd_open unsupported (errno=%d)\n", errno);
        return 2;
    }

    page = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) {
        close(fd);
        fprintf(stderr, "probe: mmap failed\n");
        return 1;
    }
    *(volatile char *)page = 1;

    iov.iov_base = page;
    iov.iov_len = 4096;
    ret = one_call(fd, &iov, 1);
    err = errno;

    munmap(page, 4096);
    close(fd);

    if (ret >= 0) {
        printf("supported\n");
        return 0;
    }
    if (err == ENOSYS) {
        fprintf(stderr, "probe: process_madvise unsupported (ENOSYS)\n");
        return 2;
    }
    if (err == EPERM || err == EACCES) {
        fprintf(stderr, "probe: process_madvise denied (errno=%d)\n", err);
        return 3;
    }
    fprintf(stderr, "probe: process_madvise failed (errno=%d)\n", err);
    return 4;
}

int main(int argc, char **argv)
{
    long pid = -1;
    long max_mb = 128;
    int list_only = 0;
    int i;
    int pidfd;
    struct range *ranges = NULL;
    size_t count = 0;
    size_t k;
    unsigned long long budget;
    unsigned long long planned = 0;
    unsigned long page = (unsigned long)sysconf(_SC_PAGESIZE);
    long long swap_before, swap_after;

    if (argc < 2) {
        fprintf(stderr, "usage: %s --probe | --pid <pid> [--max-mb N] [--include-art] [--list]\n", argv[0]);
        return 64;
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--probe") == 0) {
            return probe();
        } else if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            pid = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--max-mb") == 0 && i + 1 < argc) {
            max_mb = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--list") == 0) {
            list_only = 1;
        } else if (strcmp(argv[i], "--include-art") == 0) {
            include_art = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("usage: %s --probe | --pid <pid> [--max-mb N] [--include-art] [--list]\n", argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown arg: %s\n", argv[i]);
            return 64;
        }
    }

    if (pid <= 0) {
        fprintf(stderr, "missing --pid\n");
        return 64;
    }
    if (max_mb <= 0)
        max_mb = 512;
    if (page == 0 || page == (unsigned long)-1)
        page = 4096;

    if (collect_ranges((pid_t)pid, &ranges, &count) != 0) {
        fprintf(stderr, "cannot read /proc/%ld/smaps (errno=%d)\n", pid, errno);
        return 3;
    }

    if (count == 0) {
        free(ranges);
        printf("0\n");
        return 0;
    }

    if (list_only) {
        for (k = 0; k < count; k++)
            printf("%lx-%lx  %lu KB  anon %llu KB\n", ranges[k].start, ranges[k].end,
                   (ranges[k].end - ranges[k].start) / 1024, ranges[k].anon / 1024);
        free(ranges);
        return 0;
    }

    pidfd = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
    if (pidfd < 0) {
        free(ranges);
        fprintf(stderr, "pidfd_open failed (errno=%d)\n", errno);
        return 2;
    }

    budget = (unsigned long long)max_mb * 1024ULL * 1024ULL;
    swap_before = read_vmswap_kb((pid_t)pid);

    {
        struct iovec iov[MAX_BATCH];
        int cnt = 0;

        for (k = 0; k < count && planned < budget; k++) {
            unsigned long pos = ranges[k].start;
            unsigned long end = ranges[k].end;
            unsigned long long left = budget - planned;

            /* 这段的常驻匿名页超出剩余预算：只换出按比例截取的前一段 */
            if (ranges[k].anon > left) {
                unsigned long long span = (unsigned long long)(end - pos) * left / ranges[k].anon;
                span = (span + page - 1) / page * page;
                if (span < page)
                    span = page;
                if (span < (unsigned long long)(end - pos))
                    end = pos + (unsigned long)span;
                planned = budget;
            } else {
                planned += ranges[k].anon;
            }

            while (pos < end) {
                unsigned long len = end - pos;
                if (len > CHUNK_BYTES)
                    len = CHUNK_BYTES;

                iov[cnt].iov_base = (void *)pos;
                iov[cnt].iov_len = len;
                cnt++;
                pos += len;

                if (cnt == MAX_BATCH) {
                    long ret = one_call(pidfd, iov, cnt);
                    if (ret < 0 && errno == ENOSYS) {
                        free(ranges);
                        close(pidfd);
                        fprintf(stderr, "process_madvise unsupported\n");
                        return 2;
                    }
                    cnt = 0;
                }
            }
        }

        if (cnt > 0)
            one_call(pidfd, iov, cnt);
    }

    free(ranges);
    close(pidfd);

    swap_after = read_vmswap_kb((pid_t)pid);
    if (swap_before >= 0 && swap_after > swap_before)
        printf("%llu\n", (unsigned long long)(swap_after - swap_before) * 1024ULL);
    else
        printf("0\n");
    return 0;
}
