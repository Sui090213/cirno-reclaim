#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/ctl.sh
#  命令行 / WebUI 的统一入口。
#
#  ctl.sh status [--json]      状态（JSON 或人读）
#  ctl.sh scan                 候选进程
#  ctl.sh run [--manual|--json] 立即回收
#  ctl.sh apprelief [--json]   舒缓前台
#  ctl.sh log [N]              最近 N 行日志
#  ctl.sh diag                 反馈用的诊断信息
#  ctl.sh config               当前运行时配置原文
#  ctl.sh save                 从 stdin 读 k=v 并保存
#  ctl.sh set k=v [k=v ...]    保存若干项
#  ctl.sh preset <name>        应用预设 conservative|balanced|aggressive
#  ctl.sh restart|start|stop
# ============================================================================

. "$(dirname "$0")/common.sh"

cr_init_dirs
cfg_load

REPO_URL="https://github.com/yishisanren/cirno-reclaim"

CMD=${1:-status}
[ $# -gt 0 ] && shift

num() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "${2:-0}" ;;
    *) printf '%s' "$1" ;;
  esac
}

bool() {
  if "$@" >/dev/null 2>&1; then printf '1'; else printf '0'; fi
}

proc_healthy() {
  _f=$1
  _pat=$2
  [ -r "$_f" ] || return 1
  _p=$(cat "$_f" 2>/dev/null)
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  pid_alive "$_p" || return 1
  proc_cmdline_has "$_p" "$_pat" || return 1
  return 0
}

status_json() {
  _d=$(bool proc_healthy "$PID_FILE" daemon.sh)
  _w=$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)
  _hb=$(since_epoch_file heartbeat)
  _wd=$(since_epoch_file wd.heartbeat)
  _po=$(bool helper_ready)
  cg_detect_layout
  _cg=0
  [ -n "$CR_CG_APPS" ] && _cg=1
  printf '{"ok":1,"version":"%s","avail":%s,"total":%s,"swap_total":%s,"swap_free":%s,"psi":%s,"daemon":%s,"watchdog":%s,"hb_age":%s,"wd_age":%s,"enable":%s,"dry_run":%s,"screen_off_only":%s,"mem_low":%s,"mem_target":%s,"total_freed":%s,"total_kills":%s,"total_app_freed":%s,"last_run":%s,"last_freed":%s,"last_kills":%s,"last_reason":"%s","last_avail":%s,"last_app_pkg":"%s","last_app_freed":%s,"pageout":%s,"profile":"%s","zram":%s,"swapfile":%s,"total_paged":%s,"last_paged":%s,"order":"%s","coloros":%s,"cgroup":%s}\n' \
    "$MODULE_VERSION" \
    "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_total_mb)" "$(swap_free_mb)" \
    "$(psi_some_avg10)" "$_d" "$_w" "$_hb" "$_wd" \
    "$(num "${enable:-1}")" "$(num "${dry_run:-0}")" "$(num "${screen_off_only:-0}")" \
    "$(mem_low_threshold_mb)" "$(mem_target_threshold_mb)" \
    "$(num "$(st_read total_freed_mb)")" "$(num "$(st_read total_kills)")" "$(num "$(st_read total_app_freed)")" \
    "$(num "$(st_read last_run)")" "$(num "$(st_read last_freed_mb)")" "$(num "$(st_read last_kills)")" \
    "$(st_read last_reason)" "$(num "$(st_read last_avail)")" \
    "$(st_read last_app_pkg)" "$(num "$(st_read last_app_freed)")" \
    "$_po" "${profile:-balanced}" "$(num "${zram_enable:-0}")" "$(num "${swapfile_enable:-0}")" \
    "$(num "$(st_read total_paged_mb)")" "$(num "$(st_read last_paged_mb)")" "${reclaim_order:-pageout_first}" \
    "$(bool is_coloros)" "$_cg"
}

