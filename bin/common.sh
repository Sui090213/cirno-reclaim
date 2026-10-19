#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/common.sh
#  所有脚本共享的基础设施：日志、内存读数、PSS、冻结检测、进程管理。
#  严格 POSIX sh（Android 上是 mksh），不要写 bash 专有语法。
# ============================================================================

# 模块目录：common.sh 可能被根目录脚本（service.sh / post-fs-data.sh）
# 或 bin/ 下的脚本 source，所以按「调用者的目录」判断层级。
_cr_self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ "$(basename "$_cr_self_dir")" = "bin" ]; then
  MODDIR=${MODDIR:-$(cd "$_cr_self_dir/.." && pwd)}
  CR_BIN=${CR_BIN:-"$_cr_self_dir"}
else
  MODDIR=${MODDIR:-"$_cr_self_dir"}
  CR_BIN=${CR_BIN:-"$MODDIR/bin"}
fi

# 兜底：如果 $0 推导出来的目录不是模块目录（某些管理器会换 cwd），
# 直接回到标准安装路径，避免整条链路找不到文件。
if [ ! -f "$MODDIR/module.prop" ] && [ -f /data/adb/modules/cirno_reclaim/module.prop ]; then
  MODDIR=/data/adb/modules/cirno_reclaim
  CR_BIN="$MODDIR/bin"
fi

DATA_DIR=${DATA_DIR:-/data/adb/cirno_reclaim}
STATE_DIR="$DATA_DIR/state"
LOG_DIR=${LOG_DIR:-"$MODDIR/log"}
LOG_FILE="$LOG_DIR/reclaim.log"
CONF_FILE="$DATA_DIR/config.conf"
PID_FILE="$DATA_DIR/daemon.pid"
WD_PID_FILE="$DATA_DIR/watchdog.pid"
LOCK_DAEMON="$DATA_DIR/lock.daemon"
LOCK_WATCHDOG="$DATA_DIR/lock.watchdog"
LOCK_RECLAIM="$DATA_DIR/lock.reclaim"
HELPER="$CR_BIN/cirno_pageout"
# cgroup v2 挂载点；测试时可以指到假目录
CR_CGROOT=${CR_CGROOT:-/sys/fs/cgroup}

MODULE_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
[ -n "$MODULE_VERSION" ] || MODULE_VERSION="unknown"

umask 077

# ---------------------------------------------------------------- 目录
cr_init_dirs() {
  [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR" 2>/dev/null
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
  chmod 700 "$DATA_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null
  chmod 755 "$LOG_DIR" 2>/dev/null
  # 老版本数据目录（若存在）保持 0700
  [ -f "$CONF_FILE" ] && chmod 600 "$CONF_FILE" 2>/dev/null
  [ -f "$LOG_FILE" ] && chmod 600 "$LOG_FILE" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- 日志
log() {
  _cr_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  printf '%s %s\n' "${_cr_ts:-??:??:??}" "$*" >>"$LOG_FILE" 2>/dev/null
  return 0
}

log_rotate() {
  [ -f "$LOG_FILE" ] || return 0
  _kb=${log_max_kb:-512}
  _size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
  [ -n "$_size" ] || return 0
  if [ "$_size" -gt $((_kb * 1024)) ] 2>/dev/null; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    : >"$LOG_FILE"
    log "log rotated (limit ${_kb}KB)"
  fi
  return 0
}

# ---------------------------------------------------------------- 内存读数
meminfo_kb() {
  awk -v k="$1:" '$1 == k {print $2; exit}' /proc/meminfo 2>/dev/null
}

mem_total_mb() {
  _cr_kb=$(meminfo_kb MemTotal)
  [ -n "$_cr_kb" ] || _cr_kb=0
  printf '%s' $((_cr_kb / 1024))
}

mem_avail_mb() {
  _cr_kb=$(meminfo_kb MemAvailable)
  if [ -z "$_cr_kb" ]; then
    # 老内核没有 MemAvailable，用近似值
    _cr_kb=$(awk '/^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} END{print f+b+c}' /proc/meminfo 2>/dev/null)
  fi
  [ -n "$_cr_kb" ] || _cr_kb=0
  printf '%s' $((_cr_kb / 1024))
}

swap_total_mb() {
  _cr_kb=$(meminfo_kb SwapTotal)
  [ -n "$_cr_kb" ] || _cr_kb=0
  printf '%s' $((_cr_kb / 1024))
}

# 所有 zram 设备实际占用的内存（MB）：mm_stat 第 3 列 mem_used_total（字节）
zram_used_mb() {
  _cr_t=0
  for _cr_z in /sys/block/zram*/mm_stat; do
    [ -r "$_cr_z" ] || continue
    read -r _cr_o _cr_c _cr_u _cr_rest <"$_cr_z"
    case "$_cr_u" in ''|*[!0-9]*) continue ;; esac
    _cr_t=$((_cr_t + _cr_u / 1048576))
  done
  printf '%s' "$_cr_t"
}

swap_free_mb() {
  _cr_kb=$(meminfo_kb SwapFree)
  [ -n "$_cr_kb" ] || _cr_kb=0
  printf '%s' $((_cr_kb / 1024))
}

# /proc/pressure/memory 的 some avg10，内核不支持时输出 -1
psi_some_avg10() {
  if [ -r /proc/pressure/memory ]; then
    awk '/^some / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit }
      }
    }' /proc/pressure/memory 2>/dev/null
  else
    printf '%s' '-1'
  fi
}

