#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/ctl.sh
#  命令行 / WebUI 的统一入口。
#
#  ctl.sh status [--json]      状态（JSON 或人读）
#  ctl.sh scan                 候选进程
#  ctl.sh run [--manual|--json] 立即回收
#  ctl.sh apprelief [--json]   舒缓前台
#  ctl.sh log [N]              最近 N 行日志（带文件路径与大小）
#  ctl.sh diag                 反馈用的诊断信息
#  ctl.sh doctor               自检：路径 / 权限 / 引擎 / helper / 日志
#  ctl.sh engine               当前守护引擎（cpp / shell）
#  ctl.sh config               当前运行时配置原文（缺失自动恢复）
#  ctl.sh save                 从 stdin 读 k=v 并保存
#  ctl.sh set k=v [k=v ...]    保存若干项
#  ctl.sh preset <name>        应用预设 conservative|balanced|aggressive
#  ctl.sh restart|start|stop
# ============================================================================

# 解析预检：common.sh 有语法错误时直接报出来，
# 避免出现「cfg_load: command not found」这种让人摸不着头脑的连锁报错。
_cr_common="$(dirname "$0")/common.sh"
if ! sh -n "$_cr_common" >/dev/null 2>&1; then
  echo "[ctl] common.sh 语法错误："
  sh -n "$_cr_common" 2>&1 | head -n 6
  exit 3
fi

. "$_cr_common"

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
  _d=$(bool proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)")
  _w=$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)
  _hb=$(since_epoch_file heartbeat)
  _wd=$(since_epoch_file wd.heartbeat)
  _po=$(bool helper_ready)
  cg_detect_layout
  _cg=0
  [ -n "$CR_CG_APPS" ] && _cg=1
  printf '{"ok":1,"version":"%s","avail":%s,"total":%s,"swap_total":%s,"swap_free":%s,"psi":%s,"daemon":%s,"watchdog":%s,"hb_age":%s,"wd_age":%s,"enable":%s,"dry_run":%s,"screen_off_only":%s,"mem_low":%s,"mem_target":%s,"total_freed":%s,"total_kills":%s,"total_app_freed":%s,"last_run":%s,"last_freed":%s,"last_kills":%s,"last_reason":"%s","last_avail":%s,"last_app_pkg":"%s","last_app_freed":%s,"pageout":%s,"profile":"%s","zram":%s,"swapfile":%s,"total_paged":%s,"last_paged":%s,"order":"%s","coloros":%s,"cgroup":%s,"engine":"%s","config_ok":%s}\n' \
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
    "$(bool is_coloros)" "$_cg" \
    "$(if cpp_daemon_ready; then printf 'cpp'; elif [ -x "$CR_BIN/daemon.sh" ]; then printf 'shell'; else printf 'none'; fi)" \
    "$(if [ -r "$CONF_FILE" ]; then printf '1'; else printf '0'; fi)"
}

status_text() {
  printf 'version   : %s\n' "$MODULE_VERSION"
  printf 'daemon    : %s (heartbeat %ss ago)\n' "$(proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)" && echo running || echo stopped)" "$(since_epoch_file heartbeat)"
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
  printf 'daemon    : %s\n' "$(proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)" && echo running || echo stopped)"
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

# ---------------------------------------------------------------- 日志 / 配置 / 自检
do_info() {
  _lsz=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$_lsz" in ''|*[!0-9]*) _lsz=0 ;; esac
  printf '{"model":"%s","android":"%s","kernel":"%s","engine":"%s","pageout":%s,"log_size":%s,"log_path":"%s","config_ok":%s}\n' \
    "$(getprop ro.product.model 2>/dev/null)" \
    "$(getprop ro.build.version.release 2>/dev/null)" \
    "$(uname -r 2>/dev/null)" \
    "$(if cpp_daemon_ready; then printf 'cpp'; else printf 'shell'; fi)" \
    "$(bool helper_ready)" \
    "$_lsz" \
    "$LOG_FILE" \
    "$([ -r "$CONF_FILE" ] && printf '1' || printf '0')"
  return 0
}

# 一次调用返回状态 + 设备信息，给 WebUI 省掉一半的同步 exec
do_snapshot() {
  _s=$(status_json 2>/dev/null | tr -d '\n')
  _i=$(do_info 2>/dev/null | tr -d '\n')
  printf '{"status":%s,"info":%s}\n' "$_s" "$_i"
  return 0
}

