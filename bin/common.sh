#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/common.sh
#  所有脚本共享的基础设施：日志、内存读数、PSS、冻结检测、进程管理。
# 严格 POSIX sh（Android 上是 mksh），不要写 bash 专有语法。
# ============================================================================

# 某些管理器（尤其 WebUI 的 ksu.exec）给的 PATH 可能不完整，
# 先补齐再调用任何外部命令，否则 dirname/awk/tail 会“命令不存在”。
PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:/product/bin:/odm/bin:$PATH
export PATH

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
# cgroup v2 根；调试时可以用环境变量 CR_CGROOT 指到别的目录
CR_CGROOT=${CR_CGROOT:-/sys/fs/cgroup}
# 系统适配档案目录（HyperOS / ColorOS）
PROFILES_DIR="$MODDIR/profiles"

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

# MemTotal 不会变，进程内缓存一次，省掉大量 awk fork
mem_total_mb() {
  [ -n "${CR_MEM_TOTAL_MB:-}" ] && { printf '%s' "$CR_MEM_TOTAL_MB"; return 0; }
  _cr_kb=$(meminfo_kb MemTotal)
  [ -n "$_cr_kb" ] || _cr_kb=0
  CR_MEM_TOTAL_MB=$((_cr_kb / 1024))
  printf '%s' "$CR_MEM_TOTAL_MB"
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

swap_free_mb() {
  _cr_kb=$(meminfo_kb SwapFree)
  [ -n "$_cr_kb" ] || _cr_kb=0
  printf '%s' $((_cr_kb / 1024))
}

# 所有 zram 设备实际占用的物理内存（MB）：mm_stat 第 3 列 mem_used_total，单位字节
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

# $1 > $2（支持小数），作为条件使用
frac_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# 当前是否真的「内存紧张」：可用内存低于触发阈值，或 PSI some 超过设定值。
# 供守护进程 / 前台舒缓共用，保证「什么时候该动手」只有一处定义。
# 返回 0 = 紧张，1 = 还宽裕
mem_pressure_now() {
  _cr_avail=$(mem_avail_mb)
  _cr_low=$(mem_low_threshold_mb)
  if [ "$_cr_avail" -lt "$_cr_low" ] 2>/dev/null; then
    return 0
  fi
  if [ "${psi_enable:-1}" = "1" ]; then
    _cr_psi=$(psi_some_avg10)
    if [ "$_cr_psi" != "-1" ] && frac_gt "$_cr_psi" "${psi_some_avg10:-25}"; then
      return 0
    fi
  fi
  return 1
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
#   apps/uid_<uid>/pid_<pid>   新版 AOSP / HyperOS
#   uid_<uid>/pid_<pid>        Android 12~14 的 AOSP 布局
# 只认 apps/ 的话，第二种布局会永远扫不到进程，模块就一直是「空闲」。
# 结果写 CR_CG_APPS；空 = 两种都没有（Cirno 没开 per-pid freezer）。
cg_detect_layout() {
  [ -n "${CR_CG_APPS:-}" ] && return 0
  _cr_found=""
  for _cr_root in "$CR_CGROOT/apps" "$CR_CGROOT"; do
    for _cr_d in "$_cr_root"/uid_*; do
      [ -d "$_cr_d" ] || continue
      _cr_found=$_cr_root
      break
    done
    [ -n "$_cr_found" ] && break
  done
  CR_CG_APPS=$_cr_found
  return 0
}

# 应用 UID 判定：10xxx~19xxx（多用户下 UID 会带 userId*100000 偏移）
cg_uid_is_app() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  _cr_u=$(( $1 % 100000 ))
  [ "$_cr_u" -ge 10000 ] && [ "$_cr_u" -le 19999 ]
}

# 某个 pid 的 cgroup 目录；找不到就返回空
cg_pid_dir() {
  cg_detect_layout
  _cr_uid=$(pid_uid "$1")
  if [ -n "${CR_CG_APPS:-}" ] && [ -n "$_cr_uid" ]; then
    _cr_dir="$CR_CG_APPS/uid_$_cr_uid/pid_$1"
    if [ -d "$_cr_dir" ]; then
      printf '%s' "$_cr_dir"
      return 0
    fi
  fi
  _cr_cg=$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$1/cgroup" 2>/dev/null)
  case "$_cr_cg" in
    ''|/) return 1 ;;
  esac
  [ -d "$CR_CGROOT$_cr_cg" ] || return 1
  printf '%s' "$CR_CGROOT$_cr_cg"
}