# 有效触发阈值：绝对值与总内存百分比取大
mem_low_threshold_mb() {
  _cr_low=${mem_low_mb:-800}
  _cr_pct=${mem_low_pct:-0}
  if [ "${_cr_pct:-0}" -gt 0 ] 2>/dev/null; then
    _cr_pct_mb=$(( $(mem_total_mb) * _cr_pct / 100 ))
    [ "$_cr_pct_mb" -gt "$_cr_low" ] && _cr_low=$_cr_pct_mb
  fi
  printf '%s' "$_cr_low"
}

mem_target_threshold_mb() {
  _cr_tgt=${mem_target_mb:-1200}
  _cr_pct=${mem_target_pct:-0}
  if [ "${_cr_pct:-0}" -gt 0 ] 2>/dev/null; then
    _cr_pct_mb=$(( $(mem_total_mb) * _cr_pct / 100 ))
    [ "$_cr_pct_mb" -gt "$_cr_tgt" ] && _cr_tgt=$_cr_pct_mb
  fi
  printf '%s' "$_cr_tgt"
}

# ---------------------------------------------------------------- /proc 读取
pid_alive() {
  [ -n "$1" ] && [ -d "/proc/$1" ] && kill -0 "$1" 2>/dev/null
}

pid_cmdline() {
  tr '\0' '\n' <"/proc/$1/cmdline" 2>/dev/null | head -n 1
}

pid_uid() {
  awk '/^Uid:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null
}

pid_oom() {
  cat "/proc/$1/oom_score_adj" 2>/dev/null
}

pid_threads() {
  awk '/^Threads:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null
}

pid_starttime() {
  sed 's/^[0-9]* (.*) //' "/proc/$1/stat" 2>/dev/null | awk 'NF >= 20 {print $20; exit}'
}

# PSS（KB）。优先 smaps_rollup（Android 9+ / 内核 4.14+）
pid_pss_kb() {
  if [ -r "/proc/$1/smaps_rollup" ]; then
    awk '/^Pss:/ {print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null
  else
    awk '/^Pss:/ {s += $2} END {print s + 0}' "/proc/$1/smaps" 2>/dev/null
  fi
}

# 进程属于哪个包（去掉 :service 之类的后缀）
# 只接受应用包名允许的字符集，避免 /proc 里奇怪的名字被拼进 am kill
pid_pkg() {
  _cr_cmd=$(pid_cmdline "$1")
  [ -n "$_cr_cmd" ] || return 1
  case "$_cr_cmd" in
    /*|\[*) return 1 ;;
  esac
  _cr_pkg=${_cr_cmd%%:*}
  case "$_cr_pkg" in
    ''|*[!A-Za-z0-9_.]*) return 1 ;;
  esac
  printf '%s' "$_cr_pkg"
}

# ---------------------------------------------------------------- cgroup 布局
# 应用进程的 per-pid cgroup 在不同 Android 版本 / ROM 上挂的位置不同：
#   apps/uid_<uid>/pid_<pid>   新版 AOSP 与 HyperOS
#   uid_<uid>/pid_<pid>        Android 12~14 的 AOSP 布局，部分 ROM 沿用
# 只认 apps/ 的话，后一种布局上永远找不到冻结进程，模块会一直空转。
# 结果写在 CR_CG_APPS（空 = 两种都没有）。
cg_detect_layout() {
  [ -n "${CR_CG_LAYOUT_DONE:-}" ] && return 0
  CR_CG_LAYOUT_DONE=1
  CR_CG_APPS=""
  for _cr_root in "$CR_CGROOT/apps" "$CR_CGROOT"; do
    for _cr_d in "$_cr_root"/uid_*; do
      if [ -d "$_cr_d" ]; then
        CR_CG_APPS=$_cr_root
        return 0
      fi
    done
  done
  return 0
}

# 某个 pid 所在 cgroup 的目录（找不到输出空）
pid_cg_dir() {
  cg_detect_layout
  _cr_uid=$(pid_uid "$1")
  if [ -n "$CR_CG_APPS" ] && [ -n "$_cr_uid" ] && [ -d "$CR_CG_APPS/uid_$_cr_uid/pid_$1" ]; then
    printf '%s' "$CR_CG_APPS/uid_$_cr_uid/pid_$1"
    return 0
  fi
  _cr_cg=$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$1/cgroup" 2>/dev/null)
  case "$_cr_cg" in
    ''|/) return 1 ;;
  esac
  [ -d "$CR_CGROOT$_cr_cg" ] || return 1
  printf '%s' "$CR_CGROOT$_cr_cg"
}

# cgroup 目录是否处于冻结状态。
# cgroup.events 的 frozen 字段是「实际」状态，冻结写在 uid_ 这一层时 pid_ 层的
# cgroup.freeze 仍然是 0，只看 cgroup.freeze 会漏掉。
# 扫描时每个 pid 都要调一次，只用 read 内建，不 fork。
cg_dir_frozen() {
  if [ -r "$1/cgroup.events" ]; then
    while read -r _cr_k _cr_v; do
      [ "$_cr_k" = "frozen" ] && [ "$_cr_v" = "1" ] && return 0
    done <"$1/cgroup.events"
  fi
  _cr_v=""
  [ -r "$1/cgroup.freeze" ] && read -r _cr_v <"$1/cgroup.freeze"
  [ "$_cr_v" = "1" ]
}

# 冻结检测：per-pid cgroup（两种布局都认），其次从 /proc/<pid>/cgroup 推导
pid_frozen() {
  [ -d "/proc/$1" ] || return 1
  _cr_dir=$(pid_cg_dir "$1") || return 1
  cg_dir_frozen "$_cr_dir"
}

pid_set_frozen() {
  _cr_dir=$(pid_cg_dir "$1") || return 1
  [ -w "$_cr_dir/cgroup.freeze" ] || return 1
  printf '%s' "$2" >"$_cr_dir/cgroup.freeze" 2>/dev/null
}

pids_of_pkg() {
  _cr_pkg=$1
  for _cr_d in /proc/[0-9]*; do
    _cr_p=${_cr_d#/proc/}
    [ -r "$_cr_d/cmdline" ] || continue
    _cr_c=$(tr '\0' '\n' <"$_cr_d/cmdline" 2>/dev/null | head -n 1)
    case "$_cr_c" in
      "$_cr_pkg"|"$_cr_pkg":*) printf '%s\n' "$_cr_p" ;;
    esac
  done
}

# ---------------------------------------------------------------- 前台应用
fg_pkg() {
  _cr_line=$(dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity=|mResumedActivity:|ResumedActivity:' | head -n 1)
  if [ -z "$_cr_line" ]; then
    _cr_line=$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus=|mFocusedApp=' | head -n 1)
  fi
  [ -n "$_cr_line" ] || return 1
  printf '%s\n' "$_cr_line" |
    sed -n 's/.*[ {]\([A-Za-z0-9_][A-Za-z0-9_.]*\)\/[A-Za-z0-9_.$]*.*/\1/p' |
    head -n 1
}

