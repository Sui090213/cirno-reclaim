#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/reclaim.sh
#  后台回收引擎：只处理「已冻结 + 缓存级 + 非前台 + 通过名单」的进程。
#
#  用法：
#      reclaim.sh --scan                 # 打印候选
#      reclaim.sh --run   [--manual]     # 执行一次回收
#      reclaim.sh --run --dry-run        # 只记录
#      reclaim.sh --run --json           # 输出 JSON（给 WebUI）
# ============================================================================

. "$(dirname "$0")/common.sh"

CAND_FILE="$STATE_DIR/candidates.txt"
MODE="scan"
MANUAL=0
JSON=0
REASON="auto"

while [ $# -gt 0 ]; do
  case "$1" in
    --scan) MODE="scan" ;;
    --run) MODE="run" ;;
    --manual) MANUAL=1 ;;
    --dry-run) FORCE_DRY=1 ;;
    --json) JSON=1 ;;
    --high-check) HIGH_ONLY=1 ;;
    --reason) shift; REASON=${1:-auto} ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  esac
  shift
done

cr_init_dirs
cfg_load
[ -n "${FORCE_DRY:-}" ] && dry_run=1

# JSON 里的 reason 只允许安全字符，避免 root CLI 传入奇怪内容撑坏 JSON
case "$REASON" in
  ''|*[!A-Za-z0-9_().<>-]*) REASON="auto" ;;
esac

# 单实例：daemon 的自动回收和 WebUI「立即回收」不能同时改同一批状态文件
if ! lock_acquire "$LOCK_RECLAIM" reclaim.sh; then
  log "reclaim already running, skip"
  if [ "$JSON" = "1" ]; then
    printf '{"ok":1,"skipped":1,"reason":"busy","freed":0,"kills":0}\n'
  else
    printf 'busy: another reclaim is running\n'
  fi
  exit 0
fi
trap 'lock_release "$LOCK_RECLAIM"' EXIT
trap 'exit 143' INT TERM HUP

# ---------------------------------------------------------------- 冻结时长
frozen_age_sec() {
  # $1 = pid, $2 = starttime
  _k="$1:$2"
  _t="$STATE_DIR/frozen.tsv"
  _seen=$(awk -v k="$_k" '$1 == k {print $2; exit}' "$_t" 2>/dev/null)
  if [ -z "$_seen" ]; then
    printf '%s %s\n' "$_k" "$(date +%s)" >>"$_t" 2>/dev/null
    printf '0'
  else
    _now=$(date +%s)
    _d=$((_now - _seen))
    [ "$_d" -lt 0 ] && _d=0
    printf '%s' "$_d"
  fi
}

frozen_tsv_prune() {
  _t="$STATE_DIR/frozen.tsv"
  [ -f "$_t" ] || return 0
  _n=$(wc -l <"$_t" 2>/dev/null | tr -d ' ')
  [ -n "$_n" ] || return 0
  [ "$_n" -lt 1500 ] 2>/dev/null && return 0
  : >"$_t.new"
  while read -r _k _ts; do
    _p=${_k%%:*}
    [ -d "/proc/$_p" ] && printf '%s %s\n' "$_k" "$_ts" >>"$_t.new"
  done <"$_t"
  mv -f "$_t.new" "$_t" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- 候选收集
# 单个 pid 的完整过滤 + 记账；收集阶段统一走这里
emit_candidate() {
  _p=$1
  [ -r "/proc/$_p/status" ] || return 1

  _pkg=$(pid_pkg "$_p") || return 1
  [ -n "$_pkg" ] || return 1

  # 应用 UID
  if [ "${allow_system_uid:-0}" != "1" ]; then
    _uid=$(pid_uid "$_p")
    case "$_uid" in ''|*[!0-9]*) return 1 ;; esac
    _uid=$((_uid % 100000))
    [ "$_uid" -ge 10000 ] && [ "$_uid" -le 19999 ] || return 1
  fi

  # 缓存级别
  _oom=$(pid_oom "$_p")
  case "$_oom" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_oom" -ge "$_min_oom" ] || return 1

  # 冻结
  if [ "${only_frozen:-1}" = "1" ]; then
    pid_frozen "$_p" || return 1
  fi

  # 前台保护
  if [ "${protect_foreground:-1}" = "1" ] && [ -n "$_fg" ] && [ "$_pkg" = "$_fg" ]; then
    return 1
  fi

  pkg_protected "$_pkg" && return 1
  pkg_included "$_pkg" || return 1

  _pss=$(pid_pss_kb "$_p")
  case "$_pss" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_pss" -ge "$_min_pss" ] || return 1

  _st=$(pid_starttime "$_p")
  _age=$(frozen_age_sec "$_p" "$_st")
  [ "$_age" -ge "$_min_age" ] || return 1

  printf '%s %s %s %s %s\n' "$_pss" "$_p" "$_pkg" "$_age" "$_st" >>"$CAND_FILE"
  return 0
}