# cgroup 目录是否真的被冻结。
# cgroup.events 的 frozen 字段才是「实际」状态：Cirno 按 uid 层整组冻结时，
# pid 层 cgroup.freeze 仍然写 0，只看 cgroup.freeze 会漏掉这些进程。
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

# 冻结检测：先按 Cirno 的 per-pid cgroup，再从 /proc/<pid>/cgroup 推导
pid_frozen() {
  [ -d "/proc/$1" ] || return 1
  _cr_dir=$(cg_pid_dir "$1") || return 1
  cg_dir_frozen "$_cr_dir"
}

pid_set_frozen() {
  _cr_dir=$(cg_pid_dir "$1") || return 1
  [ -w "$_cr_dir/cgroup.freeze" ] || return 1
  printf '%s' "$2" >"$_cr_dir/cgroup.freeze" 2>/dev/null
}

# 诊断用：cgroup 布局 + 进程数 + 冻结数
cg_counts() {
  cg_detect_layout
  [ -n "${CR_CG_APPS:-}" ] || { printf 'layout=not-found'; return 0; }
  _cr_n=0
  _cr_f=0
  for _d in "$CR_CG_APPS"/uid_*/pid_*; do
    [ -d "$_d" ] || continue
    _u=${_d%/pid_*}
    _u=${_u##*/uid_}
    cg_uid_is_app "$_u" || continue
    _cr_n=$((_cr_n + 1))
    cg_dir_frozen "$_d" && _cr_f=$((_cr_f + 1))
  done
  printf 'root=%s app_procs=%s frozen=%s' "$CR_CG_APPS" "$_cr_n" "$_cr_f"
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
# 系统关键进程 + root 管理器 + 两家 OEM 桌面/调度/推送服务。
# 这些包即使被写进 include_packages 也不会被动，属于「硬保护」。
CR_HARD_PROTECT="android com.android.systemui com.android.shell com.android.phone \
com.android.server.telecom com.android.bluetooth com.android.nfc com.android.dialer \
com.android.incallui com.android.keychain com.android.certinstaller com.android.settings \
com.android.launcher com.google.android.gms com.google.android.gsf \
com.google.android.permissioncontroller com.android.permissioncontroller \
com.google.android.packageinstaller com.android.packageinstaller \
com.topjohnwu.magisk me.weishu.kernelsu com.derq.ksunext com.rifsxd.ksunext \
com.sukisu.ultra me.bmax.apatch io.github.a13e300.ksuwebui nep.timeline.cirno \
org.lsposed.manager moe.shizuku.privileged.api \
com.miui.home com.miui.securitycenter com.miui.powerkeeper com.miui.aod com.xiaomi.mipush \
com.oppo.launcher com.oplus.athena com.oplus.battery com.oplus.deepthinker com.oplus.cosa \
com.oplus.uiengine com.oplus.securitypermission com.coloros.securitypermission \
com.coloros.safecenter com.oplus.safecenter com.coloros.phonemanager com.oplus.phonemanager \
com.heytap.mcs com.heytap.htms com.heytap.openid com.coloros.ocs.opencapabilityservice \
com.oplus.ocs com.oplus.appplatform com.oplus.exsystemservice com.oplus.wirelesssettings \
com.coloros.wirelesssettings com.oplus.persist.system"

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
  # 用 IFS 切分 + set -f 关闭通配展开。
  # 不用 ${var%%;*}：mksh 对这类写法里的分号处理有坑。
  [ -n "$2" ] || return 1
  _cr_old_ifs=$IFS
  IFS=';'
  set -f
  for _cr_pat in $2; do
    [ -n "$_cr_pat" ] || continue
    case "$1" in
      $_cr_pat)
        set +f
        IFS=$_cr_old_ifs
        return 0
        ;;
    esac
  done
  set +f
  IFS=$_cr_old_ifs
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

# ---------------------------------------------------------------- 系统识别
# 只读 getprop / 目录判断，不启动任何子进程之外的探测。
# hyperos = 小米 HyperOS / MIUI；coloros = ColorOS / realmeUI / OxygenOS（同一套 OPlus 底座）
rom_detect() {
  if [ -n "$(getprop ro.mi.os.version.name 2>/dev/null)" ] ||
     [ -n "$(getprop ro.miui.ui.version.name 2>/dev/null)" ]; then
    printf '%s' 'hyperos'
    return 0
  fi
  if [ -n "$(getprop ro.build.version.oplusrom 2>/dev/null)" ] ||
     [ -n "$(getprop ro.build.version.opporom 2>/dev/null)" ] ||
     [ -d /my_product ]; then
    printf '%s' 'coloros'
    return 0
  fi
  printf '%s' 'generic'
}

rom_name() {
  _cr_rv=$(getprop ro.mi.os.version.name 2>/dev/null)
  if [ -n "$_cr_rv" ]; then
    printf 'HyperOS %s' "$_cr_rv"
    return 0
  fi
  _cr_rv=$(getprop ro.miui.ui.version.name 2>/dev/null)
  if [ -n "$_cr_rv" ]; then
    printf 'MIUI %s' "$_cr_rv"
    return 0
  fi
  _cr_rv=$(getprop ro.build.version.oplusrom 2>/dev/null)
  if [ -n "$_cr_rv" ]; then
    printf 'ColorOS %s' "$_cr_rv"
    return 0
  fi
  _cr_rv=$(getprop ro.build.version.opporom 2>/dev/null)
  if [ -n "$_cr_rv" ]; then
    printf 'ColorOS %s' "$_cr_rv"
    return 0
  fi
  if [ -d /my_product ]; then
    printf 'ColorOS (OPlus base)'
    return 0
  fi
  _cr_rv=$(getprop ro.build.version.release 2>/dev/null)
  printf 'Other ROM (Android %s)' "${_cr_rv:-?}"
}

# 系统自己管 zram（「内存扩展」）的 ROM：不要替它重建 zram 设备
oem_zram_managed() {
  case "$(rom_detect)" in
    hyperos|coloros) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- 系统适配档案
profile_list() {
  printf '%s' 'hyperos coloros generic'
}

profile_valid() {
  case "${1:-}" in
    hyperos|coloros|generic) return 0 ;;
  esac
  return 1
}

