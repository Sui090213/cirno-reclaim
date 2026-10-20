// ============================================================================
//  Cirno Reclaim Hybrid - src/cirno_daemon.cpp
//  C++ 守护进程：负责调度、心跳、子进程回收与限时，具体回收逻辑仍交给 shell 引擎。
//
//  为什么用 C++ 做守护：
//    - 不依赖 shell 的 sleep 循环，心跳/超时用单调时钟，不会被系统时间跳变影响；
//    - 子进程有硬超时，dumpsys 卡住时不会拖死整个守护；
//    - 单文件静态二进制（zig c++ 交叉编译），不依赖 Android 的 libc++。
//
//  v2.3.0 低功耗重写（重要）：
//    旧版每秒 nanosleep 轮询 + 固定周期无条件 fork 回收脚本，实测功耗偏高。
//    现在的做法：
//      1. 事件驱动睡眠：算出下一个事件时间，睡到那个点，空闲时不再 1 秒一醒；
//      2. 内存压力门控：自己读 /proc/meminfo 与 /proc/pressure/memory，
//         只有真的紧张才 fork reclaim.sh / app_relief.sh，空闲时一次也不 fork；
//      3. boot_delay 按「系统 uptime」判断，开机只等一次，被 watchdog 拉起不会重复等；
//      4. 心跳/日志写入降到 45s 数量级，不再每次 spawn 都写一行；
//      5. 长时间不紧张时自动把探测周期放宽，进一步减少唤醒。
//
//  设计原则：
//    - 只读配置、只调用固定路径的脚本，不 eval、不拼命令；
//    - 任何脚本缺失/失败都只记日志并继续，不退出；
//    - 单实例用 mkdir 原子锁 + pid 命令行校验。
// ============================================================================

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <string>
#include <vector>

