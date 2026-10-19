#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/daemon.sh
#  主守护进程：定时回收、前台舒缓、VM 参数回写、心跳。
#  watchdog.sh 会盯着这个进程的心跳，掉线就把它拉起来。
# ============================================================================

. "$(dirname "$0")/common.sh"

cr_init_dirs
cfg_load
protect_self

# 单实例（mkdir 原子锁，pid 文件只用于展示/兼容）
if ! lock_acquire "$LOCK_DAEMON" daemon.sh; then
  log "daemon already running (lock held), exit"
  exit 0
fi
printf '%s' "$$" >"$PID_FILE" 2>/dev/null
chmod 600 "$PID_FILE" 2>/dev/null

log "daemon start $MODULE_VERSION pid=$$ avail=$(mem_avail_mb)MB total=$(mem_total_mb)MB"
heartbeat_write
st_write daemon_started "$(date +%s)"

_cleanup_done=0
cleanup() {
  [ "$_cleanup_done" = "1" ] && return 0
  _cleanup_done=1
  _cur=$(cat "$PID_FILE" 2>/dev/null)
  [ "$_cur" = "$$" ] && rm -f "$PID_FILE" 2>/dev/null
  lock_release "$LOCK_DAEMON"
  log "daemon exit pid=$$"
  return 0
}
trap 'cleanup; exit 0' INT TERM HUP
trap 'cleanup' EXIT

# 每轮的小睡，分成 1 秒，便于快速响应 stop
nap() {
  _n=${1:-15}
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    sleep 1
    _i=$((_i + 1))
    [ -f "$DATA_DIR/.stop" ] && break
    [ -d "$MODDIR" ] || break
    [ -f "$MODDIR/disable" ] && break
    [ -f "$MODDIR/remove" ] && break
  done
  return 0
}

module_enabled() {
  [ -f "$MODDIR/disable" ] && return 1
  [ -f "$MODDIR/remove" ] && return 1
  return 0
}

_last_reclaim=0
_last_hp=0
_last_app=0
_last_vm=0
_last_protect=0
_last_rotate=0
_last_hash=""

while :; do
  if ! module_enabled; then
    log "module disabled/removed, daemon exit"
    cleanup
    exit 0
  fi

  # 配置变更检测（cksum）
  _hash=$(cfg_cksum)
  if [ "$_hash" != "$_last_hash" ]; then
    [ -n "$_last_hash" ] && log "config changed, reloading"
    cfg_load
    _last_hash=$_hash
  fi

  heartbeat_write
  _now=$(date +%s)

  # 定期刷新输入法 / 桌面保护名单、清理冻结记录
  if [ $((_now - _last_protect)) -ge 1800 ]; then
    protected_dynamic_refresh
    _last_protect=$_now
  fi

  # VM 参数回写（Android 偶尔会重置）；总开关关闭时也不动系统参数
  if [ "${enable:-1}" = "1" ] && [ "${vm_tune:-0}" = "1" ] && [ $((_now - _last_vm)) -ge 300 ]; then
    sh "$CR_BIN/vm_tune.sh" reassert >/dev/null 2>&1
    _last_vm=$_now
  fi

  # 后台回收（screen_off_only 的判断在 reclaim.sh 内部，避免两边逻辑重复）
  if [ "${enable:-1}" = "1" ]; then
    if [ $((_now - _last_reclaim)) -ge "${interval:-15}" ]; then
      sh "$CR_BIN/reclaim.sh" --run >/dev/null 2>&1
      _last_reclaim=$(date +%s)
    fi
  fi

  # 高 PSS 看门狗：总内存不紧张时，单独盯着「特别大的冻结进程」
  if [ "${enable:-1}" = "1" ] && [ "${high_pss_mb:-600}" -gt 0 ]; then
    if [ $((_now - _last_hp)) -ge "${high_pss_interval:-90}" ]; then
      sh "$CR_BIN/reclaim.sh" --run --high-check >/dev/null 2>&1
      _last_hp=$(date +%s)
    fi
  fi

  # 前台舒缓
  if [ "${enable:-1}" = "1" ] && [ "${app_reclaim:-1}" = "1" ]; then
    if [ $((_now - _last_app)) -ge "${app_reclaim_interval:-45}" ]; then
      sh "$CR_BIN/app_relief.sh" >/dev/null 2>&1
      _last_app=$(date +%s)
    fi
  fi

  # 日志轮转
  if [ $((_now - _last_rotate)) -ge 60 ]; then
    log_rotate
    _last_rotate=$_now
  fi

  nap "${interval:-15}"

  # 模块目录消失（卸载/更新窗口）时不要变成无 sleep 的忙循环
  if [ ! -d "$MODDIR" ]; then
    sleep 5
    continue
  fi

  if [ -f "$DATA_DIR/.stop" ]; then
    log "stop flag detected, daemon exit"
    rm -f "$DATA_DIR/.stop" 2>/dev/null
    cleanup
    exit 0
  fi
done