# 打印某个档案要覆盖的 k=v 行；generic 表示不覆盖任何参数
profile_pairs() {
  case "${1:-}" in
    hyperos|coloros) _cr_pp="$PROFILES_DIR/$1.conf" ;;
    *) return 1 ;;
  esac
  [ -r "$_cr_pp" ] || return 1
  cat "$_cr_pp" 2>/dev/null
  return 0
}

profile_show() {
  printf 'device_profile=%s\n' "${device_profile:-generic}"
  printf 'detected=%s\n' "$(rom_detect)"
  printf 'rom=%s\n' "$(rom_name)"
}

# 只改 device_profile，不动其它参数（升级安装 / keep 场景用）
profile_record() {
  profile_valid "${1:-}" || return 1
  printf 'device_profile=%s\n' "$1" | cfg_write_pairs >/dev/null 2>&1 || return 1
  device_profile=$1
  return 0
}

# 应用档案：先写档案里的参数，再落 device_profile
profile_apply() {
  profile_valid "${1:-}" || return 1
  _cr_pa="$1"
  # generic 本来就没有档案文件；hyperos/coloros 缺文件说明安装不完整，要留痕
  if [ "$_cr_pa" != "generic" ] && ! profile_pairs "$_cr_pa" >/dev/null 2>&1; then
    log "WARN profile: $_cr_pa.conf missing, only device_profile will be updated"
  fi
  _cr_pairs=$(profile_pairs "$_cr_pa" 2>/dev/null)
  if [ -n "$_cr_pairs" ]; then
    printf '%s\n' "$_cr_pairs" | cfg_write_pairs >/dev/null 2>&1 || return 1
  fi
  printf 'device_profile=%s\n' "$_cr_pa" | cfg_write_pairs >/dev/null 2>&1 || return 1
  device_profile=$_cr_pa
  log "profile: applied $_cr_pa (rom=$(rom_name))"
  return 0
}