status_text() {
  printf 'version   : %s\n' "$MODULE_VERSION"
  printf 'daemon    : %s (heartbeat %ss ago)\n' "$(proc_healthy "$PID_FILE" daemon.sh && echo running || echo stopped)" "$(since_epoch_file heartbeat)"
  printf 'watchdog  : %s (heartbeat %ss ago)\n' "$(proc_healthy "$WD_PID_FILE" watchdog.sh && echo running || echo stopped)" "$(since_epoch_file wd.heartbeat)"
  printf 'memory    : avail=%sMB total=%sMB swap=%s/%sMB psi=%s\n' \
    "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_free_mb)" "$(swap_total_mb)" "$(psi_some_avg10)"
  printf 'trigger   : low=%sMB target=%sMB\n' "$(mem_low_threshold_mb)" "$(mem_target_threshold_mb)"
  printf 'mode      : order=%s dry_run=%s\n' "${reclaim_order:-pageout_first}" "${dry_run:-0}"
  printf 'totals    : reclaimed=%s procs, paged=%sMB, freed=%sMB, app_freed=%sMB\n' \
    "$(num "$(st_read total_kills)")" "$(num "$(st_read total_paged_mb)")" \
    "$(num "$(st_read total_freed_mb)")" "$(num "$(st_read total_app_freed)")"
  printf 'last run  : %sMB freed, %sMB paged, %s procs, reason=%s\n' \
    "$(num "$(st_read last_freed_mb)")" "$(num "$(st_read last_paged_mb)")" \
    "$(num "$(st_read last_kills)")" "$(st_read last_reason)"
}

# ---------------------------------------------------------------- 配置写入
validate_value() {
  _k=$1
  _v=$2

  # 去掉成对引号后再校验
  case "$_v" in
    \'*\') _v=${_v#\'}; _v=${_v%\'} ;;
    \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
  esac

  # 类型必须和解析器一致（数字 / 精确枚举 / 名单字符集）
  cfg_value_type_ok "$_k" "$_v" || return 1

  # 再夹一层范围，防止 interval=0 这类会引发忙循环的值
  case "$_k" in
    interval) [ "$_v" -ge 5 ] && [ "$_v" -le 300 ] || return 1 ;;
    watchdog_interval) [ "$_v" -ge 10 ] && [ "$_v" -le 600 ] || return 1 ;;
    heartbeat_timeout) [ "$_v" -ge 60 ] && [ "$_v" -le 1800 ] || return 1 ;;
    boot_delay) [ "$_v" -le 600 ] || return 1 ;;
    log_max_kb) [ "$_v" -ge 32 ] && [ "$_v" -le 16384 ] || return 1 ;;
    mem_low_mb|mem_target_mb|high_pss_mb|min_process_mb|app_pss_mb) [ "$_v" -le 65536 ] || return 1 ;;
    max_kills_per_run) [ "$_v" -le 64 ] || return 1 ;;
    max_kills_per_hour) [ "$_v" -le 512 ] || return 1 ;;
    min_frozen_min) [ "$_v" -le 1440 ] || return 1 ;;
    deep_pageout_max_mb) [ "$_v" -le 4096 ] || return 1 ;;
    max_rounds) [ "$_v" -ge 1 ] && [ "$_v" -le 20 ] || return 1 ;;
  esac
  return 0
}