# 优先从 cgroup 里枚举已冻结的 pid：比遍历整个 /proc 便宜得多，
# 而且天然只包含 Cirno 冻结过的进程。
# 返回值：0 = 布局可用（有没有候选都算），1 = 布局不可用（由调用方决定怎么办）
collect_from_cgroup() {
  [ -d /sys/fs/cgroup/apps ] || return 1
  _seen=0
  for _uid_d in /sys/fs/cgroup/apps/uid_*; do
    [ -d "$_uid_d" ] || continue
    _seen=1
    for _pid_d in "$_uid_d"/pid_*; do
      [ -d "$_pid_d" ] || continue
      _fd="$_pid_d/cgroup.freeze"
      [ -r "$_fd" ] || continue
      [ "$(cat "$_fd" 2>/dev/null)" = "1" ] || continue
      _p=${_pid_d##*/pid_}
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      emit_candidate "$_p"
    done
  done
  [ "$_seen" = "1" ]
}

collect_from_proc() {
  for _d in /proc/[0-9]*; do
    [ -r "$_d/status" ] || continue
    emit_candidate "${_d#/proc/}"
  done
  return 0
}

collect_candidates() {
  : >"$CAND_FILE"
  _min_pss=$(( ${min_process_mb:-48} * 1024 ))
  _min_oom=${min_oom_score_adj:-900}
  _min_age=$(( ${min_frozen_min:-5} * 60 ))
  _fg=""
  [ "${protect_foreground:-1}" = "1" ] && _fg=$(fg_pkg_cached)

  if [ "${only_frozen:-1}" = "1" ]; then
    if [ -d /sys/fs/cgroup/apps ]; then
      # 布局存在就只用 cgroup 枚举。没有候选是正常现象，
      # 绝不回退到全量 /proc 扫描（那会在空闲时每 15 秒 fork 数千次）。
      collect_from_cgroup >/dev/null 2>&1
    else
      # 没有 Cirno 的 per-pid freezer 就不可能有冻结进程，直接 idle
      if [ "$(st_read no_cirno_logged)" != "1" ]; then
        log "WARN no /sys/fs/cgroup/apps, Cirno freezer not active (only_frozen=1 -> idle)"
        st_write no_cirno_logged 1
      fi
    fi
  else
    collect_from_proc
  fi

  if [ -s "$CAND_FILE" ]; then
    sort -rn "$CAND_FILE" >"$CAND_FILE.sorted" 2>/dev/null
    mv -f "$CAND_FILE.sorted" "$CAND_FILE" 2>/dev/null
  fi
  return 0
}

frac_gt() {
  # $1 > $2（支持小数），作为条件使用
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'
}

# ---------------------------------------------------------------- 触发判断
need_reclaim() {
  _avail=$(mem_avail_mb)
  _target=$(mem_target_threshold_mb)
  _low=$(mem_low_threshold_mb)

  [ "$MANUAL" = "1" ] && { REASON="manual"; return 0; }

  if [ "$_avail" -lt "$_low" ]; then
    REASON="low_mem(${_avail}<${_low})"
    return 0
  fi

  if [ "${psi_enable:-1}" = "1" ]; then
    _psi=$(psi_some_avg10)
    if [ "$_psi" != "-1" ] && frac_gt "$_psi" "${psi_some_avg10:-25}"; then
      REASON="psi(${_psi})"
      return 0
    fi
  fi
  return 2
}

# ---------------------------------------------------------------- 深回收
deep_pageout() {
  [ "${deep_reclaim:-1}" = "1" ] || return 0
  helper_ready || { log "DEEP skip: pageout helper unavailable"; return 0; }
  _budget=${1:-96}
  [ "$_budget" -gt 0 ] || return 0
  _done=0
  _fg=""
  [ "${protect_foreground:-1}" = "1" ] && _fg=$(fg_pkg_cached)

  for _d in /proc/[0-9]*; do
    [ "$_done" -ge "$_budget" ] && break
    _p=${_d#/proc/}
    [ -r "$_d/status" ] || continue
    _pkg=$(pid_pkg "$_p") || continue
    _oom=$(pid_oom "$_p")
    case "$_oom" in ''|*[!0-9]*) continue ;; esac
    [ "$_oom" -ge "${min_oom_score_adj:-900}" ] || continue
    [ "${protect_foreground:-1}" = "1" ] && [ -n "$_fg" ] && [ "$_pkg" = "$_fg" ] && continue
    pkg_protected "$_pkg" && continue
    pkg_included "$_pkg" || continue
    pid_frozen "$_p" || continue

    _want=$((_budget - _done))
    [ "$_want" -gt 32 ] && _want=32
    _bytes=$(pageout_pid "$_p" "$_want")
    case "$_bytes" in ''|*[!0-9]*) _bytes=0 ;; esac
    _mb=$((_bytes / 1024 / 1024))
    _done=$((_done + _mb))
    [ "$_mb" -gt 0 ] && log "DEEP pid=$_p pkg=$_pkg pageout=${_mb}MB"
  done
  [ "$_done" -gt 0 ] && log "DEEP total=${_done}MB"
  return 0
}