namespace {

const char *kDataDir = "/data/adb/cirno_reclaim";
const char *kStateDir = "/data/adb/cirno_reclaim/state";
const char *kLogDir = "/data/adb/modules/cirno_reclaim/log";
const char *kLogFile = "/data/adb/modules/cirno_reclaim/log/reclaim.log";
const char *kConfFile = "/data/adb/cirno_reclaim/config.conf";
const char *kPidFile = "/data/adb/cirno_reclaim/daemon.pid";
const char *kLockDir = "/data/adb/cirno_reclaim/lock.daemon";
const char *kHeartbeat = "/data/adb/cirno_reclaim/state/heartbeat";
// 轻量运行统计（唤醒次数 / 探测次数 / 自身 CPU 时间），供 --status 与 WebUI 验证功耗
const char *kStatsFile = "/data/adb/cirno_reclaim/state/cpp.stats";
const char *kReclaimScript = "/data/adb/modules/cirno_reclaim/bin/reclaim.sh";
const char *kReliefScript = "/data/adb/modules/cirno_reclaim/bin/app_relief.sh";
const char *kVmScript = "/data/adb/modules/cirno_reclaim/bin/vm_tune.sh";

volatile sig_atomic_t g_stop = 0;
volatile sig_atomic_t g_reload = 0;
bool g_foreground = false;

// 运行统计（只用于展示/验证功耗，不上报任何地方）
unsigned long g_wakeups = 0;
unsigned long g_probes = 0;

void on_signal(int sig) {
  if (sig == SIGHUP) {
    g_reload = 1;
  } else {
    g_stop = 1;
  }
}

double steady_seconds() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// 系统已开机多少秒（/proc/uptime 第一列）
double uptime_seconds() {
  std::string text;
  int fd = open("/proc/uptime", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 0.0;
  char buf[128];
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0) return 0.0;
  buf[n] = '\0';
  return strtod(buf, nullptr);
}

bool file_exists(const char *p) {
  struct stat st;
  return stat(p, &st) == 0;
}

long file_size(const char *p) {
  struct stat st;
  if (stat(p, &st) != 0) return -1;
  return (long)st.st_size;
}

long file_mtime(const char *p) {
  struct stat st;
  if (stat(p, &st) != 0) return -1;
  return (long)st.st_mtime;
}

bool read_file(const char *p, std::string &out) {
  int fd = open(p, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  char buf[4096];
  ssize_t n;
  out.clear();
  while ((n = read(fd, buf, sizeof(buf))) > 0) out.append(buf, (size_t)n);
  close(fd);
  return true;
}

bool write_file(const char *p, const std::string &data, mode_t mode) {
  int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
  if (fd < 0) return false;
  size_t off = 0;
  while (off < data.size()) {
    ssize_t n = write(fd, data.data() + off, data.size() - off);
    if (n <= 0) {
      close(fd);
      return false;
    }
    off += (size_t)n;
  }
  close(fd);
  return true;
}

void mkdir_ok(const char *p, mode_t mode) {
  if (mkdir(p, mode) != 0 && errno != EEXIST) {
    // 父目录不存在等错误只记一次，由调用方继续
  }
}

std::string now_text() {
  time_t t = time(nullptr);
  struct tm tmv;
  localtime_r(&t, &tmv);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
  return std::string(buf);
}

void log_line(const char *fmt, ...) {
  char msg[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);

  std::string line = now_text() + " " + msg + "\n";
  int fd = open(kLogFile, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd >= 0) {
    ssize_t ignored = write(fd, line.data(), line.size());
    (void)ignored;
    close(fd);
  }
  if (g_foreground) {
    fputs(line.c_str(), stderr);
  }
}

// ---------------------------------------------------------------- 配置
struct Config {
  int enable = 1;
  int interval = 20;
  int boot_delay = 90;
  int app_reclaim = 1;
  int app_reclaim_interval = 60;
  int relief_gate = 1;
  int vm_tune = 1;
  int keepalive = 1;
  int oom_protect = 1;
  int high_pss_mb = 600;
  int high_pss_interval = 90;
  int log_max_kb = 512;
  int heartbeat_sec = 45;
  int heartbeat_timeout = 180;
  int cooldown_sec = 60;
  int mem_low_mb = 800;
  int mem_low_pct = 8;
  int psi_enable = 1;
  int psi_some_avg10 = 25;
  int loaded_lines = 0;
  int bad_lines = 0;
  std::string device_profile = "generic";
};

bool parse_int(const std::string &v, int &out) {
  if (v.empty()) return false;
  char *end = nullptr;
  errno = 0;
  long n = strtol(v.c_str(), &end, 10);
  if (errno != 0 || end == nullptr || *end != '\0') return false;
  if (n < 0 || n > 1000000) return false;
  out = (int)n;
  return true;
}

std::string trim(const std::string &s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos) return "";
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

// 只认自己需要的键；不认识的键直接忽略（shell 那边有完整校验）
Config load_config() {
  Config c;
  std::string text;
  if (!read_file(kConfFile, text)) {
    log_line("WARN cpp-daemon: cannot read config, using defaults");
    return c;
  }

  size_t pos = 0;
  while (pos <= text.size()) {
    size_t nl = text.find('\n', pos);
    if (nl == std::string::npos) nl = text.size();
    std::string line = trim(text.substr(pos, nl - pos));
    pos = nl + 1;

    if (line.empty() || line[0] == '#') continue;
    size_t eq = line.find('=');
    if (eq == std::string::npos) {
      c.bad_lines++;
      continue;
    }
    std::string key = trim(line.substr(0, eq));
    std::string val = trim(line.substr(eq + 1));

    // 行内注释：只认空白 + #
    size_t hash = val.find('#');
    if (hash != std::string::npos) {
      if (hash == 0 || (val[hash - 1] != ' ' && val[hash - 1] != '\t')) {
        c.bad_lines++;
        continue;
      }
      val = trim(val.substr(0, hash));
    }
    if (val.size() >= 2 && ((val.front() == '\'' && val.back() == '\'') ||
                            (val.front() == '"' && val.back() == '"'))) {
      val = val.substr(1, val.size() - 2);
    }
    if (key.empty()) {
      c.bad_lines++;
      continue;
    }

    int n = 0;
    bool numeric = parse_int(val, n);
    if (key == "enable" && numeric) c.enable = n;
    else if (key == "interval" && numeric) c.interval = n;
    else if (key == "boot_delay" && numeric) c.boot_delay = n;
    else if (key == "app_reclaim" && numeric) c.app_reclaim = n;
    else if (key == "app_reclaim_interval" && numeric) c.app_reclaim_interval = n;
    else if (key == "relief_gate" && numeric) c.relief_gate = n;
    else if (key == "vm_tune" && numeric) c.vm_tune = n;
    else if (key == "keepalive" && numeric) c.keepalive = n;
    else if (key == "oom_protect" && numeric) c.oom_protect = n;
    else if (key == "high_pss_mb" && numeric) c.high_pss_mb = n;
    else if (key == "high_pss_interval" && numeric) c.high_pss_interval = n;
    else if (key == "log_max_kb" && numeric) c.log_max_kb = n;
    else if (key == "heartbeat_sec" && numeric) c.heartbeat_sec = n;
    else if (key == "heartbeat_timeout" && numeric) c.heartbeat_timeout = n;
    else if (key == "cooldown_sec" && numeric) c.cooldown_sec = n;
    else if (key == "mem_low_mb" && numeric) c.mem_low_mb = n;
    else if (key == "mem_low_pct" && numeric) c.mem_low_pct = n;
    else if (key == "psi_enable" && numeric) c.psi_enable = n;
    else if (key == "psi_some_avg10" && numeric) c.psi_some_avg10 = n;
    else if (key == "device_profile") {
      if (val == "hyperos" || val == "coloros" || val == "generic") c.device_profile = val;
    }
    c.loaded_lines++;
  }

  // 和 shell 的 cfg_clamp 保持一致
  if (c.interval < 5) c.interval = 5;
  if (c.interval > 300) c.interval = 300;
  if (c.app_reclaim_interval < 10) c.app_reclaim_interval = 10;
  if (c.high_pss_interval < 30) c.high_pss_interval = 30;
  if (c.log_max_kb < 32) c.log_max_kb = 32;
  if (c.boot_delay < 0) c.boot_delay = 0;
  if (c.boot_delay > 600) c.boot_delay = 600;
  if (c.mem_low_pct < 0) c.mem_low_pct = 0;
  if (c.mem_low_pct > 90) c.mem_low_pct = 90;
  if (c.psi_some_avg10 < 0) c.psi_some_avg10 = 0;
  if (c.heartbeat_timeout < 60) c.heartbeat_timeout = 60;
  if (c.heartbeat_timeout > 1800) c.heartbeat_timeout = 1800;
  if (c.heartbeat_sec < 10) c.heartbeat_sec = 10;
  if (c.heartbeat_sec > c.heartbeat_timeout / 2 && c.heartbeat_timeout / 2 >= 10) {
    c.heartbeat_sec = c.heartbeat_timeout / 2;
  }
  if (c.heartbeat_sec > 120) c.heartbeat_sec = 120;
  if (c.bad_lines > 0) {
    log_line("WARN cpp-daemon: %d invalid config line(s) ignored", c.bad_lines);
  }
  return c;
}

// ---------------------------------------------------------------- 内存压力
struct MemInfo {
  long total_mb = 0;
  long avail_mb = 0;
};

// 一次读 /proc/meminfo，不 fork，开销可以忽略
bool read_meminfo(MemInfo &out) {
  std::string text;
  if (!read_file("/proc/meminfo", text)) return false;
  long total_kb = -1;
  long avail_kb = -1;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t nl = text.find('\n', pos);
    if (nl == std::string::npos) nl = text.size();
    size_t len = nl - pos;
    if (len > 9 && text.compare(pos, 9, "MemTotal:") == 0) {
      total_kb = atol(text.c_str() + pos + 9);
    } else if (len > 13 && text.compare(pos, 13, "MemAvailable:") == 0) {
      avail_kb = atol(text.c_str() + pos + 13);
    }
    pos = nl + 1;
  }
  if (total_kb <= 0 || avail_kb < 0) return false;
  out.total_mb = total_kb / 1024;
  out.avail_mb = avail_kb / 1024;
  return true;
}

// /proc/pressure/memory 的 some avg10；内核不支持时返回 -1
double read_psi_avg10() {
  std::string text;
  if (!read_file("/proc/pressure/memory", text)) return -1.0;
  size_t some = text.find("some ");
  if (some == std::string::npos) return -1.0;
  size_t a = text.find("avg10=", some);
  if (a == std::string::npos) return -1.0;
  return strtod(text.c_str() + a + 6, nullptr);
}

long mem_low_threshold_mb(const Config &c, long total_mb) {
  long low = c.mem_low_mb;
  if (c.mem_low_pct > 0) {
    long p = total_mb * c.mem_low_pct / 100;
    if (p > low) low = p;
  }
  return low;
}

// 与 shell 的 mem_pressure_now 完全一致：可用内存低于阈值，或 PSI 超过设定值
bool pressure_tight(const Config &c, const MemInfo &m, double psi) {
  if (m.avail_mb < mem_low_threshold_mb(c, m.total_mb)) return true;
  if (c.psi_enable && psi >= 0.0 && psi > (double)c.psi_some_avg10) return true;
  return false;
}

// ---------------------------------------------------------------- 进程
bool pid_alive(pid_t pid) {
  if (pid <= 0) return false;
  return kill(pid, 0) == 0;
}

bool cmdline_has(pid_t pid, const char *needle) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/cmdline", (int)pid);
  std::string cmd;
  if (!read_file(path, cmd)) return false;
  for (size_t i = 0; i < cmd.size(); i++) {
    if (cmd[i] == '\0') cmd[i] = ' ';
  }
  return cmd.find(needle) != std::string::npos;
}