# stdin: k=v 行；输出 OK 或 ERR <原因>
apply_pairs() {
  [ -r "$CONF_FILE" ] || { printf 'ERR no_config'; return 1; }
  cp -f "$CONF_FILE" "$CONF_FILE.work" 2>/dev/null || { printf 'ERR copy_failed'; return 1; }
  _changed=0
  _err=""

  while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue ;; esac
    case "$_l" in *=*) ;; *) continue ;; esac
    _k=${_l%%=*}
    _v=${_l#*=}
    [ -n "$_k" ] || continue
    if ! cfg_key_allowed "$_k"; then
      _err="unknown_key:$_k"
      continue
    fi
    if ! validate_value "$_k" "$_v"; then
      _err="invalid_value:$_k"
      continue
    fi
    # 所有值统一单引号写入：即使将来有人又把配置文件 source 回去也不会执行
    _v=${_v#\'}
    _v=${_v%\'}
    _v="'$_v'"
    awk -v k="$_k" -v v="$_v" '
      BEGIN { done = 0 }
      {
        if (!done && index($0, k "=") == 1) { print k "=" v; done = 1 }
        else print
      }
      END { if (!done) print k "=" v }
    ' "$CONF_FILE.work" >"$CONF_FILE.work2" 2>/dev/null &&
      mv -f "$CONF_FILE.work2" "$CONF_FILE.work" 2>/dev/null
    _changed=1
  done

  if [ "$_changed" = "1" ] && [ -z "$_err" ] && sh -n "$CONF_FILE.work" >/dev/null 2>&1; then
    chmod 600 "$CONF_FILE.work" 2>/dev/null
    if mv -f "$CONF_FILE.work" "$CONF_FILE" 2>/dev/null; then
      printf 'OK'
      return 0
    fi
  fi
  rm -f "$CONF_FILE.work" "$CONF_FILE.work2" 2>/dev/null
  [ -n "$_err" ] || _err="write_failed"
  printf 'ERR %s' "$_err"
  return 1
}

preset_pairs() {
  case "$1" in
    conservative)
      cat <<'EOF'
profile=conservative
interval=30
mem_low_mb=600
mem_low_pct=6
mem_target_mb=900
mem_target_pct=10
psi_enable=0
high_pss_mb=900
max_kills_per_run=2
max_kills_per_hour=8
min_frozen_min=15
min_process_mb=96
deep_reclaim=1
deep_pageout_max_mb=128
reclaim_order=pageout_first
drop_caches=0
app_pss_mb=1200
app_pageout=0
app_pageout_passes=1
EOF
      ;;
    balanced)
      cat <<'EOF'
profile=balanced
interval=15
mem_low_mb=800
mem_low_pct=8
mem_target_mb=1200
mem_target_pct=14
psi_enable=1
high_pss_mb=600
max_kills_per_run=4
max_kills_per_hour=20
min_frozen_min=5
min_process_mb=48
deep_reclaim=1
deep_pageout_max_mb=256
reclaim_order=pageout_first
drop_caches=0
app_pss_mb=900
app_pageout=1
app_pageout_passes=3
EOF
      ;;
    aggressive)
      cat <<'EOF'
profile=aggressive
interval=10
mem_low_mb=1600
mem_low_pct=12
mem_target_mb=2200
mem_target_pct=18
psi_enable=1
psi_some_avg10=18
high_pss_mb=400
max_kills_per_run=6
max_kills_per_hour=36
min_frozen_min=2
min_process_mb=32
deep_reclaim=1
deep_pageout_max_mb=512
reclaim_order=pageout_first
drop_caches=1
app_pss_mb=700
app_pageout=1
app_pageout_passes=4
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

do_preset() {
  _name=$1
  _tmp="$DATA_DIR/preset.$$"
  preset_pairs "$_name" >"$_tmp" 2>/dev/null || {
    rm -f "$_tmp"
    printf '{"ok":0,"err":"unknown_preset"}\n'
    return 1
  }
  _out=$(apply_pairs <"$_tmp")
  rm -f "$_tmp"
  case "$_out" in
    OK) printf '{"ok":1,"preset":"%s"}\n' "$_name" ;;
    *) printf '{"ok":0,"err":"%s"}\n' "${_out#ERR }" ;;
  esac
  return 0
}

do_save() {
  _tmp="$DATA_DIR/save.$$"
  cat >"$_tmp" 2>/dev/null
  _out=$(apply_pairs <"$_tmp")
  rm -f "$_tmp" 2>/dev/null
  case "$_out" in
    OK) printf '{"ok":1}\n' ;;
    *) printf '{"ok":0,"err":"%s"}\n' "${_out#ERR }" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 诊断信息
# root 方案的版本：KernelSU 系列有 ksud，APatch 有 apd
root_info() {
  _r=""
  for _b in /data/adb/ksud /data/adb/ksu/bin/ksud; do
    if [ -x "$_b" ]; then
      _r="ksu=$("$_b" -V 2>/dev/null | head -n 1)"
      break
    fi
  done
  [ -x /data/adb/apd ] && _r="$_r apatch=$(/data/adb/apd -V 2>/dev/null | head -n 1)"
  _m=$(magisk -v 2>/dev/null)
  [ -n "$_m" ] && _r="$_r magisk=$_m"
  printf '%s' "${_r:-unknown}"
}