# dumpsys activity 很重，内存紧张时几百 ms 起步。
# 30 秒内复用缓存，避免每轮 / 每个候选都去敲 system_server。
fg_pkg_cached() {
  _cr_c="$STATE_DIR/fg.pkg"
  if [ -r "$_cr_c" ] && [ "$(since_epoch_file fg.ts)" -le 30 ]; then
    cat "$_cr_c" 2>/dev/null
    return 0
  fi
  _cr_v=$(fg_pkg) || return 1
  [ -n "$_cr_v" ] || return 1
  printf '%s' "$_cr_v" >"$_cr_c" 2>/dev/null
  chmod 600 "$_cr_c" 2>/dev/null
  date +%s >"$STATE_DIR/fg.ts" 2>/dev/null
  printf '%s' "$_cr_v"
}

# ---------------------------------------------------------------- 保护名单
CR_HARD_PROTECT="android com.android.systemui com.android.shell com.android.phone \
com.android.server.telecom com.android.bluetooth com.android.nfc com.android.dialer \
com.android.incallui com.android.keychain com.android.certinstaller com.android.settings \
com.google.android.gms com.google.android.gsf com.google.android.permissioncontroller \
com.android.permissioncontroller com.google.android.packageinstaller com.android.packageinstaller \
com.topjohnwu.magisk me.weishu.kernelsu com.derq.ksunext com.sukisu.ultra me.bmax.apatch \
io.github.a13e300.ksuwebui nep.timeline.cirno \
com.rifsxd.ksunext io.github.vvb2060.magisk org.lsposed.manager moe.shizuku.privileged.api \
com.android.launcher com.oppo.launcher com.oplus.athena com.oplus.battery com.oplus.deepthinker \
com.oplus.cosa com.oplus.uiengine com.oplus.securitypermission com.coloros.securitypermission \
com.coloros.safecenter com.oplus.safecenter com.coloros.phonemanager com.oplus.phonemanager \
com.heytap.mcs com.heytap.htms com.heytap.openid com.coloros.ocs.opencapabilityservice \
com.oplus.ocs com.oplus.appplatform com.oplus.exsystemservice com.oplus.wirelesssettings \
com.coloros.wirelesssettings com.oplus.aod com.oplus.persist.system com.android.incallui"

# 运行时补充的桌面 / 输入法（缓存到 state/ 里，避免每次都跑 dumpsys）
protected_dynamic_load() {
  [ -r "$STATE_DIR/protect.dynamic" ] && cat "$STATE_DIR/protect.dynamic"
  return 0
}

