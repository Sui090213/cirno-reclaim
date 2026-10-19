#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/watchdog.sh
#  保活进程：盯着 daemon 的心跳和进程号，掉线就拉起来。
#  它自己也归 service.sh 的守护循环管，所以三层是：
#      service.sh（外层循环） → watchdog.sh（心跳看护） → daemon.sh（干活）
# ============================================================================

. "$(dirname "$0")/common.sh"

cr_init_dirs
cfg_load
protect_self

[ "${keepalive:-1}" = "1" ] || {
  log "watchdog: keepalive=0, exit"
  exit 0
}

if ! lock_acquire "$LOCK_WATCHDOG" watchdog.sh; then
  log "watchdog already running (lock held), exit"
  exit 0
fi
printf '%s' "$$" >"$WD_PID_FILE" 2>/dev/null
chmod 600 "$WD_PID_FILE" 2>/dev/null

log "watchdog start pid=$$ interval=${watchdog_interval:-30}s timeout=${heartbeat_timeout:-180}s"
st_write wd_started "$(date +%s)"

_cleanup_done=0
cleanup() {
  [ "$_cleanup_done" = "1" ] && return 0
  _cleanup_done=1
  _cur=$(cat "$WD_PID_FILE" 2>/dev/null)
  [ "$_cur" = "$$" ] && rm -f "$WD_PID_FILE" 2>/dev/null
  lock_release "$LOCK_WATCHDOG"
  log "watchdog exit pid=$$"
  return 0
}
trap 'cleanup; exit 0' INT TERM HUP
trap 'cleanup' EXIT

cmdline_has() {
  proc_cmdline_has "$1" "$2"
}

# pid 文件里的进程可能被复用，必须核对命令行
daemon_healthy() {
  [ -r "$PID_FILE" ] || return 1
  _p=$(cat "$PID_FILE" 2>/dev/null)
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  pid_alive "$_p" || return 1
  cmdline_has "$_p" "$(daemon_cmdline_pat)" || return 1
  return 0
}

restart_daemon() {
  _now=$(date +%s)
  _last=$(st_read wd_last_restart)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  [ $((_now - _last)) -lt 20 ] && return 0

  log "WATCHDOG: daemon unhealthy (hb=$(since_epoch_file heartbeat)s), restarting"
  stop_pidfile "$PID_FILE" daemon "$(daemon_cmdline_pat)"
  start_daemon
  st_write wd_last_restart "$_now"
  st_incr wd_restarts 1 >/dev/null
  return 0
}

# service.sh 的外层循环也一起看着，避免只有 watchdog 一个人孤军奋战
restart_supervisor() {
  _p=$(st_read supervisor.pid)
  case "$_p" in
    ''|*[!0-9]*) _p=0 ;;
  esac
  if [ "$_p" -gt 0 ] && pid_alive "$_p" && cmdline_has "$_p" "service.sh"; then
    return 0
  fi
  _last=$(st_read wd_last_sup_restart)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
  _now=$(date +%s)
  [ $((_now - _last)) -lt 300 ] && return 0

  log "WATCHDOG: supervisor missing, relaunching service.sh --resume"
  st_write wd_last_sup_restart "$_now"
  sh "$MODDIR/service.sh" --resume >/dev/null 2>&1 &
  return 0
}

while :; do
  if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
    log "watchdog: module disabled/removed, exit"
    cleanup
    exit 0
  fi
  if [ -f "$DATA_DIR/.stop" ]; then
    log "watchdog: stop flag, exit"
    cleanup
    exit 0
  fi

  date +%s >"$STATE_DIR/wd.heartbeat" 2>/dev/null
  chmod 600 "$STATE_DIR/wd.heartbeat" 2>/dev/null

  _hb=$(since_epoch_file heartbeat)
  if daemon_healthy; then
    if [ "$_hb" -gt "${heartbeat_timeout:-180}" ]; then
      restart_daemon
    fi
  else
    restart_daemon
  fi

  # 守护正在跑但心跳明显落后，也重建一次
  [ "$_hb" -gt "$(( ${heartbeat_timeout:-180} * 2 ))" ] && restart_daemon

  restart_supervisor

  sleep "${watchdog_interval:-30}"
done