# 应用 cgroup 里一共有多少个进程、多少个处于冻结
cg_counts() {
  cg_detect_layout
  [ -n "$CR_CG_APPS" ] || { printf 'layout=not-found'; return 0; }
  _n=0
  _f=0
  for _d in "$CR_CG_APPS"/uid_*/pid_*; do
    [ -d "$_d" ] || continue
    _u=${_d%/pid_*}
    _u=${_u##*/uid_}
    case "$_u" in ''|*[!0-9]*) continue ;; esac
    _u=$((_u % 100000))
    [ "$_u" -ge 10000 ] && [ "$_u" -le 19999 ] || continue
    _n=$((_n + 1))
    cg_dir_frozen "$_d" && _f=$((_f + 1))
  done
  printf 'root=%s app_procs=%s frozen=%s' "$CR_CG_APPS" "$_n" "$_f"
}

do_diag() {
  printf '=== Cirno Reclaim Hybrid 诊断信息 ===\n'
  printf 'module    : %s (%s)\n' "$MODULE_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'device    : %s %s (%s)\n' "$(getprop ro.product.brand 2>/dev/null)" "$(getprop ro.product.model 2>/dev/null)" \
    "$(getprop ro.soc.model 2>/dev/null)"
  printf 'android   : %s (SDK %s)\n' "$(getprop ro.build.version.release 2>/dev/null)" "$(getprop ro.build.version.sdk 2>/dev/null)"
  printf 'rom       : %s / oplusrom=%s\n' "$(getprop ro.build.display.id 2>/dev/null)" \
    "$(getprop ro.build.version.oplusrom 2>/dev/null)"
  printf 'coloros   : %s\n' "$(is_coloros && echo yes || echo no)"
  printf 'kernel    : %s\n' "$(uname -r 2>/dev/null)"
  printf 'arch      : %s\n' "$(uname -m 2>/dev/null)"
  printf 'root      : %s\n' "$(root_info)"
  printf 'daemon    : %s\n' "$(proc_healthy "$PID_FILE" daemon.sh && echo running || echo stopped)"
  printf 'watchdog  : %s\n' "$(proc_healthy "$WD_PID_FILE" watchdog.sh && echo running || echo stopped)"
  if [ -x "$HELPER" ]; then
    printf 'pageout   : %s\n' "$("$HELPER" --probe 2>&1 | head -n 1)"
  else
    printf 'pageout   : helper missing\n'
  fi
  printf 'memory    : avail=%sMB total=%sMB swap=%s/%sMB psi=%s\n' \
    "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_free_mb)" "$(swap_total_mb)" "$(psi_some_avg10)"
  printf 'cirno     : %s\n' "$(pm list packages 2>/dev/null | grep -c 'nep.timeline.cirno')"
  printf 'cgroup    : %s\n' "$(cg_counts)"
  printf 'foreground: %s\n' "$(fg_pkg 2>/dev/null)"
  printf 'mode      : order=%s dry_run=%s vm_tune=%s\n' "${reclaim_order:-pageout_first}" "${dry_run:-0}" "${vm_tune:-0}"

  printf '\n--- swap / zram ---\n'
  cat /proc/swaps 2>/dev/null
  for _z in /sys/block/zram*; do
    [ -d "$_z" ] || continue
    printf '%s: disksize=%s alg=%s\n' "${_z##*/}" "$(cat "$_z/disksize" 2>/dev/null)" "$(cat "$_z/comp_algorithm" 2>/dev/null)"
    printf '  mm_stat=%s\n' "$(cat "$_z/mm_stat" 2>/dev/null)"
    # sysfs / memcg 的文件名都是简单字母数字
    # shellcheck disable=SC2010
    printf '  extra=%s\n' "$(ls "$_z" 2>/dev/null | grep -iE 'hybrid|writeback|backing|swapd' | tr '\n' ' ')"
  done
  printf 'vm        : swappiness=%s page-cluster=%s watermark_scale=%s min_free_kb=%s extra_free_kb=%s\n' \
    "$(cat /proc/sys/vm/swappiness 2>/dev/null)" "$(cat /proc/sys/vm/page-cluster 2>/dev/null)" \
    "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)" "$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)" \
    "$(cat /proc/sys/vm/extra_free_kbytes 2>/dev/null)"
  # sysfs / memcg 的文件名都是简单字母数字
  # shellcheck disable=SC2010
  printf 'memcg     : %s\n' "$(ls /dev/memcg 2>/dev/null | grep -iE 'swap|hybrid|reclaim|zram' | head -n 20 | tr '\n' ' ')"
  printf 'psi       : %s\n' "$(tr '\n' ' ' </proc/pressure/memory 2>/dev/null)"
  printf '\n--- props ---\n'
  getprop 2>/dev/null | grep -iE 'zram|swap|hybrid|nandswap|lmk|athena|hans|freezer' | head -n 40

  printf '\n--- config ---\n'
  grep -v '^[[:space:]]*#' "$CONF_FILE" 2>/dev/null | grep -v '^[[:space:]]*$'
  printf '\n--- stats ---\n'
  printf 'total_kills=%s total_paged_mb=%s total_freed_mb=%s total_app_freed=%s wd_restarts=%s\n' \
    "$(num "$(st_read total_kills)")" "$(num "$(st_read total_paged_mb)")" "$(num "$(st_read total_freed_mb)")" \
    "$(num "$(st_read total_app_freed)")" "$(num "$(st_read wd_restarts)")"
  printf '\n--- scan ---\n'
  sh "$CR_BIN/reclaim.sh" --scan 2>/dev/null | head -n 15
  printf '\n--- log (last 40) ---\n'
  tail -n 40 "$LOG_FILE" 2>/dev/null
  printf '\n=== 反馈：%s/issues ===\n' "$REPO_URL"
}