std::string read_pid_file(const char *path) {
  std::string s;
  if (!read_file(path, s)) return "";
  return trim(s);
}

struct Child {
  pid_t pid = 0;
  std::string name;
  double deadline = 0;
};

std::vector<Child> g_children;
std::string g_missing_logged;

bool child_running(const char *name) {
  for (size_t i = 0; i < g_children.size(); i++) {
    if (g_children[i].name == name) return true;
  }
  return false;
}

void spawn_child(const char *name, const char *script, const char *arg1, const char *arg2,
                 int timeout_sec) {
  if (!file_exists(script)) {
    if (g_missing_logged.find(script) == std::string::npos) {
      log_line("WARN cpp-daemon: missing %s, skip %s", script, name);
      g_missing_logged += script;
      g_missing_logged += ';';
    }
    return;
  }
  pid_t pid = fork();
  if (pid < 0) {
    log_line("WARN cpp-daemon: fork failed for %s (errno=%d)", name, errno);
    return;
  }
  if (pid == 0) {
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
      dup2(devnull, 0);
      dup2(devnull, 1);
      dup2(devnull, 2);
      if (devnull > 2) close(devnull);
    }
    setsid();
    if (arg1 != nullptr && arg2 != nullptr) {
      execl("/system/bin/sh", "sh", script, arg1, arg2, (char *)nullptr);
    } else if (arg1 != nullptr) {
      execl("/system/bin/sh", "sh", script, arg1, (char *)nullptr);
    } else {
      execl("/system/bin/sh", "sh", script, (char *)nullptr);
    }
    _exit(127);
  }

  Child c;
  c.pid = pid;
  c.name = name;
  c.deadline = steady_seconds() + (double)timeout_sec;
  g_children.push_back(c);
  // 不再每次 spawn 都写日志：脚本自己会记录真正做了什么，这里只在调试时看
}

