#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/app_relief.sh
#  前台应用内存舒缓：不杀进程、不杀线程，只让应用释放缓存并把匿名页换出。
#
#  强化点（相对上游实现）：
#    1. 对该包「所有」进程都发 send-trim-memory，而不只是主进程；
#    2. 页换出分多轮（app_pageout_passes），每轮重新读 smaps，按当前 PSS 分配预算；
#    3. 换出后重新测 PSS，日志里直接给出 before/after，方便判断是否真的有效；
#    4. helper 不可用时自动降级为纯 trim，不影响启动；
#    5. 自动触发只在内存真的紧张时（低于触发阈值或 PSI 超标）才动手。
#       内存充足时压前台应用换不来任何好处，只会让正在用的应用缺页卡顿。
#       换出量受 app_pageout_max_mb 严格限制（helper 按实际常驻匿名页记账）。
#
#  用法：app_relief.sh [--force] [--json]
# ============================================================================

. "$(dirname "$0")/common.sh"

FORCE=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  esac
  shift
done

cr_init_dirs
cfg_load

[ "${app_reclaim:-1}" = "1" ] || [ "$FORCE" = "1" ] || {
  log "APP RELIEF skip: app_reclaim=0"
  exit 0
}

emit_json() {
  [ "$JSON" = "1" ] || return 0
  printf '{"ok":%s,"pkg":"%s","before":%s,"after":%s,"freed":%s,"pss_before":%s,"pss_after":%s,"threads":%s,"trim":"%s","pageout":%s}\n' \
    "$1" "${_pkg:-}" "${_before:-0}" "${_after:-0}" "${_freed:-0}" "${_pss_before_mb:-0}" "${_pss_after_mb:-0}" \
    "${_threads:-0}" "${app_trim_level:-RUNNING_LOW}" "${_po_bytes:-0}"
}

# 内存不紧张就什么都不做（--force 是用户手动点的，照做）
if [ "$FORCE" != "1" ]; then
  _pressure=0
  [ "$(mem_avail_mb)" -lt "$(mem_low_threshold_mb)" ] && _pressure=1
  if [ "$_pressure" = "0" ] && [ "${psi_enable:-1}" = "1" ]; then
    _psi=$(psi_some_avg10)
    if [ "$_psi" != "-1" ] && awk -v a="$_psi" -v b="${psi_some_avg10:-25}" 'BEGIN { exit !(a + 0 > b + 0) }'; then
      _pressure=1
    fi
  fi
  if [ "$_pressure" = "0" ]; then
    _before=$(mem_avail_mb); _after=$_before; _freed=0
    emit_json 1
    exit 0
  fi
fi

_pkg=$(fg_pkg_cached)
if [ -z "$_pkg" ]; then
  log "APP RELIEF skip: cannot detect foreground package"
  _ok=0; _before=0; _after=0; _freed=0
  emit_json 0
  exit 0
fi

_pids=$(pids_of_pkg "$_pkg")
if [ -z "$_pids" ]; then
  log "APP RELIEF skip: no process for $_pkg"
  _ok=0
  emit_json 0
  exit 0
fi

# 汇总 PSS / 线程数
_pss_before_kb=0
_threads=0
_npids=0
for _p in $_pids; do
  _v=$(pid_pss_kb "$_p")
  case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
  _t=$(pid_threads "$_p")
  case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
  _pss_before_kb=$((_pss_before_kb + _v))
  _threads=$((_threads + _t))
  _npids=$((_npids + 1))
done
_pss_before_mb=$((_pss_before_kb / 1024))

_need=${app_pss_mb:-900}
if [ "$FORCE" != "1" ]; then
  if [ "$_need" -gt 0 ] && [ "$_pss_before_mb" -lt "$_need" ]; then
    log "APP RELIEF skip: $_pkg pss=${_pss_before_mb}MB < ${_need}MB"
    _before=$(mem_avail_mb); _after=$_before; _freed=0
    emit_json 1
    exit 0
  fi
  _cd=$(since_epoch_file last_app_run)
  if [ "$_cd" -lt "${app_reclaim_cooldown:-90}" ]; then
    log "APP RELIEF skip: cooldown(${_cd}s)"
    _before=$(mem_avail_mb); _after=$_before; _freed=0
    emit_json 1
    exit 0
  fi
