#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - service.sh
#  开机入口（late_start service）。职责：
#    1. 等开机完成 + boot_delay；
#    2. 应用 VM / zram / swap 调参；
#    3. 拉起守护进程（默认 cirno_daemon，可回退 daemon.sh）与 watchdog.sh；
#    4. 自己作为最外层守护循环，两个进程掉了都补回来。
#  带 --resume 参数时跳过开机等待（由 watchdog 在 supervisor 死掉时调用）。
# ============================================================================

. "$(dirname "$0")/bin/common.sh"

RESUME=0
[ "${1:-}" = "--resume" ] && RESUME=1

cr_init_dirs
cfg_load
protect_self

# 防重复启动
_p=$(st_read supervisor.pid)
if [ -n "$_p" ] && [ "$_p" != "$$" ] && pid_alive "$_p" && proc_cmdline_has "$_p" "service.sh"; then
  log "service.sh already running (pid=$_p), duplicate exit"
  exit 0
fi
st_write supervisor.pid "$$"
st_write boot.service "$(date +%s)"

_cleanup_done=0
cleanup() {
  [ "$_cleanup_done" = "1" ] && return 0
  _cleanup_done=1
  _cur=$(st_read supervisor.pid)
  [ "$_cur" = "$$" ] && rm -f "$STATE_DIR/supervisor.pid" 2>/dev/null
  return 0
}
trap 'cleanup; exit 0' INT TERM HUP
trap 'cleanup' EXIT

if [ "$RESUME" = "0" ]; then
  _i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] &&
        [ "$(getprop dev.bootcomplete 2>/dev/null)" != "1" ]; do
    sleep 5
    _i=$((_i + 1))
    [ "$_i" -ge 120 ] && break
  done
  log "service: boot_completed=$([ "$_i" -ge 120 ] && echo timeout || echo yes), delay ${boot_delay:-90}s"
  _i=0
  while [ "$_i" -lt "${boot_delay:-90}" ]; do
    sleep 5
    _i=$((_i + 5))
    [ -f "$MODDIR/disable" ] && break
  done
fi

# 总开关关闭时不要碰系统内存参数
if [ "${enable:-1}" = "1" ] && [ "${vm_tune:-0}" = "1" ]; then
  if [ "$RESUME" = "0" ]; then
    sh "$CR_BIN/vm_tune.sh" apply
  else
    # resume 只做回写，绝不能重建 zram / swapfile
    sh "$CR_BIN/vm_tune.sh" reassert
  fi
fi

start_daemon
start_watchdog

log "service: supervisor loop start pid=$$"

_i=0
while :; do
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "service: module disabled/removed, stopping"
    stop_all
    cleanup
    exit 0
  fi
  if [ -f "$DATA_DIR/.stop" ]; then
    log "service: stop flag, stopping"
    rm -f "$DATA_DIR/.stop" 2>/dev/null
    stop_all
    cleanup
    exit 0
  fi

  if ! is_running_pidfile "$PID_FILE"; then
    log "service: daemon missing, starting"
    start_daemon
  fi

  if [ "${keepalive:-1}" = "1" ] && ! is_running_pidfile "$WD_PID_FILE"; then
    log "service: watchdog missing, starting"
    start_watchdog
  fi

  # 心跳长时间不动，直接重建
  _hb=$(since_epoch_file heartbeat)
  if [ "$_hb" -gt "$(( ${heartbeat_timeout:-180} * 3 ))" ]; then
    log "service: heartbeat stale (${_hb}s), restarting daemon"
    stop_pidfile "$PID_FILE" daemon "$(daemon_cmdline_pat)"
    start_daemon
  fi

  _i=$((_i + 1))
  [ $((_i % 60)) -eq 0 ] && log "service: alive avail=$(mem_avail_mb)MB"
  sleep 30
done