# 外观配置：theme / bg / bgurl / alpha / accent / radius / dim / nav / perf
do_ui() {
  _sub=${1:-get}
  _dir="$DATA_DIR/webui"
  _f="$_dir/theme.conf"
  mkdir -p "$_dir" 2>/dev/null
  chmod 700 "$_dir" 2>/dev/null
  case "$_sub" in
    get)
      if [ -r "$_f" ]; then
        cat "$_f" 2>/dev/null
      else
        printf 'theme=auto\nbg=solid\nbgurl=\nalpha=92\naccent=green\nradius=28\ndim=78\nnav=pill\nperf=0\n'
      fi
      ;;
    set)
      _tmp="$_f.$$"
      : >"$_tmp" 2>/dev/null
      while IFS= read -r _l; do
        case "$_l" in ''|'#'*) continue ;; esac
        case "$_l" in *=*) ;; *) continue ;; esac
        _k=${_l%%=*}
        _v=${_l#*=}
        case "$_k" in
          theme) case "$_v" in auto|light|dark) ;; *) continue ;; esac ;;
          bg) case "$_v" in solid|image) ;; *) continue ;; esac ;;
          bgurl) printf '%s' "$_v" | grep -q '[^ -~]' && continue ;;
          alpha) case "$_v" in ''|*[!0-9]*) continue ;; esac
                 [ "$_v" -ge 30 ] && [ "$_v" -le 100 ] || continue ;;
          accent) case "$_v" in green|blue|violet|pink) ;; *) continue ;; esac ;;
          radius) case "$_v" in ''|*[!0-9]*) continue ;; esac
                  [ "$_v" -ge 8 ] && [ "$_v" -le 36 ] || continue ;;
          dim) case "$_v" in ''|*[!0-9]*) continue ;; esac
               [ "$_v" -ge 0 ] && [ "$_v" -le 90 ] || continue ;;
          nav) case "$_v" in pill|bar) ;; *) continue ;; esac ;;
          perf) case "$_v" in 0|1) ;; *) continue ;; esac ;;
          *) continue ;;
        esac
        printf '%s=%s\n' "$_k" "$_v" >>"$_tmp" 2>/dev/null
      done
      mv -f "$_tmp" "$_f" 2>/dev/null
      chmod 600 "$_f" 2>/dev/null
      printf '{"ok":1}\n'
      ;;
    *)
      printf '{"ok":0,"err":"usage: ui get|set"}\n'
      return 2
      ;;
  esac
  return 0
}

do_log() {
  _n=$(num "${1:-120}" 120)
  case "$_n" in
    0) _n=120 ;;
  esac
  if [ ! -f "$LOG_FILE" ]; then
    printf '# 日志文件尚未生成: %s\n' "$LOG_FILE"
    printf '# post-fs-data: %s 秒前\n' "$(since_epoch_file boot.postfs)"
    printf '# service.sh  : %s 秒前\n' "$(since_epoch_file boot.service)"
    printf '# 若上面是 999999，说明模块脚本没有执行：检查模块是否启用、是否安装完整。\n'
    printf '# 可以先执行: sh %s doctor\n' "$CR_BIN/ctl.sh"
    return 0
  fi
  printf '# file  : %s\n' "$LOG_FILE"
  printf '# size  : %s bytes, %s lines\n' \
    "$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')" \
    "$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ')"
  printf '# tail  : %s\n' "$_n"
  printf '# --------------------------------------------\n'
  tail -n "$_n" "$LOG_FILE" 2>/dev/null
  if [ -f "$LOG_FILE.1" ]; then
    printf '# rotated: %s.1 (%s bytes)\n' "$LOG_FILE" "$(wc -c <"$LOG_FILE.1" 2>/dev/null | tr -d ' ')"
  fi
  return 0
}

do_config() {
  if ! ensure_config; then
    printf '# 配置文件不存在，且无法从模块默认值恢复\n'
    printf '# 预期路径: %s\n' "$CONF_FILE"
    printf '# 模块默认: %s\n' "$MODDIR/config.conf"
    return 3
  fi
  printf '# path: %s\n' "$CONF_FILE"
  printf '# size: %s bytes\n' "$(wc -c <"$CONF_FILE" 2>/dev/null | tr -d ' ')"
  cat "$CONF_FILE" 2>/dev/null
  return 0
}