fi

_before=$(mem_avail_mb)
_level=${app_trim_level:-RUNNING_LOW}

log "APP RELIEF start pkg=$_pkg pids=$_npids pss=${_pss_before_mb}MB threads=$_threads level=$_level"

# ---------------------------------------------------------------- 1. trim
if [ "${app_trim_all_pids:-1}" = "1" ]; then
  _trim_targets=$_pids
else
  # 只 trim 最大的那个进程
  _big=0; _bigp=""
  for _p in $_pids; do
    _v=$(pid_pss_kb "$_p"); case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
    [ "$_v" -gt "$_big" ] && { _big=$_v; _bigp=$_p; }
  done
  _trim_targets=$_bigp
fi

for _p in $_trim_targets; do
  [ -d "/proc/$_p" ] || continue
  if [ "${dry_run:-0}" = "1" ]; then
    log "DRY trim pid=$_p level=$_level"
  else
    am_trim_pid "$_p" "$_level"
  fi
done

# OEM 的 /proc/<pid>/reclaim（默认关闭）
if [ "${app_proc_reclaim:-0}" = "1" ] && [ "${dry_run:-0}" != "1" ]; then
  for _p in $_trim_targets; do
    [ -w "/proc/$_p/reclaim" ] && printf '1' >"/proc/$_p/reclaim" 2>/dev/null &&
      log "APP RELIEF oem-reclaim pid=$_p"
  done
fi

# ---------------------------------------------------------------- 2. pageout
_po_bytes=0
if [ "${app_pageout:-1}" = "1" ] && [ "${dry_run:-0}" != "1" ] && helper_ready; then
  _total_budget=${app_pageout_max_mb:-192}
  _passes=${app_pageout_passes:-3}
  [ "$_passes" -ge 1 ] 2>/dev/null || _passes=1
  _pass_budget=$((_total_budget / _passes))
  [ "$_pass_budget" -lt 8 ] && _pass_budget=8

  _pass=1
  while [ "$_pass" -le "$_passes" ]; do
    _any=0
    # 按当前 PSS 重新分配本轮预算
    _sum=0
    for _p in $_trim_targets; do
      _v=$(pid_pss_kb "$_p"); case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
      _sum=$((_sum + _v))
    done
    [ "$_sum" -lt 1024 ] && break

    for _p in $_trim_targets; do
      _v=$(pid_pss_kb "$_p"); case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
      [ "$_v" -gt 0 ] || continue
      _share=$((_pass_budget * _v / _sum))
      [ "$_share" -lt 4 ] && _share=4
      _b=$(pageout_pid "$_p" "$_share")
      case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
      _po_bytes=$((_po_bytes + _b))
      [ "$_b" -gt 0 ] && _any=1
      log "APP RELIEF pageout pid=$_p pass=$_pass want=${_share}MB got=$((_b / 1024 / 1024))MB"
    done
    [ "$_any" = "0" ] && break
    _pass=$((_pass + 1))
  done
else
  [ "${app_pageout:-1}" = "1" ] && [ "${dry_run:-0}" != "1" ] &&
    log "APP RELIEF pageout unavailable (helper missing or kernel unsupported), trim only"
fi

sleep 2

# ---------------------------------------------------------------- 3. 复测
_pss_after_kb=0
for _p in $_pids; do
  _v=$(pid_pss_kb "$_p")
  case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
  _pss_after_kb=$((_pss_after_kb + _v))
done
_pss_after_mb=$((_pss_after_kb / 1024))

_after=$(mem_avail_mb)
_freed=$((_after - _before))
[ "$_freed" -lt 0 ] && _freed=0

date +%s >"$STATE_DIR/last_app_run" 2>/dev/null
st_write last_app_freed "$_freed"
st_write last_app_pkg "$_pkg"
st_incr total_app_freed "$_freed" >/dev/null
st_incr total_app_runs 1 >/dev/null

log "APP RELIEF done pkg=$_pkg pss=${_pss_before_mb}MB->${_pss_after_mb}MB avail=${_before}MB->${_after}MB pageout=$((_po_bytes / 1024 / 1024))MB"

emit_json 1
exit 0
