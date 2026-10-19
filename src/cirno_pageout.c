/*
 * cirno_pageout.c - 把目标进程的私有匿名页换出到 zram / swap
 *
 * 原理：pidfd_open(2) + process_madvise(2) + MADV_PAGEOUT
 *   1. 打开目标进程的 pidfd（需要 CAP_SYS_PTRACE，root 有）；
 *   2. 解析 /proc/<pid>/smaps，只挑可写、私有的匿名映射；
 *   3. 按 1MB 分块提交 MADV_PAGEOUT，避免单次 iovec 过大被内核拒绝。
 *
 * 安全边界：
 *   - 只处理匿名页（Anonymous > 0），不碰文件映射的代码/资源；
 *   - 跳过 stack / vdso / vvar / GPU / dalvik-jit / /dev/ / /system/ / /apex/；
 *   - 不结束进程、不发信号，进程随时可以把页换回来。
 *
 * 用法：
 *   cirno_pageout --probe                 # 探测内核是否支持，0 = 支持
 *   cirno_pageout --pid <pid> --max-mb 64 # 换出，最多 64MB，输出实际字节数
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
};

static const char *skip_paths[] = {
    "/dev/", "/system/", "/apex/", "/vendor/", "/product/", "/odm/",
    "/data/dalvik-cache/", "/data/app/", "/data/misc/", "/memfd:",
    "[stack", "[vvar", "[vdso", "[vectors", "[vsyscall",
    "[anon:dalvik", "[anon:jit", NULL
};

static int path_skipped(const char *path)
{
    int i;
    if (path == NULL || path[0] == '\0')
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
    int cur_ok = 0, cur_anon = 0;
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
            /* 新的 VMA 头：先提交上一条 */
            if (cur_ok && cur_anon > 0) {
                if (cur_end > cur_start) {
                    if (n == alloc) {
                        size_t nalloc = alloc ? alloc * 2 : 64;
                        struct range *tmp = realloc(arr, nalloc * sizeof(*arr));
                        if (tmp == NULL) {
                            free(arr);
                            free(line);
                            fclose(fp);
                            return -1;
                        }
                        arr = tmp;
                        alloc = nalloc;
                    }
                    arr[n].start = cur_start;
                    arr[n].end = cur_end;
                    n++;
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
                if (p != NULL && (b == NULL || p < b)) {
                    size_t l = strlen(p);
                    if (l >= sizeof(cur_path))
                        l = sizeof(cur_path) - 1;
                    memcpy(cur_path, p, l);
                    cur_path[l] = '\0';
                    if (l > 0 && cur_path[l - 1] == '\n')
                        cur_path[l - 1] = '\0';
                } else if (b != NULL) {
                    size_t l = strlen(b);
                    if (l >= sizeof(cur_path))
                        l = sizeof(cur_path) - 1;
                    memcpy(cur_path, b, l);
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
            unsigned long kb = strtoul(line + 10, NULL, 10);
            if (kb > 0)
                cur_anon = 1;
        } else if (strncmp(line, "VmFlags:", 8) == 0) {
            if (cur_anon > 0) {
                if (n == alloc) {
                    size_t nalloc = alloc ? alloc * 2 : 64;
                    struct range *tmp = realloc(arr, nalloc * sizeof(*arr));
                    if (tmp == NULL) {
                        free(arr);
                        free(line);
                        fclose(fp);
                        return -1;
                    }
                    arr = tmp;
                    alloc = nalloc;
                }
                arr[n].start = cur_start;
                arr[n].end = cur_end;
                n++;
                cur_anon = 0;
                cur_ok = 0;
            }
        }
    }

    free(line);
    fclose(fp);

    *out = arr;
    *count = n;
    return 0;
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
    unsigned long long budget;
    unsigned long long done = 0;

    if (argc < 2) {
        fprintf(stderr, "usage: %s --probe | --pid <pid> [--max-mb N] [--list]\n", argv[0]);
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
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("usage: %s --probe | --pid <pid> [--max-mb N] [--list]\n", argv[0]);
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
        size_t k;
        for (k = 0; k < count; k++)
            printf("%lx-%lx  %lu KB\n", ranges[k].start, ranges[k].end,
                   (ranges[k].end - ranges[k].start) / 1024);
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

    {
        struct iovec iov[MAX_BATCH];
        int cnt = 0;

        for (i = 0; (size_t)i < count && done < budget; i++) {
            unsigned long pos = ranges[i].start;
            unsigned long end = ranges[i].end;

            while (pos < end && done < budget) {
                unsigned long len = end - pos;
                if (len > CHUNK_BYTES)
                    len = CHUNK_BYTES;
                if ((unsigned long long)len > budget - done)
                    len = (unsigned long)(budget - done);

                iov[cnt].iov_base = (void *)pos;
                iov[cnt].iov_len = len;
                cnt++;
                pos += len;

                if (cnt == MAX_BATCH) {
                    long ret = one_call(pidfd, iov, cnt);
                    if (ret > 0) {
                        done += (unsigned long long)ret;
                    } else if (ret < 0 && errno == ENOSYS) {
                        free(ranges);
                        close(pidfd);
                        fprintf(stderr, "process_madvise unsupported\n");
                        return 2;
                    }
                    cnt = 0;
                }
            }
        }

        if (cnt > 0) {
            long ret = one_call(pidfd, iov, cnt);
            if (ret > 0)
                done += (unsigned long long)ret;
        }
    }

    free(ranges);
    close(pidfd);

    printf("%llu\n", done);
    return 0;
}