void reap_children() {
  double now = steady_seconds();
  for (size_t i = 0; i < g_children.size();) {
    int status = 0;
    pid_t r = waitpid(g_children[i].pid, &status, WNOHANG);
    if (r == g_children[i].pid) {
      int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
      if (WIFSIGNALED(status)) {
        log_line("cpp-daemon: %s killed by signal %d", g_children[i].name.c_str(), WTERMSIG(status));
      } else if (code != 0) {
        log_line("cpp-daemon: %s exit %d", g_children[i].name.c_str(), code);
      }
      g_children.erase(g_children.begin() + (long)i);
      continue;
    }
    if (r == 0 && now > g_children[i].deadline) {
      log_line("cpp-daemon: %s timeout, kill pid=%d", g_children[i].name.c_str(), (int)g_children[i].pid);
      kill(g_children[i].pid, SIGKILL);
      g_children[i].deadline = now + 5;  // 下一轮 reap 掉
    }
    i++;
  }
}

// ---------------------------------------------------------------- 锁 / 心跳
bool acquire_lock() {
  std::string lock_pid = std::string(kLockDir) + "/pid";
  std::string my_pid = std::to_string((long)getpid());

  if (mkdir(kLockDir, 0700) == 0) {
    write_file(lock_pid.c_str(), my_pid, 0600);
    return true;
  }

  std::string owner_text = read_pid_file(lock_pid.c_str());
  int owner = atoi(owner_text.c_str());
  if (owner > 0 && pid_alive((pid_t)owner) && cmdline_has((pid_t)owner, "cirno_daemon")) {
    return false;
  }

  log_line("cpp-daemon: stale lock (owner=%d), reclaiming", owner);
  unlink(lock_pid.c_str());
  rmdir(kLockDir);
  if (mkdir(kLockDir, 0700) != 0) return false;
  write_file(lock_pid.c_str(), my_pid, 0600);
  return true;
}