# 开机时处理安装脚本留下的 profile.pending：
#   hyperos / coloros / generic = 套用该档案
#   auto                        = 套用自动识别结果
#   keep                        = 保留用户已有参数，只记录识别结果
profile_bootstrap() {
  _cr_pending=""
  if [ -r "$MODDIR/profile.pending" ]; then
    # 安装脚本用 printf 写入，本身不带换行；这里只取第一行并做白名单校验，
    # 不用 tr 处理转义字符（不同 ROM 的 tr 行为不完全一致）。
    _cr_pending=$(head -n 1 "$MODDIR/profile.pending" 2>/dev/null)
    rm -f "$MODDIR/profile.pending" 2>/dev/null
    case "$_cr_pending" in
      hyperos|coloros|generic|auto|keep) : ;;
      *) _cr_pending="" ;;
    esac
  fi
  _cr_det=$(rom_detect)
  case "$_cr_pending" in
    keep)
      profile_record "$_cr_det"
      st_write profile.applied "$_cr_det"
      log "profile: keep user values, device_profile=$_cr_det (rom=$(rom_name))"
      return 0
      ;;
    auto)
      _cr_pending=$_cr_det
      ;;
  esac
  if profile_valid "$_cr_pending"; then
    if profile_apply "$_cr_pending"; then
      st_write profile.applied "$_cr_pending"
      log "profile: pending applied -> $_cr_pending (rom=$(rom_name))"
    else
      log "WARN profile: apply $_cr_pending failed"
    fi
    return 0
  fi
  # 没有安装标记（例如从旧版直接升级）：只把 auto 收敛成具体值，不覆盖用户参数
  case "${device_profile:-generic}" in
    auto|'')
      profile_record "$_cr_det"
      st_write profile.applied "$_cr_det"
      log "profile: resolved auto -> $_cr_det (rom=$(rom_name))"
      ;;
    *)
      st_write profile.applied "${device_profile:-generic}"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 配置
cfg_defaults() {
  : "${enable:=1}"
  : "${dry_run:=1}"
  : "${interval:=20}"
  : "${boot_delay:=90}"
  : "${log_max_kb:=512}"
  : "${profile:=balanced}"
  : "${device_profile:=generic}"
  : "${reclaim_order:=pageout_first}"
  : "${relief_gate:=1}"
  : "${heartbeat_sec:=45}"

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
  : "${deep_pageout_max_mb:=192}"
  : "${allow_system_uid:=0}"

  # 名单：配置里通常有，这里只是兜底
  : "${include_packages:=}"
  : "${exclude_packages:=}"

  : "${app_reclaim:=1}"
  : "${app_pss_mb:=900}"
  : "${app_reclaim_interval:=60}"
  : "${app_reclaim_cooldown:=90}"
  : "${app_trim_level:=RUNNING_LOW}"
  : "${app_trim_all_pids:=1}"
  : "${app_pageout:=1}"
  : "${app_pageout_max_mb:=192}"
  : "${app_pageout_passes:=3}"
  : "${app_proc_reclaim:=0}"

  : "${vm_tune:=1}"
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
  : "${daemon_engine:=cpp}"
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
  # 只处理空格（配置文件不用 tab），避免依赖 [[:space:]] 这类在 mksh 上
  # 可能引发解析问题的写法。
  while :; do
    case "$_cr_t" in
      ' '*) _cr_t=${_cr_t# } ;;
      *' ') _cr_t=${_cr_t% } ;;
      *) break ;;
    esac
  done
  CFG_TRIMMED=$_cr_t
}

cfg_value_type_ok() {
  # $1 = 键，$2 = 已 trim、已去成对引号的值
  case "$1" in
    include_packages|exclude_packages)
      # 用 grep 校验字符集：把 `;` 放进 case 的方括号模式会让 mksh 直接语法错误
      if printf '%s' "$2" | grep -q '[^A-Za-z0-9_.:;*/+=, -]'; then
        return 1
      fi
      return 0
      ;;
    kill_mode)
      case "$2" in pid|am) return 0 ;; esac
      ;;
    reclaim_order)
      case "$2" in pageout_first|kill_first) return 0 ;; esac
      ;;
    device_profile)
      case "$2" in hyperos|coloros|generic|auto) return 0 ;; esac
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
    daemon_engine)
      case "$2" in cpp|shell) return 0 ;; esac
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
    device_profile) device_profile=$2 ;;
    reclaim_order) reclaim_order=$2 ;;
    relief_gate) relief_gate=$2 ;;
    heartbeat_sec) heartbeat_sec=$2 ;;
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
    daemon_engine) daemon_engine=$2 ;;
    include_packages) include_packages=$2 ;;
    exclude_packages) exclude_packages=$2 ;;
  esac
  return 0
}