do_doctor() {
  printf '=== Cirno Reclaim 自检 ===\n'
  printf 'time      : %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  printf 'version   : %s\n' "$MODULE_VERSION"
  printf 'module    : %s\n' "$MODDIR"
  printf 'data      : %s\n' "$DATA_DIR"
  printf 'PATH      : %s\n' "$PATH"
  printf '\n[files]\n'
  for _f in "$MODDIR/module.prop" "$MODDIR/config.conf" "$CONF_FILE" "$LOG_FILE" \
            "$CR_BIN/reclaim.sh" "$CR_BIN/app_relief.sh" "$CR_BIN/cirno_daemon" "$CR_BIN/cirno_pageout"; do
    if [ -e "$_f" ]; then
      printf '  ok   %-58s %s bytes\n' "$_f" "$(wc -c <"$_f" 2>/dev/null | tr -d ' ')"
    else
      printf '  miss %-58s\n' "$_f"
    fi
  done
  printf '\n[writable]\n'
  printf '  sh        : %s\n' "$(command -v sh 2>/dev/null || echo missing)"
  printf '  data dir  : %s\n' "$([ -w "$DATA_DIR" ] && echo writable || echo NOT-writable)"
  printf '  log dir   : %s\n' "$([ -w "$LOG_DIR" ] && echo writable || echo NOT-writable)"
  printf '  state dir : %s\n' "$([ -w "$STATE_DIR" ] && echo writable || echo NOT-writable)"
  printf '\n[daemon]\n'
  printf '  engine   : %s\n' "$(if cpp_daemon_ready; then echo cpp; else echo shell; fi)"
  printf '  pid      : %s\n' "$(cat "$PID_FILE" 2>/dev/null)"
  printf '  running  : %s\n' "$(proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)" && echo yes || echo no)"
  printf '  heartbeat: %ss ago\n' "$(since_epoch_file heartbeat)"
  printf '  watchdog : %s (%ss ago)\n' "$(proc_healthy "$WD_PID_FILE" watchdog.sh && echo yes || echo no)" "$(since_epoch_file wd.heartbeat)"
  printf '  supervisor: %s\n' "$(proc_cmdline_has "$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null)" service.sh 2>/dev/null && echo yes || echo unknown)"
  printf '\n[engine checks]\n'
  printf '  pageout  : %s\n' "$(helper_ready && echo available || echo unavailable)"
  if [ -x "$CR_BIN/cirno_pageout" ]; then
    printf '  pageout probe: %s\n' "$("$CR_BIN/cirno_pageout" --probe 2>&1 | head -n 1)"
  else
    printf '  pageout probe: helper missing\n'
  fi
  if [ -x "$CR_BIN/cirno_daemon" ]; then
    printf '  cpp daemon --check: %s\n' "$("$CR_BIN/cirno_daemon" --check 2>&1 | tr '\n' ' ')"
  else
    printf '  cpp daemon --check: binary missing (fallback = shell)\n'
  fi
  printf '\n[boot / install]\n'
  printf '  post-fs-data: %ss ago\n' "$(since_epoch_file boot.postfs)"
  printf '  service.sh  : %ss ago\n' "$(since_epoch_file boot.service)"
  printf '  disable     : %s\n' "$([ -f "$MODDIR/disable" ] && echo present || echo no)"
  printf '  remove      : %s\n' "$([ -f "$MODDIR/remove" ] && echo present || echo no)"
  printf '  webroot     : %s\n' "$(ls -l "$MODDIR/webroot" 2>/dev/null | awk 'NR>1{printf "%s(%s) ", $9, $5}')"
  printf '  bin         : %s\n' "$(ls -l "$CR_BIN" 2>/dev/null | awk 'NR>1{printf "%s(%s) ", $9, $5}')"
  printf '\n[system]\n'
  printf '  device   : %s %s\n' "$(getprop ro.product.brand 2>/dev/null)" "$(getprop ro.product.model 2>/dev/null)"
  printf '  android  : %s (SDK %s)\n' "$(getprop ro.build.version.release 2>/dev/null)" "$(getprop ro.build.version.sdk 2>/dev/null)"
  printf '  kernel   : %s\n' "$(uname -r 2>/dev/null)"
  printf '  selinux  : %s\n' "$(getenforce 2>/dev/null)"
  printf '  memory   : avail=%sMB total=%sMB swap=%s/%sMB\n' "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_free_mb)" "$(swap_total_mb)"
  printf '  cgroup   : %s\n' "$([ -d /sys/fs/cgroup/apps ] && echo per-pid-freezer || echo no-apps-cgroup)"
  printf '\n[config]\n'
  if [ -r "$CONF_FILE" ]; then
    printf '  size: %s bytes, invalid lines: %s\n' "$(wc -c <"$CONF_FILE" | tr -d ' ')" "0"
    printf '  enable=%s dry_run=%s engine=%s interval=%s\n' "${enable:-?}" "${dry_run:-?}" "${daemon_engine:-?}" "${interval:-?}"
  else
    printf '  MISSING: %s\n' "$CONF_FILE"
  fi
  printf '\n[log tail 8]\n'
  tail -n 8 "$LOG_FILE" 2>/dev/null || printf '  (no log yet)\n'
  return 0
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
    do_log "${1:-120}"
    ;;
  diag)
    do_diag
    ;;
  doctor | selftest)
    do_doctor
    ;;
  engine)
    if cpp_daemon_ready; then
      printf '{"engine":"cpp","cpp":1,"shell":1}\n'
    else
      printf '{"engine":"shell","cpp":0,"shell":1}\n'
    fi
    ;;
  info)
    do_info
    ;;
  snapshot)
    do_snapshot
    ;;
  ui)
    do_ui "${1:-get}"
    ;;
  config)
    do_config
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
      "$(bool proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)")" "$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)"
    ;;
  start)
    rm -f "$DATA_DIR/.stop" 2>/dev/null
    start_daemon
    start_watchdog
    printf '{"ok":1,"daemon":%s,"watchdog":%s}\n' \
      "$(bool proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)")" "$(bool proc_healthy "$WD_PID_FILE" watchdog.sh)"
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