void release_lock() {
  std::string lock_pid = std::string(kLockDir) + "/pid";
  std::string owner = read_pid_file(lock_pid.c_str());
  if (atoi(owner.c_str()) == (int)getpid()) {
    unlink(lock_pid.c_str());
    rmdir(kLockDir);
  }
}

void write_heartbeat() {
  std::string now = std::to_string((long)time(nullptr));
  write_file(kHeartbeat, now, 0600);
}

// 和心跳同一次唤醒写一次，几十字节；--status 从这里读运行统计
void write_stats(int tight, const MemInfo &mem, bool have_mem, double run_seconds) {
  long cpu_ms = -1;
  struct rusage ru;
  if (getrusage(RUSAGE_SELF, &ru) == 0) {
    cpu_ms = ru.ru_utime.tv_sec * 1000L + ru.ru_utime.tv_usec / 1000L +
             ru.ru_stime.tv_sec * 1000L + ru.ru_stime.tv_usec / 1000L;
  }
  char buf[320];
  snprintf(buf, sizeof(buf),
           "wakeups=%lu\nprobes=%lu\ncpu_ms=%ld\ntight=%d\navail=%ld\ntotal=%ld\nuptime=%ld\n",
           g_wakeups, g_probes, cpu_ms, tight ? 1 : 0, have_mem ? mem.avail_mb : -1,
           have_mem ? mem.total_mb : -1, (long)run_seconds);
  write_file(kStatsFile, std::string(buf), 0600);
}

// 从 state/cpp.stats 读一个整数键；没有就返回默认值
long stat_value(const char *key, long dflt) {
  std::string text;
  if (!read_file(kStatsFile, text)) return dflt;
  std::string k = std::string(key) + "=";
  size_t p = text.find(k);
  if (p == std::string::npos) return dflt;
  return atol(text.c_str() + p + k.size());
}

void protect_self(const Config &c) {
  if (!c.oom_protect) return;
  int fd = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return;
  ssize_t ignored = write(fd, "-900", 4);
  (void)ignored;
  close(fd);
}

// 把自己降到最低 CPU / IO 优先级：守护只在需要时醒一下，
// 没必要和前台抢 CPU，nice 19 + IO idle 能明显降低对续航和流畅度的影响。
void lower_priority() {
  setpriority(PRIO_PROCESS, 0, 19);
#ifdef SYS_ioprio_set
  // IOPRIO_WHO_PROCESS = 1, IOPRIO_CLASS_IDLE = 3 -> (3 << 13)
  syscall(SYS_ioprio_set, 1, 0, (3 << 13));
#endif
}

void rotate_log(const Config &c) {
  long size = file_size(kLogFile);
  if (size < 0 || size <= (long)c.log_max_kb * 1024) return;
  std::string rotated = std::string(kLogFile) + ".1";
  rename(kLogFile, rotated.c_str());
  log_line("cpp-daemon: log rotated (limit %dKB)", c.log_max_kb);
}

// 和 shell 的 cooldown_sec 对齐：上次回收还没过冷却就别 fork 了，
// 否则每次都是 fork 一个 shell 进去立刻被 cooldown 拒绝，纯浪费。
// 返回距离冷却结束还有多少秒（0 = 现在就可以跑）
long reclaim_cooldown_wait(int cooldown) {
  if (cooldown <= 0) return 0;
  std::string s;
  if (!read_file("/data/adb/cirno_reclaim/state/last_run", s)) return 0;
  long last = atol(trim(s).c_str());
  if (last <= 0) return 0;
  long age = (long)time(nullptr) - last;
  if (age < 0) return 0;
  if (age >= (long)cooldown) return 0;
  return (long)cooldown - age;
}