# 写入前再夹一层范围，防止 interval=0 这类会引发忙循环的值。
# 与 cfg_value_type_ok 一起构成「类型 + 范围」双重校验。
cfg_value_range_ok() {
  _cr_k=${1:-}
  _cr_v=${2:-}
  case "$_cr_v" in
    \'*\') _cr_v=${_cr_v#\'}; _cr_v=${_cr_v%\'} ;;
    \"*\") _cr_v=${_cr_v#\"}; _cr_v=${_cr_v%\"} ;;
  esac
  cfg_value_type_ok "$_cr_k" "$_cr_v" || return 1
  case "$_cr_k" in
    interval) [ "$_cr_v" -ge 5 ] && [ "$_cr_v" -le 300 ] || return 1 ;;
    watchdog_interval) [ "$_cr_v" -ge 10 ] && [ "$_cr_v" -le 600 ] || return 1 ;;
    heartbeat_timeout) [ "$_cr_v" -ge 60 ] && [ "$_cr_v" -le 1800 ] || return 1 ;;
    heartbeat_sec) [ "$_cr_v" -ge 10 ] && [ "$_cr_v" -le 120 ] || return 1 ;;
    boot_delay) [ "$_cr_v" -le 600 ] || return 1 ;;
    log_max_kb) [ "$_cr_v" -ge 32 ] && [ "$_cr_v" -le 16384 ] || return 1 ;;
    mem_low_mb|mem_target_mb|high_pss_mb|min_process_mb|app_pss_mb) [ "$_cr_v" -le 65536 ] || return 1 ;;
    deep_pageout_max_mb|app_pageout_max_mb) [ "$_cr_v" -le 4096 ] || return 1 ;;
    max_kills_per_run) [ "$_cr_v" -le 64 ] || return 1 ;;
    max_kills_per_hour) [ "$_cr_v" -le 512 ] || return 1 ;;
    min_frozen_min) [ "$_cr_v" -le 1440 ] || return 1 ;;
    max_rounds) [ "$_cr_v" -ge 1 ] && [ "$_cr_v" -le 20 ] || return 1 ;;
    relief_gate) case "$_cr_v" in 0|1) ;; *) return 1 ;; esac ;;
  esac
  return 0
}