# ---------------------------------------------------------------- 命令分发
case "$CMD" in
  status)
    case "${1:-}" in
      --json) status_json ;;
      *) status_text ;;
    esac
    ;;
  scan)
    sh "$CR_BIN/reclaim.sh" --scan
    ;;
  run)
    sh "$CR_BIN/reclaim.sh" --run --manual "$@"
    ;;
  apprelief)
    sh "$CR_BIN/app_relief.sh" "$@"
    ;;
  log)
    tail -n "$(num "${1:-80}" 80)" "$LOG_FILE" 2>/dev/null
    ;;
  diag)
    do_diag
    ;;
  config)
    cat "$CONF_FILE" 2>/dev/null
    ;;
  save)
    do_save
    ;;
  set)
    _tmp="$DATA_DIR/set.$$"
    : >"$_tmp" 2>/dev/null
    for _kv in "$@"; do
      printf '%s\n' "$_kv" >>"$_tmp" 2>/dev/null
    done
    _out=$(apply_pairs <"$_tmp")
    rm -f "$_tmp" 2>/dev/null
    case "$_out" in
      OK) printf '{"ok":1}\n' ;;
      *) printf '{"ok":0,"err":"%s"}\n' "${_out#ERR }" ;;
    esac
    ;;
  preset)
    do_preset "${1:-balanced}"
    ;;
  restart)
    stop_all
    rm -f "$DATA_DIR/.stop" 2>/dev/null
    start_daemon
    start_watchdog
    _p=$(st_read supervisor.pid)
    case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
    if [ "$_p" -eq 0 ] || ! pid_alive "$_p" || ! proc_cmdline_has "$_p" "service.sh"; then
      if command -v setsid >/dev/null 2>&1; then
        setsid sh "$MODDIR/service.sh" --resume >/dev/null 2>&1 &
      else
        ( sh "$MODDIR/service.sh" --resume >/dev/null 2>&1 & )
      fi
    fi
    sleep 1
    printf '{"ok":1,"daemon":%s,"watchdog":%s}\n' \
      "$(bool proc_healthy "$PID_FILE" daemon.sh)" "$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)"
    ;;
  start)
    rm -f "$DATA_DIR/.stop" 2>/dev/null
    start_daemon
    start_watchdog
    printf '{"ok":1,"daemon":%s,"watchdog":%s}\n' \
      "$(bool proc_healthy "$PID_FILE" daemon.sh)" "$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)"
    ;;
  stop)
    : >"$DATA_DIR/.stop"
    stop_all
    printf '{"ok":1,"stopped":true}\n'
    ;;
  *)
    sed -n '2,22p' "$0"
    exit 2
    ;;
esac