// ---------------------------------------------------------------- 状态
int print_status() {
  Config c = load_config();
  std::string pid_text = read_pid_file(kPidFile);
  int pid = atoi(pid_text.c_str());
  bool alive = pid > 0 && pid_alive((pid_t)pid) && cmdline_has((pid_t)pid, "cirno_daemon");
  std::string hb = read_pid_file(kHeartbeat);
  long hb_age = -1;
  if (!hb.empty()) hb_age = (long)time(nullptr) - atol(hb.c_str());
  long log_size = file_size(kLogFile);

  MemInfo m;
  bool mem_ok = read_meminfo(m);
  double psi = read_psi_avg10();
  bool tight = mem_ok ? pressure_tight(c, m, psi) : true;

  printf("{");
  printf("\"ok\":1,");
  printf("\"engine\":\"cpp\",");
  printf("\"pid\":%d,", pid);
  printf("\"alive\":%d,", alive ? 1 : 0);
  printf("\"heartbeat_age\":%ld,", hb_age);
  printf("\"log_size\":%ld,", log_size);
  printf("\"config_bad_lines\":%d,", c.bad_lines);
  printf("\"interval\":%d,", c.interval);
  printf("\"app_interval\":%d,", c.app_reclaim_interval);
  printf("\"heartbeat_sec\":%d,", c.heartbeat_sec);
  printf("\"profile\":\"%s\",", c.device_profile.c_str());
  printf("\"tight\":%d,", tight ? 1 : 0);
  printf("\"avail\":%ld,", m.avail_mb);
  printf("\"total\":%ld,", m.total_mb);
  printf("\"low\":%ld,", mem_low_threshold_mb(c, m.total_mb));
  printf("\"psi\":%.2f,", psi);
  printf("\"relief_gate\":%d,", c.relief_gate);
  printf("\"wakeups\":%ld,", stat_value("wakeups", -1));
  printf("\"probes\":%ld,", stat_value("probes", -1));
  printf("\"cpu_ms\":%ld,", stat_value("cpu_ms", -1));
  printf("\"uptime\":%ld,", stat_value("uptime", -1));
  printf("\"children\":%d", (int)g_children.size());
  printf("}\n");
  return 0;
}

void usage() {
  printf("usage: cirno_daemon [--status] [--check] [--foreground] [--once]\n");
}

int check_config() {
  Config c = load_config();
  MemInfo m;
  bool mem_ok = read_meminfo(m);
  printf("config: %s\n", kConfFile);
  printf("lines: parsed=%d invalid=%d\n", c.loaded_lines, c.bad_lines);
  printf("interval=%d app_interval=%d high_pss_mb=%d heartbeat_sec=%d\n", c.interval,
         c.app_reclaim_interval, c.high_pss_mb, c.heartbeat_sec);
  printf("profile=%s relief_gate=%d boot_delay=%d\n", c.device_profile.c_str(), c.relief_gate,
         c.boot_delay);
  if (mem_ok) {
    printf("mem: total=%ldMB avail=%ldMB low=%ldMB tight=%d\n", m.total_mb, m.avail_mb,
           mem_low_threshold_mb(c, m.total_mb), pressure_tight(c, m, read_psi_avg10()) ? 1 : 0);
  } else {
    printf("mem: unreadable\n");
  }
  return c.bad_lines == 0 ? 0 : 2;
}

// 计算两次事件之间的睡眠：到下一个事件为止，空闲时最多睡 cap 秒
void sleep_until(double now, double deadline, double cap) {
  double delta = deadline - now;
  if (delta < 0.05) delta = 0.05;
  if (delta > cap) delta = cap;
  struct timespec ts;
  ts.tv_sec = (time_t)delta;
  ts.tv_nsec = (long)((delta - (double)ts.tv_sec) * 1e9);
  if (ts.tv_nsec < 0) ts.tv_nsec = 0;
  while (nanosleep(&ts, &ts) != 0 && errno == EINTR && !g_stop) {
    // 被信号打断：剩余时间已写回 ts，继续睡
  }
}

}  // namespace