protected_dynamic_refresh() {
  _cr_out=""
  _cr_home=$(cmd package resolve-activity --brief -a android.intent.action.MAIN \
    -c android.intent.category.HOME 2>/dev/null | tail -n 1 | cut -d/ -f1)
  case "$_cr_home" in
    */*|"") : ;;
    *) _cr_out="$_cr_out $_cr_home" ;;
  esac
  _cr_ime=$(settings get secure default_input_method 2>/dev/null | cut -d/ -f1)
  case "$_cr_ime" in
    null|""|*/*) : ;;
    *) _cr_out="$_cr_out $_cr_ime" ;;
  esac
  printf '%s' "${_cr_out# }" >"$STATE_DIR/protect.dynamic" 2>/dev/null
  chmod 600 "$STATE_DIR/protect.dynamic" 2>/dev/null
  return 0
}

in_list() {
  # $1 = 包名, $2 = 分号分隔名单
  # 逐段切分，不做无引号展开（避免 `*` 被当前目录的文件名撑开）
  [ -n "$2" ] || return 1
  _cr_rest=$2
  while [ -n "$_cr_rest" ]; do
    _cr_pat=${_cr_rest%%;*}
    case "$_cr_rest" in
      *';'*) _cr_rest=${_cr_rest#*;} ;;
      *) _cr_rest="" ;;
    esac
    [ -n "$_cr_pat" ] || continue
    # 名单支持 * 通配，这里故意不加引号
    # shellcheck disable=SC2254
    case "$1" in
      $_cr_pat) return 0 ;;
    esac
  done
  return 1
}

pkg_protected() {
  _cr_p=$1
  case " $CR_HARD_PROTECT " in
    *" $_cr_p "*) return 0 ;;
  esac
  case "$_cr_p" in
    com.android.providers.*|com.android.internal.*|com.google.android.ext.*) return 0 ;;
  esac
  for _cr_d in $(protected_dynamic_load); do
    [ "$_cr_p" = "$_cr_d" ] && return 0
  done
  in_list "$_cr_p" "${exclude_packages:-}" && return 0
  return 1
}

# include_packages 非空时，只处理名单内的包
pkg_included() {
  [ -n "${include_packages:-}" ] || return 0
  in_list "$1" "$include_packages"
}

# ColorOS / OxygenOS / realme UI（同一套 OPlus 底层）
# 这些系统自带「内存扩展」（zram + 写回存储），由系统自己管 swap 和回收参数。
is_coloros() {
  [ -n "$(getprop ro.build.version.oplusrom 2>/dev/null)" ] && return 0
  [ -n "$(getprop ro.build.version.opporom 2>/dev/null)" ] && return 0
  [ -d /my_product ]
}

# ---------------------------------------------------------------- 配置
cfg_defaults() {
  : "${enable:=1}"
  : "${dry_run:=0}"
  : "${interval:=15}"
  : "${boot_delay:=90}"
  : "${log_max_kb:=512}"
  : "${profile:=balanced}"

  : "${mem_low_mb:=800}"
  : "${mem_low_pct:=8}"
  : "${mem_target_mb:=1200}"
  : "${mem_target_pct:=14}"
  : "${psi_enable:=1}"
  : "${psi_some_avg10:=25}"
  : "${high_pss_mb:=600}"
  : "${high_pss_interval:=90}"
  : "${max_kills_per_run:=4}"
  : "${max_kills_per_hour:=20}"
  : "${max_rounds:=4}"
  : "${cooldown_sec:=60}"
  : "${min_process_mb:=48}"
  : "${min_frozen_min:=5}"
  : "${min_oom_score_adj:=900}"
  : "${only_frozen:=1}"
  : "${kill_mode:=pid}"
  : "${protect_foreground:=1}"
  : "${screen_off_only:=0}"
  : "${drop_caches:=0}"
  : "${drop_caches_cooldown:=1800}"
  : "${deep_reclaim:=1}"
  : "${deep_pageout_max_mb:=256}"
  : "${reclaim_order:=pageout_first}"
  : "${allow_system_uid:=0}"

  # 名单：配置里通常有，这里只是兜底
  : "${include_packages:=}"
  : "${exclude_packages:=}"

  : "${app_reclaim:=1}"
  : "${app_pss_mb:=900}"
  : "${app_reclaim_interval:=45}"
  : "${app_reclaim_cooldown:=90}"
  : "${app_trim_level:=RUNNING_LOW}"
  : "${app_trim_all_pids:=1}"
  : "${app_pageout:=1}"
  : "${app_pageout_max_mb:=192}"
  : "${app_pageout_passes:=3}"
  : "${app_proc_reclaim:=0}"

  : "${vm_tune:=0}"
  : "${zram_enable:=0}"
  : "${zram_disksize_mb:=0}"
  : "${zram_algorithm:=lz4}"
  : "${swapfile_enable:=0}"
  : "${swapfile_mb:=2048}"
  : "${swappiness:=80}"
  : "${vfs_cache_pressure:=100}"
  : "${dirty_writeback_centisecs:=1500}"
  : "${dirty_expire_centisecs:=500}"
  : "${page_cluster:=1}"
  : "${io_tune:=0}"
  : "${read_ahead_kb:=128}"

  : "${keepalive:=1}"
  : "${watchdog_interval:=30}"
  : "${heartbeat_timeout:=180}"
  : "${oom_protect:=1}"
  return 0
}