# ---------------------------------------------------------------- 主流程
run_reclaim() {
  _start_avail=$(mem_avail_mb)
  _target=$(mem_target_threshold_mb)
  _total=$(mem_total_mb)
  _max_run=${max_kills_per_run:-4}
  _max_hour=${max_kills_per_hour:-20}
  _kills=0
  _freed=0

  if [ "${screen_off_only:-0}" = "1" ] && [ "$MANUAL" != "1" ]; then
    if screen_on; then
      log "SKIP reason=screen_on_only"
      [ "$JSON" = "1" ] && printf '{"ok":1,"skipped":1,"reason":"screen_on_only","avail":%s,"freed":0,"kills":0}\n' "$_start_avail"
      return 0
    fi
  fi

  if [ "$MANUAL" != "1" ]; then
    _cd=$(since_epoch_file last_run)
    if [ "$_cd" -lt "${cooldown_sec:-60}" ]; then
      log "SKIP reason=cooldown(${_cd}s)"
      [ "$JSON" = "1" ] && printf '{"ok":1,"skipped":1,"reason":"cooldown","avail":%s,"freed":0,"kills":0}\n' "$_start_avail"
      return 0
    fi
  fi

  need_reclaim
  _need=$?

  # 高 PSS 看门狗：总内存不紧张，但某个冻结进程特别大，也要回收
  if [ "$_need" != "0" ] && [ "${HIGH_ONLY:-0}" = "1" ] && [ "${high_pss_mb:-600}" -gt 0 ]; then
    collect_candidates
    _top=$(head -n 1 "$CAND_FILE" 2>/dev/null | awk '{print $1}')
    case "$_top" in ''|*[!0-9]*) _top=0 ;; esac
    if [ "$_top" -ge $(( ${high_pss_mb:-600} * 1024 )) ]; then
      _need=0
      REASON="high_pss($((_top / 1024))MB)"
    fi
  fi

  case "$_need" in
    0) : ;;
    *)
      log "SKIP reason=mem_ok avail=${_start_avail}MB target=${_target}MB"
      [ "$JSON" = "1" ] && printf '{"ok":1,"skipped":1,"reason":"mem_ok","avail":%s,"target":%s,"freed":0,"kills":0}\n' "$_start_avail" "$_target"
      return 0
      ;;
  esac

  log "RECLAIM start reason=$REASON avail=${_start_avail}MB target=${_target}MB dry_run=${dry_run:-0}"

  _round=0
  while [ "$_round" -lt "${max_rounds:-4}" ]; do
    _round=$((_round + 1))
    collect_candidates
    [ -s "$CAND_FILE" ] || break

    _round_kills=0
    while read -r _pss _p _pkg _age _st0; do
      [ "$_kills" -ge "$_max_run" ] && [ "$_max_run" -gt 0 ] && break
      if [ "$_max_hour" -gt 0 ]; then
        _hc=$(hour_count)
        [ "$_hc" -ge "$_max_hour" ] && { log "SKIP hour_cap=$_max_hour"; break 2; }
      fi

      pid_alive "$_p" || continue

      # pid 复用检查：进程的 starttime 必须与扫描时一致
      if [ -n "$_st0" ]; then
        _now_st=$(pid_starttime "$_p")
        [ "$_now_st" = "$_st0" ] || continue
      fi

      # 预检查（避免白白解冻一个已经不该动的进程）
      _oom=$(pid_oom "$_p")
      case "$_oom" in ''|*[!0-9]*) continue ;; esac
      [ "$_oom" -ge "${min_oom_score_adj:-900}" ] || continue
      pkg_protected "$_pkg" && continue
      if [ "${protect_foreground:-1}" = "1" ]; then
        _fg=$(fg_pkg_cached)
        [ -n "$_fg" ] && [ "$_pkg" = "$_fg" ] && continue
      fi

      if [ "${dry_run:-0}" = "1" ]; then
        [ "$_round_kills" -ge "$_max_run" ] && [ "$_max_run" -gt 0 ] && break
        log "DRY would reclaim pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB age=${_age}s"
        _round_kills=$((_round_kills + 1))
        continue
      fi

      # 先解冻，SIGKILL 才能稳定送达
      pid_frozen "$_p" && pid_set_frozen "$_p" 0
      sleep 1

      # 解冻到 kill 之间隔了 1 秒：用户可能刚好点开这个应用、
      # 进程也可能退出后 pid 被复用，所以这里必须整体复核一遍。
      _abort=0
      pid_alive "$_p" || _abort=1
      if [ "$_abort" = "0" ] && [ -n "$_st0" ]; then
        [ "$(pid_starttime "$_p")" = "$_st0" ] || _abort=1
      fi
      if [ "$_abort" = "0" ]; then
        _oom=$(pid_oom "$_p")
        case "$_oom" in ''|*[!0-9]*) _abort=1 ;; esac
      fi
      if [ "$_abort" = "0" ] && [ "$_oom" -lt "${min_oom_score_adj:-900}" ]; then
        _abort=1
      fi
      if [ "$_abort" = "0" ] && pkg_protected "$_pkg"; then
        _abort=1
      fi
      if [ "$_abort" = "0" ] && [ "${protect_foreground:-1}" = "1" ]; then
        _fg=$(fg_pkg_cached)
        [ -n "$_fg" ] && [ "$_pkg" = "$_fg" ] && _abort=1
      fi
      if [ "$_abort" = "0" ] && ! pid_alive "$_p"; then
        _abort=1
      fi

      if [ "$_abort" = "1" ]; then
        # 放弃回收，把进程冻回去，别让它一直裸跑
        pid_alive "$_p" && pid_set_frozen "$_p" 1
        log "SKIP pid=$_p pkg=$_pkg aborted after unfreeze (race)"
        continue
      fi

      if [ "${kill_mode:-pid}" = "am" ]; then
        am_kill_pkg "$_pkg"
      else
        kill -9 "$_p" 2>/dev/null
      fi
      sleep 1

      pid_alive "$_p" && {
        log "WARN pid=$_p pkg=$_pkg still alive after kill"
      }

      _now_avail=$(mem_avail_mb)
      _delta=$((_now_avail - _start_avail - _freed))
      [ "$_delta" -lt 0 ] && _delta=0
      _freed=$((_freed + _delta))
      _kills=$((_kills + 1))
      _round_kills=$((_round_kills + 1))
      hour_add

      log "RECLAIM pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB age=${_age}s freed=${_delta}MB avail=${_now_avail}MB mode=${kill_mode:-pid}"

      [ "$_now_avail" -ge "$_target" ] && break
    done <"$CAND_FILE"

    [ "$_kills" -ge "$_max_run" ] && [ "$_max_run" -gt 0 ] && break
    [ "$(mem_avail_mb)" -ge "$_target" ] && break
    [ "$_round_kills" = "0" ] && break
  done

  # 杀完还紧，就把冻结进程的匿名页换出（不杀进程）
  _avail_now=$(mem_avail_mb)
  if [ "$_avail_now" -lt "$_target" ] && [ "${dry_run:-0}" != "1" ]; then
    deep_pageout "${deep_pageout_max_mb:-96}"
    _avail_now=$(mem_avail_mb)
  fi

  # 最后手段：清页缓存
  if [ "$_avail_now" -lt "$_target" ] && [ "${drop_caches:-0}" = "1" ] && [ "$MANUAL" != "1" ]; then
    if [ "$(since_epoch_file last_drop_caches)" -ge "${drop_caches_cooldown:-1800}" ]; then
      drop_page_cache
      date +%s >"$STATE_DIR/last_drop_caches" 2>/dev/null
      _avail_now=$(mem_avail_mb)
    fi
  fi

  _avail_end=$_avail_now
  _net=$((_avail_end - _start_avail))
  [ "$_net" -lt 0 ] && _net=0

  if [ "${dry_run:-0}" = "1" ]; then
    # 演练同样要限速：写 last_run 让 cooldown 生效，并清理冻结记录，
    # 否则首刷观察模式反而最费 CPU / 日志。
    st_write last_run "$(date +%s)"
    frozen_tsv_prune
  else
    st_write last_run "$(date +%s)"
    st_write last_freed_mb "$_net"
    st_write last_kills "$_kills"
    st_write last_avail "$_avail_end"
    st_write last_reason "$REASON"
    st_incr total_freed_mb "$_net" >/dev/null
    st_incr total_kills "$_kills" >/dev/null
    frozen_tsv_prune
  fi

  log "RECLAIM done kills=$_kills freed=${_net}MB avail=${_avail_end}MB"

  if [ "$JSON" = "1" ]; then
    printf '{"ok":1,"skipped":0,"reason":"%s","avail":%s,"target":%s,"freed":%s,"kills":%s,"dry_run":%s}\n' \
      "$REASON" "$_avail_end" "$_target" "$_net" "$_kills" "${dry_run:-0}"
  fi
  return 0
}

scan_print() {
  collect_candidates
  _avail=$(mem_avail_mb)
  _total=$(mem_total_mb)
  _low=$(mem_low_threshold_mb)
  _tgt=$(mem_target_threshold_mb)
  _psi=$(psi_some_avg10)
  printf 'mem: avail=%sMB total=%sMB low=%sMB target=%sMB psi=%s\n' \
    "$_avail" "$_total" "$_low" "$_tgt" "$_psi"
  if [ ! -s "$CAND_FILE" ]; then
    printf 'no candidates\n'
    return 0
  fi
  printf '%-8s %-7s %-6s %-6s %s\n' 'PSS_MB' 'PID' 'AGE_S' 'FROZEN' 'PACKAGE'
  while read -r _pss _p _pkg _age _st0; do
    printf '%-8s %-7s %-6s %-6s %s\n' "$((_pss / 1024))" "$_p" "$_age" "$(pid_frozen "$_p" && echo 1 || echo 0)" "$_pkg"
  done <"$CAND_FILE"
  return 0
}

case "$MODE" in
  scan) scan_print ;;
  run) run_reclaim ;;
esac