# 从 stdin 读 k=v 行，白名单 + 类型/范围校验后原子写回运行时配置。
# 所有值统一单引号写入：即使将来有人又把配置文件 source 回去也不会执行。
# 输出：OK / ERR <原因>
cfg_write_pairs() {
  [ -r "$CONF_FILE" ] || { printf 'ERR no_config'; log "config write FAILED: no_config"; return 1; }
  cp -f "$CONF_FILE" "$CONF_FILE.work" 2>/dev/null || { printf 'ERR copy_failed'; log "config write FAILED: copy_failed"; return 1; }
  _cr_wp_changed=0
  _cr_wp_err=""
  _cr_wp_n=0

  while IFS= read -r _cr_l; do
    case "$_cr_l" in ''|'#'*) continue ;; esac
    case "$_cr_l" in *=*) ;; *) continue ;; esac
    _cr_k=${_cr_l%%=*}
    _cr_v=${_cr_l#*=}
    [ -n "$_cr_k" ] || continue
    if ! cfg_key_allowed "$_cr_k"; then
      _cr_wp_err="unknown_key:$_cr_k"
      continue
    fi
    if ! cfg_value_range_ok "$_cr_k" "$_cr_v"; then
      _cr_wp_err="invalid_value:$_cr_k"
      continue
    fi
    _cr_v=${_cr_v#\'}
    _cr_v=${_cr_v%\'}
    _cr_v="'$_cr_v'"
    awk -v k="$_cr_k" -v v="$_cr_v" '
      BEGIN { done = 0 }
      {
        if (!done && index($0, k "=") == 1) { print k "=" v; done = 1 }
        else print
      }
      END { if (!done) print k "=" v }
    ' "$CONF_FILE.work" >"$CONF_FILE.work2" 2>/dev/null &&
      mv -f "$CONF_FILE.work2" "$CONF_FILE.work" 2>/dev/null
    _cr_wp_changed=1
    _cr_wp_n=$((_cr_wp_n + 1))
  done

  if [ "$_cr_wp_changed" = "1" ] && [ -z "$_cr_wp_err" ]; then
    if sh -n "$CONF_FILE.work" >/dev/null 2>&1; then
      chmod 600 "$CONF_FILE.work" 2>/dev/null
      if mv -f "$CONF_FILE.work" "$CONF_FILE" 2>/dev/null; then
        printf 'OK'
        log "config write: ok ($_cr_wp_n key(s))"
        return 0
      fi
      _cr_wp_err="rename_failed"
    else
      _cr_wp_err="syntax_check_failed"
    fi
  fi
  rm -f "$CONF_FILE.work" "$CONF_FILE.work2" 2>/dev/null
  [ -n "$_cr_wp_err" ] || _cr_wp_err="write_failed"
  # 写失败一定要留痕：WebUI 的「设置保存诊断」会把最近日志一起导出
  log "config write FAILED: $_cr_wp_err (changed=$_cr_wp_changed keys=$_cr_wp_n)"
  printf 'ERR %s' "$_cr_wp_err"
  return 1
}

# 读取配置：解析失败的行计数后忽略，不执行任何内容
# 最后兜底：模块自带的 config.conf 也不见了时，直接生成一份完整默认配置。
# 这样即使安装不完整，WebUI 也能读到配置、用户也能保存。
write_default_config() {
  cat >"$CONF_FILE" <<'CR_EOF'
enable=1
dry_run=1
interval=20
boot_delay=90
log_max_kb=512
profile=balanced
device_profile=generic
reclaim_order=pageout_first
relief_gate=1
heartbeat_sec=45
mem_low_mb=800
mem_low_pct=8
mem_target_mb=1200
mem_target_pct=14
psi_enable=1
psi_some_avg10=25
high_pss_mb=600
high_pss_interval=90
max_kills_per_run=4
max_kills_per_hour=20
max_rounds=4
cooldown_sec=60
min_process_mb=48
min_frozen_min=5
min_oom_score_adj=900
only_frozen=1
kill_mode=pid
protect_foreground=1
screen_off_only=0
drop_caches=0
drop_caches_cooldown=1800
deep_reclaim=1
deep_pageout_max_mb=192
allow_system_uid=0
app_reclaim=1
app_pss_mb=900
app_reclaim_interval=60
app_reclaim_cooldown=90
app_trim_level=RUNNING_LOW
app_trim_all_pids=1
app_pageout=1
app_pageout_max_mb=192
app_pageout_passes=3
app_proc_reclaim=0
vm_tune=1
zram_enable=0
zram_disksize_mb=0
zram_algorithm=lz4
swapfile_enable=0
swapfile_mb=2048
swappiness=80
vfs_cache_pressure=100
dirty_writeback_centisecs=1500
dirty_expire_centisecs=500
page_cluster=1
io_tune=0
read_ahead_kb=128
keepalive=1
watchdog_interval=30
heartbeat_timeout=180
oom_protect=1
daemon_engine=cpp
include_packages=''
exclude_packages='com.tencent.mm;com.tencent.mobileqq;com.eg.android.AlipayGphone;com.taobao.taobao;com.jingdong.app.mall;com.ss.android.ugc.aweme'
CR_EOF
  chmod 600 "$CONF_FILE" 2>/dev/null
  log "config: generated built-in defaults"
  return 0
}

# 配置缺失或为空时恢复：优先复制模块自带的 config.conf，再退回内置默认值
ensure_config() {
  [ -s "$CONF_FILE" ] && return 0
  mkdir -p "$DATA_DIR" 2>/dev/null
  if [ -r "$MODDIR/config.conf" ] && cp -f "$MODDIR/config.conf" "$CONF_FILE" 2>/dev/null; then
    chmod 600 "$CONF_FILE" 2>/dev/null
    log "config: restored from module default"
    return 0
  fi
  write_default_config
}

cfg_load() {
  cfg_defaults
  ensure_config
  [ -r "$CONF_FILE" ] || return 0

  # 保证最后一行以换行结尾：否则 read 在 EOF 拿不到最后一行；
  # 而用 `|| [ -n "$line" ]` 补又可能在无换行时死循环。
  if [ -s "$CONF_FILE" ]; then
    _cr_last=$(tail -c 1 "$CONF_FILE" 2>/dev/null)
    [ -n "$_cr_last" ] && printf '\n' >>"$CONF_FILE" 2>/dev/null
  fi

  _cr_bad=0
  while IFS= read -r _cr_line; do
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
      *' #'*) _cr_v=${_cr_v%%' #'*} ;;
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
  case "${interval:-}" in ''|*[!0-9]*) interval=20 ;; esac
  [ "$interval" -ge 5 ] 2>/dev/null || interval=5
  [ "$interval" -le 300 ] 2>/dev/null || interval=300

  case "${watchdog_interval:-}" in ''|*[!0-9]*) watchdog_interval=30 ;; esac
  [ "$watchdog_interval" -ge 10 ] 2>/dev/null || watchdog_interval=10
  [ "$watchdog_interval" -le 600 ] 2>/dev/null || watchdog_interval=600

  case "${heartbeat_timeout:-}" in ''|*[!0-9]*) heartbeat_timeout=180 ;; esac
  _cr_min=$((interval * 3))
  [ "$heartbeat_timeout" -ge "$_cr_min" ] 2>/dev/null || heartbeat_timeout=$_cr_min
  [ "$heartbeat_timeout" -le 1800 ] 2>/dev/null || heartbeat_timeout=1800

  # 心跳间隔必须明显小于超时，否则 watchdog 会周期性误判掉线
  case "${heartbeat_sec:-}" in ''|*[!0-9]*) heartbeat_sec=45 ;; esac
  [ "$heartbeat_sec" -ge 10 ] 2>/dev/null || heartbeat_sec=10
  _cr_hbmax=$((heartbeat_timeout / 2))
  [ "$_cr_hbmax" -lt 10 ] && _cr_hbmax=10
  [ "$heartbeat_sec" -le "$_cr_hbmax" ] 2>/dev/null || heartbeat_sec=$_cr_hbmax
  [ "$heartbeat_sec" -le 120 ] 2>/dev/null || heartbeat_sec=120

  case "${boot_delay:-}" in ''|*[!0-9]*) boot_delay=90 ;; esac
  [ "$boot_delay" -le 600 ] 2>/dev/null || boot_delay=600

  case "${log_max_kb:-}" in ''|*[!0-9]*) log_max_kb=512 ;; esac
  [ "$log_max_kb" -ge 32 ] 2>/dev/null || log_max_kb=32

  case "${max_rounds:-}" in ''|*[!0-9]*) max_rounds=4 ;; esac
  [ "$max_rounds" -ge 1 ] 2>/dev/null || max_rounds=1
  [ "$max_rounds" -le 20 ] 2>/dev/null || max_rounds=20

  case "${cooldown_sec:-}" in ''|*[!0-9]*) cooldown_sec=60 ;; esac
  [ "$cooldown_sec" -le 86400 ] 2>/dev/null || cooldown_sec=86400

  case "${app_reclaim_interval:-}" in ''|*[!0-9]*) app_reclaim_interval=60 ;; esac
  [ "$app_reclaim_interval" -ge 10 ] 2>/dev/null || app_reclaim_interval=10

  return 0
}