# ---------------------------------------------------------------- 配置
# config.conf 永远不被 source。
# 流程：逐行解析 -> 键白名单 -> 按类型校验值 -> case 赋值。
# 值只作为变量内容存在，不会回到 shell 再解析，所以 `;`、`$()`、反引号都无效。

# 去首尾空白，结果写到 CFG_TRIMMED（用全局变量而不是命令替换，
# 避免每行都 fork 一个子 shell）
cfg_trim_var() {
  _cr_t=$1
  _cr_t=${_cr_t#"${_cr_t%%[![:space:]]*}"}
  _cr_t=${_cr_t%"${_cr_t##*[![:space:]]}"}
  CFG_TRIMMED=$_cr_t
}

cfg_value_type_ok() {
  # $1 = 键，$2 = 已 trim、已去成对引号的值
  case "$1" in
    include_packages|exclude_packages)
      case "$2" in
        *[!A-Za-z0-9_.:\;*/+=,\ -]*) return 1 ;;
      esac
      return 0
      ;;
    kill_mode)
      case "$2" in pid|am) return 0 ;; esac
      ;;
    reclaim_order)
      case "$2" in pageout_first|kill_first) return 0 ;; esac
      ;;
    app_trim_level)
      case "$2" in RUNNING_MODERATE|RUNNING_LOW|RUNNING_CRITICAL) return 0 ;; esac
      ;;
    profile)
      case "$2" in conservative|balanced|aggressive) return 0 ;; esac
      ;;
    zram_algorithm)
      case "$2" in lz4|lz4hc|zstd|lzo-rle|lzo|'') return 0 ;; esac
      ;;
    *)
      case "$2" in ''|*[!0-9]*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

# 只做赋值，不 eval、不再交给 shell 解析
cfg_assign() {
  case "$1" in
    enable) enable=$2 ;;
    dry_run) dry_run=$2 ;;
    interval) interval=$2 ;;
    boot_delay) boot_delay=$2 ;;
    log_max_kb) log_max_kb=$2 ;;
    profile) profile=$2 ;;
    mem_low_mb) mem_low_mb=$2 ;;
    mem_low_pct) mem_low_pct=$2 ;;
    mem_target_mb) mem_target_mb=$2 ;;
    mem_target_pct) mem_target_pct=$2 ;;
    psi_enable) psi_enable=$2 ;;
    psi_some_avg10) psi_some_avg10=$2 ;;
    high_pss_mb) high_pss_mb=$2 ;;
    high_pss_interval) high_pss_interval=$2 ;;
    max_kills_per_run) max_kills_per_run=$2 ;;
    max_kills_per_hour) max_kills_per_hour=$2 ;;
    max_rounds) max_rounds=$2 ;;
    cooldown_sec) cooldown_sec=$2 ;;
    min_process_mb) min_process_mb=$2 ;;
    min_frozen_min) min_frozen_min=$2 ;;
    min_oom_score_adj) min_oom_score_adj=$2 ;;
    only_frozen) only_frozen=$2 ;;
    kill_mode) kill_mode=$2 ;;
    protect_foreground) protect_foreground=$2 ;;
    screen_off_only) screen_off_only=$2 ;;
    drop_caches) drop_caches=$2 ;;
    drop_caches_cooldown) drop_caches_cooldown=$2 ;;
    deep_reclaim) deep_reclaim=$2 ;;
    deep_pageout_max_mb) deep_pageout_max_mb=$2 ;;
    reclaim_order) reclaim_order=$2 ;;
    allow_system_uid) allow_system_uid=$2 ;;
    app_reclaim) app_reclaim=$2 ;;
    app_pss_mb) app_pss_mb=$2 ;;
    app_reclaim_interval) app_reclaim_interval=$2 ;;
    app_reclaim_cooldown) app_reclaim_cooldown=$2 ;;
    app_trim_level) app_trim_level=$2 ;;
    app_trim_all_pids) app_trim_all_pids=$2 ;;
    app_pageout) app_pageout=$2 ;;
    app_pageout_max_mb) app_pageout_max_mb=$2 ;;
    app_pageout_passes) app_pageout_passes=$2 ;;
    app_proc_reclaim) app_proc_reclaim=$2 ;;
    vm_tune) vm_tune=$2 ;;
    zram_enable) zram_enable=$2 ;;
    zram_disksize_mb) zram_disksize_mb=$2 ;;
    zram_algorithm) zram_algorithm=$2 ;;
    swapfile_enable) swapfile_enable=$2 ;;
    swapfile_mb) swapfile_mb=$2 ;;
    swappiness) swappiness=$2 ;;
    vfs_cache_pressure) vfs_cache_pressure=$2 ;;
    dirty_writeback_centisecs) dirty_writeback_centisecs=$2 ;;
    dirty_expire_centisecs) dirty_expire_centisecs=$2 ;;
    page_cluster) page_cluster=$2 ;;
    io_tune) io_tune=$2 ;;
    read_ahead_kb) read_ahead_kb=$2 ;;
    keepalive) keepalive=$2 ;;
    watchdog_interval) watchdog_interval=$2 ;;
    heartbeat_timeout) heartbeat_timeout=$2 ;;
    oom_protect) oom_protect=$2 ;;
    include_packages) include_packages=$2 ;;
    exclude_packages) exclude_packages=$2 ;;
  esac
  return 0
}

