// ============================================================================
//  Cirno Reclaim Hybrid - src/cirno_daemon.cpp
//  C++ 守护进程：负责调度、心跳、子进程回收与限时，具体回收逻辑仍交给 shell 引擎。
//
//  为什么用 C++ 做守护：
//    - 不依赖 shell 的 sleep 循环，心跳/超时用单调时钟，不会被系统时间跳变影响；
//    - 子进程有硬超时，dumpsys 卡住时不会拖死整个守护；
//    - 单文件静态二进制（zig c++ 交叉编译），不依赖 Android 的 libc++。
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
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <string>
#include <vector>

namespace {

const char *kModDir = "/data/adb/modules/cirno_reclaim";
const char *kDataDir = "/data/adb/cirno_reclaim";
const char *kStateDir = "/data/adb/cirno_reclaim/state";
const char *kLogDir = "/data/adb/modules/cirno_reclaim/log";
const char *kLogFile = "/data/adb/modules/cirno_reclaim/log/reclaim.log";
const char *kConfFile = "/data/adb/cirno_reclaim/config.conf";
const char *kPidFile = "/data/adb/cirno_reclaim/daemon.pid";
const char *kLockDir = "/data/adb/cirno_reclaim/lock.daemon";
const char *kHeartbeat = "/data/adb/cirno_reclaim/state/heartbeat";
const char *kReclaimScript = "/data/adb/modules/cirno_reclaim/bin/reclaim.sh";
const char *kReliefScript = "/data/adb/modules/cirno_reclaim/bin/app_relief.sh";

volatile sig_atomic_t g_stop = 0;
volatile sig_atomic_t g_reload = 0;
bool g_foreground = false;

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
  int interval = 15;
  int app_reclaim = 1;
  int app_reclaim_interval = 45;
  int vm_tune = 1;
  int keepalive = 1;
  int oom_protect = 1;
  int high_pss_mb = 600;
  int high_pss_interval = 90;
  int log_max_kb = 512;
  int boot_delay = 90;
  int loaded_lines = 0;
  int bad_lines = 0;
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
    else if (key == "app_reclaim" && numeric) c.app_reclaim = n;
    else if (key == "app_reclaim_interval" && numeric) c.app_reclaim_interval = n;
    else if (key == "vm_tune" && numeric) c.vm_tune = n;
    else if (key == "keepalive" && numeric) c.keepalive = n;
    else if (key == "oom_protect" && numeric) c.oom_protect = n;
    else if (key == "high_pss_mb" && numeric) c.high_pss_mb = n;
    else if (key == "high_pss_interval" && numeric) c.high_pss_interval = n;
    else if (key == "log_max_kb" && numeric) c.log_max_kb = n;
    else if (key == "boot_delay" && numeric) c.boot_delay = n;
    c.loaded_lines++;
  }

  // 和 shell 的 cfg_clamp 保持一致
  if (c.interval < 5) c.interval = 5;
  if (c.interval > 300) c.interval = 300;
  if (c.app_reclaim_interval < 10) c.app_reclaim_interval = 10;
  if (c.high_pss_interval < 30) c.high_pss_interval = 30;
  if (c.log_max_kb < 32) c.log_max_kb = 32;
  if (c.bad_lines > 0) {
    log_line("WARN cpp-daemon: %d invalid config line(s) ignored", c.bad_lines);
  }
  return c;
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

bool child_running(const char *name) {
  for (size_t i = 0; i < g_children.size(); i++) {
    if (g_children[i].name == name) return true;
  }
  return false;
}

void spawn_child(const char *name, const char *script, const char *arg1, const char *arg2,
                 int timeout_sec) {
  if (!file_exists(script)) {
    log_line("WARN cpp-daemon: missing %s, skip %s", script, name);
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
  log_line("cpp-daemon: start %s pid=%d", name, (int)pid);
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

void protect_self(const Config &c) {
  if (!c.oom_protect) return;
  int fd = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return;
  ssize_t ignored = write(fd, "-900", 4);
  (void)ignored;
  close(fd);
}

void rotate_log(const Config &c) {
  long size = file_size(kLogFile);
  if (size < 0 || size <= (long)c.log_max_kb * 1024) return;
  std::string rotated = std::string(kLogFile) + ".1";
  rename(kLogFile, rotated.c_str());
  log_line("cpp-daemon: log rotated (limit %dKB)", c.log_max_kb);
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
  printf("\"children\":%d", (int)g_children.size());
  printf("}\n");
  return 0;
}

void usage() {
  printf("usage: cirno_daemon [--status] [--check] [--foreground] [--once]\n");
}

int check_config() {
  Config c = load_config();
  printf("config: %s\n", kConfFile);
  printf("lines: parsed=%d invalid=%d\n", c.loaded_lines, c.bad_lines);
  printf("interval=%d app_interval=%d high_pss_mb=%d log_max_kb=%d\n",
         c.interval, c.app_reclaim_interval, c.high_pss_mb, c.log_max_kb);
  return c.bad_lines == 0 ? 0 : 2;
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

  log_line("cpp-daemon start pid=%d interval=%d app=%d", (int)getpid(), cfg.interval,
           cfg.app_reclaim_interval);

  double now = steady_seconds();
  double next_hb = now;
  double next_reclaim = now;
  double next_high = now + cfg.high_pss_interval;
  double next_app = now + 5;
  double next_rotate = now + 60;
  long last_conf_mtime = file_mtime(kConfFile);

  while (!g_stop) {
    now = steady_seconds();

    if (file_exists("/data/adb/modules/cirno_reclaim/disable") ||
        file_exists("/data/adb/modules/cirno_reclaim/remove")) {
      log_line("cpp-daemon: module disabled/removed, exit");
      break;
    }

    if (g_reload) {
      g_reload = 0;
      cfg = load_config();
      last_conf_mtime = file_mtime(kConfFile);
      log_line("cpp-daemon: reloaded config");
    }

    long mt = file_mtime(kConfFile);
    if (mt != last_conf_mtime) {
      last_conf_mtime = mt;
      cfg = load_config();
      log_line("cpp-daemon: config changed, reloaded");
    }

    if (now >= next_hb) {
      write_heartbeat();
      next_hb = now + 5;
    }

    if (cfg.enable) {
      if (now >= next_reclaim && !child_running("reclaim")) {
        spawn_child("reclaim", kReclaimScript, "--run", nullptr, 180);
        next_reclaim = now + cfg.interval;
      }
      if (cfg.high_pss_mb > 0 && now >= next_high && !child_running("reclaim")) {
        spawn_child("reclaim-high", kReclaimScript, "--run", "--high-check", 120);
        next_high = now + cfg.high_pss_interval;
      }
      if (cfg.app_reclaim && now >= next_app && !child_running("app_relief")) {
        spawn_child("app_relief", kReliefScript, nullptr, nullptr, 120);
        next_app = now + cfg.app_reclaim_interval;
      }
    }

    if (now >= next_rotate) {
      rotate_log(cfg);
      next_rotate = now + 60;
    }

    reap_children();

    struct timespec ts = {0, 1000 * 1000 * 1000};
    nanosleep(&ts, nullptr);
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
