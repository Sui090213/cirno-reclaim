#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/reclaim.sh
#  后台回收引擎：只处理「已冻结 + 缓存级 + 非前台 + 通过名单」的进程。
#
#  reclaim_order=pageout_first（默认）时的顺序，配合 Cirno「后台不死」的目标：
#    1. 先把冻结进程的匿名页压进 zram（进程不死，切回来不冷启动）；
#    2. 仍低于目标，才按 PSS 从大到小结束冻结进程；
#    3. 最后才考虑 drop_caches。
#  reclaim_order=kill_first 是上游的顺序：先杀，杀完不够再换出。
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
  ''|*[!A-Za-z0-9_.\(\)\<\>-]*) REASON="auto" ;;
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
# $2 = 1 表示调用方已经确认过冻结（cgroup 枚举时），不再重复读
emit_candidate() {
  _p=$1
  _known_frozen=${2:-0}
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
  if [ "${only_frozen:-1}" = "1" ] && [ "$_known_frozen" != "1" ]; then
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
# 而且天然只包含 Cirno 冻结过的进程（Cirno 会关掉系统自带的 freezer）。
# 布局两种都认（见 common.sh 的 cg_detect_layout），与 Cirno 自己的判断一致。
# 返回值：0 = 布局可用（有没有候选都算），1 = 布局不可用（由调用方决定怎么办）
collect_from_cgroup() {
  cg_detect_layout
  [ -n "$CR_CG_APPS" ] || return 1
  for _uid_d in "$CR_CG_APPS"/uid_*; do
    [ -d "$_uid_d" ] || continue
    # 只看应用 UID，系统进程的 cgroup 不用读
    if [ "${allow_system_uid:-0}" != "1" ]; then
      _u=${_uid_d##*/uid_}
      case "$_u" in ''|*[!0-9]*) continue ;; esac
      _u=$((_u % 100000))
      [ "$_u" -ge 10000 ] && [ "$_u" -le 19999 ] || continue
    fi
    for _pid_d in "$_uid_d"/pid_*; do
      [ -d "$_pid_d" ] || continue
      cg_dir_frozen "$_pid_d" || continue
      _p=${_pid_d##*/pid_}
      case "$_p" in ''|*[!0-9]*) continue ;; esac
      emit_candidate "$_p" 1
    done
  done
  return 0
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
  # 桌面 / 输入法保护名单平时由 daemon 刷新；手动回收可能抢在它前面，缺了就现取一次
  [ -r "$STATE_DIR/protect.dynamic" ] || protected_dynamic_refresh

  if [ "${only_frozen:-1}" = "1" ]; then
    # 布局存在就只用 cgroup 枚举。没有候选是正常现象，
    # 绝不回退到全量 /proc 扫描（那会在空闲时每 15 秒 fork 数千次）。
    if ! collect_from_cgroup >/dev/null 2>&1; then
      # 没有 per-pid cgroup 就不可能有 Cirno 冻结的进程，直接 idle
      if [ "$(st_read no_cirno_logged)" != "1" ]; then
        log "WARN no per-pid app cgroup under $CR_CGROOT, Cirno freezer not active (only_frozen=1 -> idle)"
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

# ---------------------------------------------------------------- 可用内存估算
# 内核把刚释放的页先放进每个 CPU 的缓存（pcp 列表），这部分不算进 MemAvailable，
# 要过好几秒才慢慢放回。实测 6.x 内核换出 400MB 后 MemAvailable 立刻只涨了 ~130MB。
# 回收途中如果只看 MemAvailable，会低估刚释放的量，多杀本来不用杀的应用。
# 所以回收途中用「起点 + 实际释放量」估算，和实测值取大。
# EST_AVAIL 由调用方维护；est_refresh 把它和当前实测值取大。
est_refresh() {
  _m=$(mem_avail_mb)
  [ "$_m" -gt "${EST_AVAIL:-0}" ] && EST_AVAIL=$_m
  return 0
}

# ---------------------------------------------------------------- 深回收
# 把冻结进程的匿名页（含 ART 堆）换出到 zram，进程不死。
# 候选与回收共用一套过滤（冻结、缓存级、非前台、名单、PSS、冻结时长），
# 按 PSS 从大到小处理，直到用完预算或（估算的）可用内存达到目标。
# 换出的净收益 = 实际换出量 - zram 自身多占的内存，计入 EST_AVAIL。
# $1 = 预算 MB，$2 = 目标可用内存 MB（0 = 只看预算）
# 结果写在 DEEP_DONE_MB，并更新 EST_AVAIL
deep_pageout() {
  DEEP_DONE_MB=0
  est_refresh
  [ "${deep_reclaim:-1}" = "1" ] || return 0
  _budget=${1:-256}
  _goal=${2:-0}
  [ "$_budget" -gt 0 ] || return 0
  if [ "${dry_run:-0}" != "1" ] && ! helper_ready; then
    log "DEEP skip: pageout helper unavailable"
    return 0
  fi

  collect_candidates
  [ -s "$CAND_FILE" ] || return 0

  _done=0
  _est0=$EST_AVAIL
  _z0=$(zram_used_mb)
  while read -r _pss _p _pkg _age _st0; do
    [ "$_done" -ge "$_budget" ] && break
    if [ "$_goal" -gt 0 ]; then
      est_refresh
      [ "$EST_AVAIL" -ge "$_goal" ] && break
    fi
    pid_alive "$_p" || continue
    [ "$(pid_starttime "$_p")" = "$_st0" ] || continue

    _want=$((_budget - _done))
    if [ "${dry_run:-0}" = "1" ]; then
      log "DRY would pageout pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB want=${_want}MB"
      continue
    fi

    _bytes=$(pageout_pid "$_p" "$_want" art)
    case "$_bytes" in ''|*[!0-9]*) _bytes=0 ;; esac
    _mb=$((_bytes / 1024 / 1024))
    _done=$((_done + _mb))
    _gain=$((_done - ($(zram_used_mb) - _z0)))
    [ "$_gain" -lt 0 ] && _gain=0
    [ $((_est0 + _gain)) -gt "$EST_AVAIL" ] && EST_AVAIL=$((_est0 + _gain))
    [ "$_mb" -gt 0 ] && log "DEEP pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB pageout=${_mb}MB"
  done <"$CAND_FILE"

  DEEP_DONE_MB=$_done
  est_refresh
  [ "$_done" -gt 0 ] && log "DEEP total=${_done}MB avail=$(mem_avail_mb)MB est=${EST_AVAIL}MB"
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
  _paged=0
  EST_AVAIL=$_start_avail

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

  # 高 PSS 看门狗：总内存不紧张，但某个冻结进程特别大
  if [ "$_need" != "0" ] && [ "${HIGH_ONLY:-0}" = "1" ] && [ "${high_pss_mb:-600}" -gt 0 ]; then
    collect_candidates
    _top=$(head -n 1 "$CAND_FILE" 2>/dev/null | awk '{print $1}')
    case "$_top" in ''|*[!0-9]*) _top=0 ;; esac
    if [ "$_top" -ge $(( ${high_pss_mb:-600} * 1024 )) ]; then
      REASON="high_pss($((_top / 1024))MB)"
      if [ "${reclaim_order:-pageout_first}" = "pageout_first" ]; then
        # 内存并不紧张：只把这个大进程压进 zram，不结束它
        _hp_pid=$(head -n 1 "$CAND_FILE" | awk '{print $2}')
        _hp_pkg=$(head -n 1 "$CAND_FILE" | awk '{print $3}')
        if [ "${dry_run:-0}" = "1" ]; then
          log "DRY would pageout pid=$_hp_pid pkg=$_hp_pkg reason=$REASON"
          _hp_mb=0
        else
          _hp_b=$(pageout_pid "$_hp_pid" "${deep_pageout_max_mb:-256}" art)
          case "$_hp_b" in ''|*[!0-9]*) _hp_b=0 ;; esac
          _hp_mb=$((_hp_b / 1024 / 1024))
          log "HIGH pid=$_hp_pid pkg=$_hp_pkg reason=$REASON pageout=${_hp_mb}MB"
        fi
        st_write last_run "$(date +%s)"
        [ "$JSON" = "1" ] && printf '{"ok":1,"skipped":0,"reason":"%s","avail":%s,"target":%s,"freed":0,"kills":0,"paged":%s,"dry_run":%s}\n' \
          "$REASON" "$(mem_avail_mb)" "$_target" "$_hp_mb" "${dry_run:-0}"
        return 0
      fi
      _need=0
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

  log "RECLAIM start reason=$REASON avail=${_start_avail}MB target=${_target}MB order=${reclaim_order:-pageout_first} dry_run=${dry_run:-0}"

  # 1. 先换出（进程不死）
  if [ "${reclaim_order:-pageout_first}" = "pageout_first" ]; then
    deep_pageout "${deep_pageout_max_mb:-256}" "$_target"
    _paged=$DEEP_DONE_MB
  fi

  # 2. 仍低于目标才结束进程
  _round=0
  while est_refresh && [ "$EST_AVAIL" -lt "$_target" ] && [ "$_round" -lt "${max_rounds:-4}" ]; do
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

      if [ "${dry_run:-0}" = "1" ]; then
        [ "$_round_kills" -ge "$_max_run" ] && [ "$_max_run" -gt 0 ] && break
        log "DRY would reclaim pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB age=${_age}s"
        _round_kills=$((_round_kills + 1))
        continue
      fi

      # 扫描到现在可能过了几秒：整体复核一遍再动手
      pid_alive "$_p" || continue
      # pid 复用检查：进程的 starttime 必须与扫描时一致
      [ "$(pid_starttime "$_p")" = "$_st0" ] || continue
      _oom=$(pid_oom "$_p")
      case "$_oom" in ''|*[!0-9]*) continue ;; esac
      [ "$_oom" -ge "${min_oom_score_adj:-900}" ] || continue
      pkg_protected "$_pkg" && continue
      if [ "${protect_foreground:-1}" = "1" ]; then
        _fg=$(fg_pkg_cached)
        [ -n "$_fg" ] && [ "$_pkg" = "$_fg" ] && continue
      fi
      if [ "${only_frozen:-1}" = "1" ]; then
        pid_frozen "$_p" || continue
      fi

      # 冻结状态下直接 SIGKILL：cgroup v2 的冻结进程可以被致命信号结束，
      # 系统自己的 lmkd 也是这么杀的。不先解冻，就没有「解冻那一秒应用在跑」的窗口，
      # 也不会让 Cirno 记录的冻结状态和实际不一致。
      if [ "${kill_mode:-pid}" = "am" ]; then
        am_kill_pkg "$_pkg"
      else
        kill -9 "$_p" 2>/dev/null
      fi
      sleep 1

      if pid_alive "$_p" && [ "$(pid_starttime "$_p")" = "$_st0" ]; then
        # 极少数情况下（老式 v1 freezer）冻结进程收不到信号：解冻后再杀一次
        if pid_frozen "$_p" && pid_set_frozen "$_p" 0; then
          kill -9 "$_p" 2>/dev/null
          sleep 1
        fi
        if pid_alive "$_p" && [ "$(pid_starttime "$_p")" = "$_st0" ]; then
          pid_set_frozen "$_p" 1
          log "WARN pid=$_p pkg=$_pkg still alive after kill"
          continue
        fi
      fi

      # 结束一个进程，至少释放它常驻的那部分（PSS）
      EST_AVAIL=$((EST_AVAIL + _pss / 1024))
      est_refresh
      _kills=$((_kills + 1))
      _round_kills=$((_round_kills + 1))
      hour_add

      log "RECLAIM pid=$_p pkg=$_pkg pss=$((_pss / 1024))MB age=${_age}s avail=$(mem_avail_mb)MB est=${EST_AVAIL}MB mode=${kill_mode:-pid}"

      [ "$EST_AVAIL" -ge "$_target" ] && break
    done <"$CAND_FILE"

    [ "$_kills" -ge "$_max_run" ] && [ "$_max_run" -gt 0 ] && break
    [ "$_round_kills" = "0" ] && break
    # 演练模式不会真的释放内存，跑一批就够了
    [ "${dry_run:-0}" = "1" ] && break
  done

  # 上游顺序：杀完还紧，再换出
  est_refresh
  if [ "${reclaim_order:-pageout_first}" = "kill_first" ] && [ "$EST_AVAIL" -lt "$_target" ]; then
    deep_pageout "${deep_pageout_max_mb:-256}" "$_target"
    _paged=$DEEP_DONE_MB
  fi

  # 最后手段：清页缓存
  est_refresh
  if [ "$EST_AVAIL" -lt "$_target" ] && [ "${drop_caches:-0}" = "1" ] && [ "$MANUAL" != "1" ] && [ "${dry_run:-0}" != "1" ]; then
    if [ "$(since_epoch_file last_drop_caches)" -ge "${drop_caches_cooldown:-1800}" ]; then
      drop_page_cache
      date +%s >"$STATE_DIR/last_drop_caches" 2>/dev/null
      est_refresh
    fi
  fi

  # 结果按估算值报告：此刻的 MemAvailable 还没跟上刚释放的内存
  _avail_end=$EST_AVAIL
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
    st_write last_paged_mb "$_paged"
    st_write last_avail "$_avail_end"
    st_write last_reason "$REASON"
    st_incr total_freed_mb "$_net" >/dev/null
    st_incr total_kills "$_kills" >/dev/null
    st_incr total_paged_mb "$_paged" >/dev/null
    frozen_tsv_prune
  fi

  log "RECLAIM done kills=$_kills paged=${_paged}MB freed=${_net}MB avail=$(mem_avail_mb)MB est=${_avail_end}MB"

  if [ "$JSON" = "1" ]; then
    printf '{"ok":1,"skipped":0,"reason":"%s","avail":%s,"target":%s,"freed":%s,"kills":%s,"paged":%s,"dry_run":%s}\n' \
      "$REASON" "$_avail_end" "$_target" "$_net" "$_kills" "$_paged" "${dry_run:-0}"
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
  printf 'cgroup: %s\n' "${CR_CG_APPS:-not found}"
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