# 读取配置：解析失败的行计数后忽略，不执行任何内容
cfg_load() {
  cfg_defaults
  [ -r "$CONF_FILE" ] || return 0

  _cr_bad=0
  while IFS= read -r _cr_line || [ -n "$_cr_line" ]; do
    # 允许缩进的注释行
    cfg_trim_var "$_cr_line"
    _cr_line=$CFG_TRIMMED
    case "$_cr_line" in
      ''|'#'*) continue ;;
    esac
    case "$_cr_line" in
      *=*) ;;
      *) _cr_bad=$((_cr_bad + 1)); continue ;;
    esac

    _cr_k=${_cr_line%%=*}
    _cr_v=${_cr_line#*=}
    cfg_trim_var "$_cr_k"
    _cr_k=$CFG_TRIMMED

    # 行内注释只认「空白 + #」；# 出现在别处说明这一行不可信，直接丢弃
    case "$_cr_v" in
      *[[:space:]]'#'*) _cr_v=${_cr_v%%[[:space:]]#*} ;;
      *'#'*) _cr_bad=$((_cr_bad + 1)); continue ;;
    esac
    cfg_trim_var "$_cr_v"
    _cr_v=$CFG_TRIMMED
    cfg_key_allowed "$_cr_k" || { _cr_bad=$((_cr_bad + 1)); continue; }
    case "$_cr_v" in
      \'*\') _cr_v=${_cr_v#\'}; _cr_v=${_cr_v%\'} ;;
      \"*\") _cr_v=${_cr_v#\"}; _cr_v=${_cr_v%\"} ;;
    esac

    # 空值：名单/算法允许清空，其余保持默认
    if [ -z "$_cr_v" ]; then
      case "$_cr_k" in
        include_packages|exclude_packages|zram_algorithm) : ;;
        *) continue ;;
      esac
    fi

    cfg_value_type_ok "$_cr_k" "$_cr_v" || { _cr_bad=$((_cr_bad + 1)); continue; }
    cfg_assign "$_cr_k" "$_cr_v"
  done <"$CONF_FILE"

  [ "$_cr_bad" -gt 0 ] && log "WARN config: $_cr_bad invalid line(s) ignored"
  cfg_clamp
  return 0
}

# 手改配置可能写出 0 / 超大值，这里统一夹到安全区间，
# 避免 interval=0 变成忙循环、heartbeat 不匹配造成周期性重启。
cfg_clamp() {
  case "${interval:-}" in ''|*[!0-9]*) interval=15 ;; esac
  [ "$interval" -ge 5 ] 2>/dev/null || interval=5
  [ "$interval" -le 300 ] 2>/dev/null || interval=300

  case "${watchdog_interval:-}" in ''|*[!0-9]*) watchdog_interval=30 ;; esac
  [ "$watchdog_interval" -ge 10 ] 2>/dev/null || watchdog_interval=10
  [ "$watchdog_interval" -le 600 ] 2>/dev/null || watchdog_interval=600

  case "${heartbeat_timeout:-}" in ''|*[!0-9]*) heartbeat_timeout=180 ;; esac
  _cr_min=$((interval * 3))
  [ "$heartbeat_timeout" -ge "$_cr_min" ] 2>/dev/null || heartbeat_timeout=$_cr_min
  [ "$heartbeat_timeout" -le 1800 ] 2>/dev/null || heartbeat_timeout=1800

  case "${boot_delay:-}" in ''|*[!0-9]*) boot_delay=90 ;; esac
  [ "$boot_delay" -le 600 ] 2>/dev/null || boot_delay=600

  case "${log_max_kb:-}" in ''|*[!0-9]*) log_max_kb=512 ;; esac
  [ "$log_max_kb" -ge 32 ] 2>/dev/null || log_max_kb=32

  case "${max_rounds:-}" in ''|*[!0-9]*) max_rounds=4 ;; esac
  [ "$max_rounds" -ge 1 ] 2>/dev/null || max_rounds=1
  [ "$max_rounds" -le 20 ] 2>/dev/null || max_rounds=20

  case "${cooldown_sec:-}" in ''|*[!0-9]*) cooldown_sec=60 ;; esac
  [ "$cooldown_sec" -le 86400 ] 2>/dev/null || cooldown_sec=86400

  case "${app_reclaim_interval:-}" in ''|*[!0-9]*) app_reclaim_interval=45 ;; esac
  [ "$app_reclaim_interval" -ge 10 ] 2>/dev/null || app_reclaim_interval=10

  return 0
}

cfg_cksum() {
  cksum "$CONF_FILE" 2>/dev/null | awk '{print $1 "-" $2}'
}