int main(int argc, char **argv) {
  bool once = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--status") == 0) return print_status();
    if (strcmp(argv[i], "--check") == 0) return check_config();
    if (strcmp(argv[i], "--foreground") == 0) g_foreground = true;
    else if (strcmp(argv[i], "--once") == 0) once = true;
    else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      usage();
      return 0;
    } else {
      usage();
      return 64;
    }
  }

  mkdir_ok(kDataDir, 0700);
  mkdir_ok(kStateDir, 0700);
  mkdir_ok(kLogDir, 0755);

  Config cfg = load_config();

  if (once) {
    // 供 action.sh / 调试使用：跑一轮回收就退出
    spawn_child("reclaim", kReclaimScript, "--run", nullptr, 120);
    while (!g_children.empty()) {
      reap_children();
      struct timespec ts = {0, 200 * 1000 * 1000};
      nanosleep(&ts, nullptr);
    }
    return 0;
  }

  if (!acquire_lock()) {
    log_line("cpp-daemon: another instance is running, exit");
    return 0;
  }

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGHUP, on_signal);
  signal(SIGCHLD, SIG_DFL);

  write_file(kPidFile, std::to_string((long)getpid()), 0600);
  protect_self(cfg);
  lower_priority();

  double now = steady_seconds();
  // boot_delay 按系统 uptime 算：开机只等一次，被 watchdog 拉起时 uptime 早就够了，不会重复等
  double up = uptime_seconds();
  double ready = now;
  if (cfg.boot_delay > 0 && up < (double)cfg.boot_delay) {
    ready = now + ((double)cfg.boot_delay - up);
  }

  log_line("cpp-daemon start pid=%d uptime=%.0fs ready_in=%.0fs interval=%d app=%d hb=%d profile=%s",
           (int)getpid(), up, ready - now, cfg.interval, cfg.app_reclaim_interval,
           cfg.heartbeat_sec, cfg.device_profile.c_str());

  double next_hb = now;
  double next_probe = ready;
  double next_reclaim = ready + (double)cfg.interval;
  double next_high =
      ready + (double)(cfg.high_pss_interval > 0 ? cfg.high_pss_interval : 3600);
  double next_relief = ready + (double)cfg.app_reclaim_interval;
  double next_vm = ready + 300;
  double next_rotate = now + 300;
  long last_conf_mtime = file_mtime(kConfFile);

  bool have_tight = false;
  bool tight = false;
  int quiet_probes = 0;
  double probe_period = (double)cfg.interval;
  MemInfo last_mem;
  bool have_mem = false;
  double run_start = now;
  unsigned long hb_tick = 0;

  while (!g_stop) {
    now = steady_seconds();
    g_wakeups++;

    if (file_exists("/data/adb/modules/cirno_reclaim/disable") ||
        file_exists("/data/adb/modules/cirno_reclaim/remove")) {
      log_line("cpp-daemon: module disabled/removed, exit");
      break;
    }

    if (g_reload) {
      g_reload = 0;
      cfg = load_config();
      last_conf_mtime = file_mtime(kConfFile);
      log_line("cpp-daemon: reloaded config (interval=%d hb=%d profile=%s)", cfg.interval,
               cfg.heartbeat_sec, cfg.device_profile.c_str());
    }

    long mt = file_mtime(kConfFile);
    if (mt != last_conf_mtime) {
      last_conf_mtime = mt;
      cfg = load_config();
      log_line("cpp-daemon: config changed, reloaded (interval=%d hb=%d profile=%s)", cfg.interval,
               cfg.heartbeat_sec, cfg.device_profile.c_str());
    }

    if (now >= next_hb) {
      write_heartbeat();
      // 统计文件隔一次心跳才写一次，减少 /data 上的写放大
      if ((++hb_tick & 1) == 0) write_stats(tight ? 1 : 0, last_mem, have_mem, now - run_start);
      // 长时间不紧张：心跳间隔也放宽到心跳超时的一半（默认 180/2=90s），
      // watchdog 仍然看得出掉线，但写盘次数减半。
      long hb = cfg.heartbeat_sec;
      if (quiet_probes >= 20) {
        long wide = hb * 2;
        long cap = cfg.heartbeat_timeout / 2;
        if (cap < 10) cap = 10;
        if (wide > cap) wide = cap;
        if (wide > hb) hb = wide;
      }
      next_hb = now + (double)hb;
    }

    // 压力探测：只读两个 /proc 文件，不 fork。空闲越久探测越稀。
    if (now >= ready && (now >= next_probe || !have_tight)) {
      g_probes++;
      MemInfo m;
      if (read_meminfo(m)) {
        double psi = read_psi_avg10();
        bool prev_tight = tight;
        bool t = pressure_tight(cfg, m, psi);
        if (!have_tight || t != tight) {
          log_line("cpp-daemon: pressure %s avail=%ldMB total=%ldMB low=%ldMB psi=%.2f",
                   t ? "TIGHT" : "relaxed", m.avail_mb, m.total_mb,
                   mem_low_threshold_mb(cfg, m.total_mb), psi);
        }
        tight = t;
        have_tight = true;
        last_mem = m;
        have_mem = true;
        quiet_probes = t ? 0 : quiet_probes + 1;
        // 刚从宽裕转紧张：立刻把回收计时器拨到「现在」，本轮就会 fork 一次回收
        if (t && !prev_tight) next_reclaim = now;
      } else {
        // 读不到内存信息时宁可多跑一次，不能让回收失灵
        tight = true;
        have_tight = true;
        quiet_probes = 0;
      }
      // 连续不紧张就把探测周期分档放宽；一旦紧张立即回到 interval。
      // 档位：quiet>=10 -> min(60, interval*2)；quiet>=20 -> min(90, interval*3)
      double base = (double)cfg.interval;
      if (quiet_probes >= 10) {
        double wide = base * 2.0;
        if (wide > 60.0) wide = 60.0;
        if (wide > base) base = wide;
      }
      if (quiet_probes >= 20) {
        double wide = (double)cfg.interval * 3.0;
        if (wide > 90.0) wide = 90.0;
        if (wide > base) base = wide;
      }
      probe_period = base;
      next_probe = now + probe_period;
    }

    // 注意：所有 next_* 计时器「到点就无条件前移」，只有真正 spawn 受 enable/压力控制。
    // 否则 enable=0 时计时器永远停在过去，睡眠退化成 0.05s 忙循环。
    if (now >= next_high) {
      next_high = now + (double)cfg.high_pss_interval;
      // 大进程看门狗：不紧张时按周期跑；紧张时由下面的常规回收覆盖
      if (cfg.enable && cfg.high_pss_mb > 0 && !tight && !child_running("reclaim") &&
          !child_running("reclaim-high")) {
        spawn_child("reclaim-high", kReclaimScript, "--run", "--high-check", 120);
      }
    }

    if (now >= next_reclaim) {
      if (cfg.enable && tight && !child_running("reclaim") && !child_running("reclaim-high")) {
        long wait = reclaim_cooldown_wait(cfg.cooldown_sec);
        if (wait <= 0) {
          spawn_child("reclaim", kReclaimScript, "--run", nullptr, 180);
          next_reclaim = now + (double)cfg.interval;
        } else {
          // 冷却还没过：直接睡到冷却结束，别在这期间反复 fork
          if (wait < 5) wait = 5;
          next_reclaim = now + (double)wait;
        }
      } else {
        next_reclaim = now + (double)cfg.interval;
      }
    }

    if (now >= next_relief) {
      next_relief = now + (double)cfg.app_reclaim_interval;
      // 前台舒缓：relief_gate=1 时同样只在紧张时跑
      if (cfg.enable && cfg.app_reclaim && (!cfg.relief_gate || tight) &&
          !child_running("app_relief")) {
        spawn_child("app_relief", kReliefScript, nullptr, nullptr, 120);
      }
    }

    // VM 参数回写：Android 偶尔会把 swappiness 之类的值改回去。
    // vm_tune=0（ColorOS 档案）时完全不 fork，省掉这份开销。
    if (now >= next_vm) {
      next_vm = now + 300;
      if (cfg.enable && cfg.vm_tune && !child_running("vm_tune")) {
        spawn_child("vm_tune", kVmScript, "reassert", nullptr, 60);
      }
    }

    if (now >= next_rotate) {
      rotate_log(cfg);
      next_rotate = now + 300;
    }

    reap_children();

    // 睡到下一个事件。回收/看门狗/舒缓的「到点判断」不需要单独唤醒：
    // 它们都是纯比较，跟着压力探测一起评估就够了，这样空闲时唤醒次数直接由 probe_period 决定。
    // 有子进程在跑时睡短一点，保证子进程超时能被及时处理。
    double next = next_hb;
    if (next_probe < next) next = next_probe;
    if (next_rotate < next) next = next_rotate;
    if (!have_tight && ready < next) next = ready;
    double cap = g_children.empty() ? 45.0 : 1.5;
    sleep_until(now, next, cap);
  }

  for (size_t i = 0; i < g_children.size(); i++) {
    kill(g_children[i].pid, SIGTERM);
  }
  for (int i = 0; i < 30 && !g_children.empty(); i++) {
    reap_children();
    struct timespec ts = {0, 100 * 1000 * 1000};
    nanosleep(&ts, nullptr);
  }

  std::string cur = read_pid_file(kPidFile);
  if (atoi(cur.c_str()) == (int)getpid()) unlink(kPidFile);
  release_lock();
  log_line("cpp-daemon exit pid=%d", (int)getpid());
  return 0;
}