cfg_cksum() {
  cksum "$CONF_FILE" 2>/dev/null | awk '{print $1 "-" $2}'
}

# 给 ctl.sh 用的白名单
cfg_key_allowed() {
  case "$1" in
    enable|dry_run|interval|boot_delay|log_max_kb|profile|device_profile|\
    reclaim_order|relief_gate|heartbeat_sec|\
    mem_low_mb|mem_low_pct|mem_target_mb|mem_target_pct|psi_enable|psi_some_avg10|\
    high_pss_mb|high_pss_interval|max_kills_per_run|max_kills_per_hour|max_rounds|\
    cooldown_sec|min_process_mb|min_frozen_min|min_oom_score_adj|only_frozen|kill_mode|\
    protect_foreground|screen_off_only|drop_caches|drop_caches_cooldown|deep_reclaim|\
    deep_pageout_max_mb|allow_system_uid|\
    app_reclaim|app_pss_mb|app_reclaim_interval|app_reclaim_cooldown|app_trim_level|\
    app_trim_all_pids|app_pageout|app_pageout_max_mb|app_pageout_passes|app_proc_reclaim|\
    vm_tune|zram_enable|zram_disksize_mb|zram_algorithm|swapfile_enable|swapfile_mb|\
    swappiness|vfs_cache_pressure|dirty_writeback_centisecs|dirty_expire_centisecs|\
    page_cluster|io_tune|read_ahead_kb|\
    keepalive|watchdog_interval|heartbeat_timeout|oom_protect|daemon_engine|\
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

# 换出某个进程的私有匿名页，成功时输出真正换出的字节数（helper 按 VmSwap 增量算）
# $3 = art 时连 ART 堆一起换出，只对已冻结的进程用
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

# C++ 守护可用吗（二进制存在且没被配置强制退回 shell）
cpp_daemon_ready() {
  [ "${daemon_engine:-cpp}" = "cpp" ] || return 1
  [ -x "$CR_BIN/cirno_daemon" ]
}

# 当前引擎对应的命令行关键字（用于 pid 存活校验）
daemon_cmdline_pat() {
  if cpp_daemon_ready; then
    printf '%s' "cirno_daemon"
  else
    printf '%s' "daemon.sh"
  fi
}

# cirno_daemon 是 zig cc 静态编译的 musl 二进制，读不了 Android 私有的
# /system/usr/share/zoneinfo/tzdata（那是 Android 自定义格式），TZ 只认 POSIX 串
# （例如 UTC-8）。不给的话 localtime_r 一律按 UTC 记日志，比 bionic 的 date 慢 8 小时，
# 排查时两边的日志时间对不上。这里按当前偏移算一个 POSIX TZ 串，只传给守护进程，
# 不改 shell 侧的 TZ，免得 %Z 从 CST 变成 UTC-8。
cr_daemon_tz() {
  _cr_z=$(date +%z 2>/dev/null)
  case "$_cr_z" in
    [+-][0-9][0-9][0-9][0-9])
      printf '%s\n' "$_cr_z" | awk '{
        inv = (substr($0, 1, 1) == "+") ? "-" : "+"
        h = substr($0, 2, 2) + 0
        m = substr($0, 4, 2) + 0
        if (m > 0) printf "UTC%s%d:%02d", inv, h, m
        else printf "UTC%s%d", inv, h
      }'
      ;;
    *) printf '%s' 'UTC' ;;
  esac
}