# 给 ctl.sh 用的白名单
cfg_key_allowed() {
  case "$1" in
    enable|dry_run|interval|boot_delay|log_max_kb|profile|\
    mem_low_mb|mem_low_pct|mem_target_mb|mem_target_pct|psi_enable|psi_some_avg10|\
    high_pss_mb|high_pss_interval|max_kills_per_run|max_kills_per_hour|max_rounds|\
    cooldown_sec|min_process_mb|min_frozen_min|min_oom_score_adj|only_frozen|kill_mode|\
    protect_foreground|screen_off_only|drop_caches|drop_caches_cooldown|deep_reclaim|\
    deep_pageout_max_mb|reclaim_order|allow_system_uid|\
    app_reclaim|app_pss_mb|app_reclaim_interval|app_reclaim_cooldown|app_trim_level|\
    app_trim_all_pids|app_pageout|app_pageout_max_mb|app_pageout_passes|app_proc_reclaim|\
    vm_tune|zram_enable|zram_disksize_mb|zram_algorithm|swapfile_enable|swapfile_mb|\
    swappiness|vfs_cache_pressure|dirty_writeback_centisecs|dirty_expire_centisecs|\
    page_cluster|io_tune|read_ahead_kb|\
    keepalive|watchdog_interval|heartbeat_timeout|oom_protect|\
    include_packages|exclude_packages)
      return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- 状态文件
st_read() {
  cat "$STATE_DIR/$1" 2>/dev/null
}

st_write() {
  printf '%s' "$2" >"$STATE_DIR/$1" 2>/dev/null
  chmod 600 "$STATE_DIR/$1" 2>/dev/null
  return 0
}

st_incr() {
  _cr_v=$(st_read "$1")
  [ -n "$_cr_v" ] || _cr_v=0
  _cr_v=$((_cr_v + ${2:-1}))
  st_write "$1" "$_cr_v"
  printf '%s' "$_cr_v"
}

# 最近 1 小时的回收次数
hour_count() {
  [ -r "$STATE_DIR/kills.hour" ] || { printf '0'; return 0; }
  _cr_now=$(date +%s)
  awk -v now="$_cr_now" '$1 ~ /^[0-9]+$/ && (now - $1) < 3600' "$STATE_DIR/kills.hour" 2>/dev/null |
    wc -l | tr -d ' '
}

hour_add() {
  _cr_now=$(date +%s)
  {
    [ -r "$STATE_DIR/kills.hour" ] && awk -v now="$_cr_now" '$1 ~ /^[0-9]+$/ && (now - $1) < 3600' "$STATE_DIR/kills.hour" 2>/dev/null
    printf '%s\n' "$_cr_now"
  } >"$STATE_DIR/kills.hour.tmp" 2>/dev/null
  mv -f "$STATE_DIR/kills.hour.tmp" "$STATE_DIR/kills.hour" 2>/dev/null
  return 0
}

heartbeat_write() {
  date +%s >"$STATE_DIR/heartbeat" 2>/dev/null
  chmod 600 "$STATE_DIR/heartbeat" 2>/dev/null
  return 0
}

# 文件内容（epoch）距今多少秒；不存在返回 999999
since_epoch_file() {
  [ -r "$STATE_DIR/$1" ] || { printf '999999'; return 0; }
  _cr_v=$(cat "$STATE_DIR/$1" 2>/dev/null)
  case "$_cr_v" in
    ''|*[!0-9]*) printf '999999'; return 0 ;;
  esac
  _cr_now=$(date +%s)
  _cr_d=$((_cr_now - _cr_v))
  [ "$_cr_d" -lt 0 ] && _cr_d=0
  printf '%s' "$_cr_d"
}

# ---------------------------------------------------------------- 动作封装
screen_on() {
  # 0 = 亮屏或无法判断（保守处理，宁可不回收）
  # 1 = 灭屏 / Doze
  _cr_s=$(dumpsys power 2>/dev/null | grep -E 'mWakefulness=' | head -n 1 | sed 's/.*mWakefulness=//')
  case "$_cr_s" in
    Asleep|Dozing) return 1 ;;
  esac
  return 0
}

am_kill_pkg() {
  am kill "$1" >/dev/null 2>&1
}

am_trim_pid() {
  am send-trim-memory "$1" "$2" >/dev/null 2>&1
}

drop_page_cache() {
  printf '1' >/proc/sys/vm/drop_caches 2>/dev/null
  log "drop_caches=1 issued (free=$(mem_avail_mb)MB)"
  return 0
}

# ---------------------------------------------------------------- pageout helper
helper_ready() {
  [ -x "$HELPER" ] || return 1
  [ "$(st_read can_pageout)" = "1" ] && return 0
  [ "$(st_read can_pageout)" = "0" ] && return 1
  if "$HELPER" --probe >/dev/null 2>&1; then
    st_write can_pageout 1
    return 0
  fi
  st_write can_pageout 0
  return 1
}