start_daemon() {
  _pat=$(daemon_cmdline_pat)
  is_running_pidfile "$PID_FILE" "$_pat" && return 0
  rm -f "$PID_FILE" 2>/dev/null
  _cr_tz=$(cr_daemon_tz)
  if cpp_daemon_ready; then
    if command -v setsid >/dev/null 2>&1; then
      env TZ="$_cr_tz" setsid "$CR_BIN/cirno_daemon" >/dev/null 2>&1 &
    else
      ( env TZ="$_cr_tz" "$CR_BIN/cirno_daemon" >/dev/null 2>&1 & )
    fi
  elif command -v setsid >/dev/null 2>&1; then
    env TZ="$_cr_tz" setsid sh "$CR_BIN/daemon.sh" >/dev/null 2>&1 &
  else
    ( env TZ="$_cr_tz" sh "$CR_BIN/daemon.sh" >/dev/null 2>&1 & )
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
  # 停止期间可能已经有新实例把新的 pid 写进同一个 pidfile（并已重新拿到锁），
  # 那种情况下不能删，否则 supervisor 会以为进程不见了、每 30s 反复拉起。
  _cr_now=$(cat "$_cr_f" 2>/dev/null)
  if [ -n "$_cr_now" ] && [ "$_cr_now" != "$_cr_p" ] && pid_alive "$_cr_now"; then
    log "keep $_cr_name pidfile (new pid=$_cr_now)"
    return 0
  fi
  rm -f "$_cr_f" 2>/dev/null
  return 0
}

stop_all() {
  stop_pidfile "$WD_PID_FILE" watchdog watchdog.sh
  stop_pidfile "$PID_FILE" daemon "$(daemon_cmdline_pat)"
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