# 换出某个进程的私有匿名页，输出「实际」换出的字节数（按 VmSwap 差值）
# $3 = art 时连 ART 堆一起换出，只给已冻结的进程用
pageout_pid() {
  _cr_pid=$1
  _cr_max=${2:-64}
  helper_ready || return 2
  if [ "${3:-}" = "art" ]; then
    "$HELPER" --pid "$_cr_pid" --max-mb "$_cr_max" --include-art 2>/dev/null
  else
    "$HELPER" --pid "$_cr_pid" --max-mb "$_cr_max" 2>/dev/null
  fi
}

# ---------------------------------------------------------------- 进程管理
# 判断某个 pid 的命令行是否包含关键字（防止 pid 复用导致误判存活）
proc_cmdline_has() {
  [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qF -- "$2"
}

# $2 = 可选命令行关键字；给了就必须匹配，避免 pid 复用导致误判存活
is_running_pidfile() {
  _cr_f=$1
  _cr_pat=${2:-}
  [ -r "$_cr_f" ] || return 1
  _cr_p=$(cat "$_cr_f" 2>/dev/null)
  case "$_cr_p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pid_alive "$_cr_p" || return 1
  if [ -n "$_cr_pat" ]; then
    proc_cmdline_has "$_cr_p" "$_cr_pat" || return 1
  fi
  return 0
}

start_daemon() {
  is_running_pidfile "$PID_FILE" daemon.sh && return 0
  rm -f "$PID_FILE" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$CR_BIN/daemon.sh" >/dev/null 2>&1 &
  else
    ( sh "$CR_BIN/daemon.sh" >/dev/null 2>&1 & )
  fi
  sleep 1
  return 0
}

start_watchdog() {
  [ "${keepalive:-1}" = "1" ] || return 0
  is_running_pidfile "$WD_PID_FILE" watchdog.sh && return 0
  rm -f "$WD_PID_FILE" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$CR_BIN/watchdog.sh" >/dev/null 2>&1 &
  else
    ( sh "$CR_BIN/watchdog.sh" >/dev/null 2>&1 & )
  fi
  sleep 1
  return 0
}

stop_pidfile() {
  # $1 = pid 文件, $2 = 名字, $3 = 可选命令行关键字
  _cr_f=$1
  _cr_name=$2
  _cr_pat=${3:-}
  [ -r "$_cr_f" ] || return 0
  _cr_p=$(cat "$_cr_f" 2>/dev/null)
  case "$_cr_p" in
    ''|*[!0-9]*) rm -f "$_cr_f"; return 0 ;;
  esac
  # pid 可能被系统复用：命令行对不上就只删 pid 文件，绝不误杀
  if [ -n "$_cr_pat" ] && ! proc_cmdline_has "$_cr_p" "$_cr_pat"; then
    log "drop stale $_cr_name pidfile (pid=$_cr_p is not $_cr_pat)"
    rm -f "$_cr_f" 2>/dev/null
    return 0
  fi
  if pid_alive "$_cr_p"; then
    kill -TERM "$_cr_p" 2>/dev/null
    _cr_i=0
    while [ "$_cr_i" -lt 5 ] && pid_alive "$_cr_p"; do
      sleep 1
      _cr_i=$((_cr_i + 1))
    done
    pid_alive "$_cr_p" && kill -KILL "$_cr_p" 2>/dev/null
    log "stopped $_cr_name pid=$_cr_p"
  fi
  rm -f "$_cr_f" 2>/dev/null
  return 0
}

stop_all() {
  stop_pidfile "$WD_PID_FILE" watchdog watchdog.sh
  stop_pidfile "$PID_FILE" daemon daemon.sh
  return 0
}

protect_self() {
  [ "${oom_protect:-1}" = "1" ] || return 0
  printf '%s' '-900' >/proc/self/oom_score_adj 2>/dev/null
  return 0
}

# 原子单实例锁：mkdir 本身是原子的，避免「先检查再写」的 TOCTOU
# $1 = 锁目录，$2 = 命令行关键字（判断持有者是否真的是同类进程）
lock_acquire() {
  _cr_lock=$1
  _cr_pat=${2:-}
  if mkdir "$_cr_lock" 2>/dev/null; then
    printf '%s' "$$" >"$_cr_lock/pid" 2>/dev/null
    return 0
  fi
  _cr_owner=$(cat "$_cr_lock/pid" 2>/dev/null)
  case "$_cr_owner" in ''|*[!0-9]*) _cr_owner=0 ;; esac
  if [ "$_cr_owner" -gt 0 ] && pid_alive "$_cr_owner"; then
    if [ -z "$_cr_pat" ] || proc_cmdline_has "$_cr_owner" "$_cr_pat"; then
      return 1
    fi
  fi
  # 持有者已死 / pid 被复用 → 清掉陈旧锁再抢
  log "stale lock $(basename "$_cr_lock") (owner=$_cr_owner), reclaiming"
  rm -rf "$_cr_lock" 2>/dev/null
  mkdir "$_cr_lock" 2>/dev/null || return 1
  printf '%s' "$$" >"$_cr_lock/pid" 2>/dev/null
  return 0
}

lock_release() {
  _cr_lock=$1
  [ -d "$_cr_lock" ] || return 0
  [ "$(cat "$_cr_lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$_cr_lock" 2>/dev/null
  return 0
}
