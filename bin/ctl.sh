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
#  ctl.sh diagfile             把诊断信息写成文件（WebView 剪贴板不可用时用）
#  ctl.sh doctor               自检：路径 / 权限 / 引擎 / helper / 日志
#  ctl.sh engine               当前守护引擎（cpp / shell）
#  ctl.sh config               当前运行时配置原文（缺失自动恢复）
#  ctl.sh configjson           配置的单行 JSON（WebUI 用，避免解析多行文本）
#  ctl.sh save                 从 stdin 读 k=v 并保存
#  ctl.sh set k=v [k=v ...]    保存若干项
#  ctl.sh preset <name>        应用预设 conservative|balanced|aggressive
#  ctl.sh profile [--json|list|detect|apply NAME]  系统适配档案（HyperOS/ColorOS/通用）
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

# 把 getprop 之类的自由文本压成 JSON 安全字符
json_safe() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9 ._()+-'
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
  printf '{"ok":1,"version":"%s","avail":%s,"total":%s,"swap_total":%s,"swap_free":%s,"psi":%s,"daemon":%s,"watchdog":%s,"hb_age":%s,"wd_age":%s,"enable":%s,"dry_run":%s,"screen_off_only":%s,"mem_low":%s,"mem_target":%s,"total_freed":%s,"total_kills":%s,"total_app_freed":%s,"total_paged":%s,"last_run":%s,"last_freed":%s,"last_kills":%s,"last_paged":%s,"last_reason":"%s","last_avail":%s,"last_app_pkg":"%s","last_app_freed":%s,"pageout":%s,"profile":"%s","zram":%s,"swapfile":%s,"engine":"%s","config_ok":%s,"device_profile":"%s","detected":"%s","rom":"%s","order":"%s","relief_gate":%s,"tight":%s,"wakeups":%s,"cpu_ms":%s}\n' \
    "$MODULE_VERSION" \
    "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_total_mb)" "$(swap_free_mb)" \
    "$(psi_some_avg10)" "$_d" "$_w" "$_hb" "$_wd" \
    "$(num "${enable:-1}")" "$(num "${dry_run:-0}")" "$(num "${screen_off_only:-0}")" \
    "$(mem_low_threshold_mb)" "$(mem_target_threshold_mb)" \
    "$(num "$(st_read total_freed_mb)")" "$(num "$(st_read total_kills)")" "$(num "$(st_read total_app_freed)")" \
    "$(num "$(st_read total_paged_mb)")" \
    "$(num "$(st_read last_run)")" "$(num "$(st_read last_freed_mb)")" "$(num "$(st_read last_kills)")" \
    "$(num "$(st_read last_paged_mb)")" \
    "$(st_read last_reason)" "$(num "$(st_read last_avail)")" \
    "$(st_read last_app_pkg)" "$(num "$(st_read last_app_freed)")" \
    "$_po" "${profile:-balanced}" "$(num "${zram_enable:-0}")" "$(num "${swapfile_enable:-0}")" \
    "$(if cpp_daemon_ready; then printf 'cpp'; elif [ -x "$CR_BIN/daemon.sh" ]; then printf 'shell'; else printf 'none'; fi)" \
    "$(if [ -r "$CONF_FILE" ]; then printf '1'; else printf '0'; fi)" \
    "$(json_safe "${device_profile:-generic}")" "$(rom_detect)" "$(json_safe "$(rom_name)")" \
    "$(json_safe "${reclaim_order:-pageout_first}")" "$(num "${relief_gate:-1}")" \
    "$(num "$(cpp_stat tight -1)" -1)" "$(num "$(cpp_stat wakeups -1)" -1)" \
    "$(num "$(cpp_stat cpu_ms -1)" -1)"
}

status_text() {
  printf 'version   : %s\n' "$MODULE_VERSION"
  printf 'daemon    : %s (heartbeat %ss ago)\n' "$(proc_healthy "$PID_FILE" "$(daemon_cmdline_pat)" && echo running || echo stopped)" "$(since_epoch_file heartbeat)"
  printf 'watchdog  : %s (heartbeat %ss ago)\n' "$(proc_healthy "$WD_PID_FILE" watchdog.sh && echo running || echo stopped)" "$(since_epoch_file wd.heartbeat)"
  printf 'rom       : %s (profile=%s)\n' "$(rom_name)" "${device_profile:-generic}"
  printf 'memory    : avail=%sMB total=%sMB swap=%s/%sMB psi=%s\n' \
    "$(mem_avail_mb)" "$(mem_total_mb)" "$(swap_free_mb)" "$(swap_total_mb)" "$(psi_some_avg10)"
  printf 'trigger   : low=%sMB target=%sMB\n' "$(mem_low_threshold_mb)" "$(mem_target_threshold_mb)"
  printf 'mode      : order=%s relief_gate=%s dry_run=%s\n' \
    "${reclaim_order:-pageout_first}" "${relief_gate:-1}" "${dry_run:-0}"
  printf 'totals    : reclaimed=%s procs, paged=%sMB, freed=%sMB, app_freed=%sMB\n' \
    "$(num "$(st_read total_kills)")" "$(num "$(st_read total_paged_mb)")" \
    "$(num "$(st_read total_freed_mb)")" "$(num "$(st_read total_app_freed)")"
  printf 'last run  : %sMB freed, %sMB paged, %s procs, reason=%s\n' \
    "$(num "$(st_read last_freed_mb)")" "$(num "$(st_read last_paged_mb)")" \
    "$(num "$(st_read last_kills)")" "$(st_read last_reason)"
}

# ---------------------------------------------------------------- 配置写入
# 真正的校验与写入在 common.sh：cfg_value_range_ok / cfg_write_pairs。
# 这里保留旧名字，避免其它脚本/文档里的调用失效。
validate_value() {
  cfg_value_range_ok "$1" "$2"
}

# stdin: k=v 行；输出 OK 或 ERR <原因>
apply_pairs() {
  cfg_write_pairs
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
deep_reclaim=0
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
  log "WEBUI save(stdin): $(head -c 240 "$_tmp" 2>/dev/null | tr '\n' ' ')"
  _out=$(apply_pairs <"$_tmp")
  rm -f "$_tmp" 2>/dev/null
  case "$_out" in
    OK) printf '{"ok":1}\n' ;;
    *) printf '{"ok":0,"err":"%s"}\n' "${_out#ERR }" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 诊断信息
# root 方案的版本号（KernelSU 系列 ksud / APatch apd / Magisk）
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

# 从 C++ 守护写的运行统计里取一个键（没有就返回默认值）
cpp_stat() {
  _f="$STATE_DIR/cpp.stats"
  [ -r "$_f" ] || { printf '%s' "${2:-}"; return 0; }
  _v=$(sed -n "s/^$1=//p" "$_f" 2>/dev/null | head -n 1)
  [ -n "$_v" ] || _v=${2:-}
  printf '%s' "$_v"
}

do_diag() {
  printf '=== Cirno Reclaim Hybrid 诊断信息 ===\n'
  printf 'module    : %s (%s)\n' "$MODULE_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'device    : %s %s (%s)\n' "$(getprop ro.product.brand 2>/dev/null)" \
    "$(getprop ro.product.model 2>/dev/null)" "$(getprop ro.soc.model 2>/dev/null)"
  printf 'android   : %s (SDK %s)\n' "$(getprop ro.build.version.release 2>/dev/null)" "$(getprop ro.build.version.sdk 2>/dev/null)"
  printf 'rom       : %s\n' "$(getprop ro.build.display.id 2>/dev/null)"
  printf 'hyperos   : %s\n' "$(getprop ro.mi.os.version.name 2>/dev/null)"
  printf 'miui      : %s\n' "$(getprop ro.miui.ui.version.name 2>/dev/null)"
  printf 'oplusrom  : %s\n' "$(getprop ro.build.version.oplusrom 2>/dev/null)"
  printf 'detected  : %s (%s) profile=%s\n' "$(rom_detect)" "$(rom_name)" "${device_profile:-unknown}"
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
  printf 'mode      : order=%s dry_run=%s vm_tune=%s relief_gate=%s\n' \
    "${reclaim_order:-pageout_first}" "${dry_run:-0}" "${vm_tune:-0}" "${relief_gate:-1}"

  # 配置可写性 / 语法自检：WebUI 保存失败时最先要看的就是这几行
  if [ -r "$CONF_FILE" ]; then
    _csz=$(wc -c <"$CONF_FILE" 2>/dev/null | tr -d ' ')
    if sh -n "$CONF_FILE" >/dev/null 2>&1; then _csyn=ok; else _csyn=FAIL; fi
    printf 'config    : %s (%s bytes, writable=%s, readable=%s, sh -n=%s)\n' \
      "$CONF_FILE" "${_csz:-?}" \
      "$([ -w "$CONF_FILE" ] && echo yes || echo no)" \
      "$([ -r "$CONF_FILE" ] && echo yes || echo no)" "$_csyn"
    printf 'data dir  : %s (writable=%s)\n' "$DATA_DIR" "$([ -w "$DATA_DIR" ] && echo yes || echo no)"
  else
    printf 'config    : MISSING %s\n' "$CONF_FILE"
  fi

  printf '\n--- cpp daemon ---\n'
  if [ -x "$CR_BIN/cirno_daemon" ]; then
    "$CR_BIN/cirno_daemon" --status 2>/dev/null || printf 'status failed\n'
  else
    printf 'binary missing (engine = shell)\n'
  fi

  printf '\n--- swap / zram ---\n'
  cat /proc/swaps 2>/dev/null
  for _z in /sys/block/zram*; do
    [ -d "$_z" ] || continue
    printf '%s: disksize=%s alg=%s\n' "${_z##*/}" "$(cat "$_z/disksize" 2>/dev/null)" "$(cat "$_z/comp_algorithm" 2>/dev/null)"
    printf '  mm_stat=%s\n' "$(cat "$_z/mm_stat" 2>/dev/null)"
    # 这里只是枚举 sysfs 名字，不是拿 ls 的输出做逻辑判断
    # shellcheck disable=SC2010
    printf '  extra=%s\n' "$(ls "$_z" 2>/dev/null | grep -iE 'hybrid|writeback|backing|swapd' | tr '\n' ' ')"
  done
  printf 'vm        : swappiness=%s page-cluster=%s watermark_scale=%s min_free_kb=%s extra_free_kb=%s\n' \
    "$(cat /proc/sys/vm/swappiness 2>/dev/null)" "$(cat /proc/sys/vm/page-cluster 2>/dev/null)" \
    "$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)" "$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)" \
    "$(cat /proc/sys/vm/extra_free_kbytes 2>/dev/null)"
  # shellcheck disable=SC2010
  printf 'memcg     : %s\n' "$(ls /dev/memcg 2>/dev/null | grep -iE 'swap|hybrid|reclaim|zram' | head -n 20 | tr '\n' ' ')"
  printf 'psi       : %s\n' "$(tr '\n' ' ' </proc/pressure/memory 2>/dev/null)"

  printf '\n--- props ---\n'
  getprop 2>/dev/null | grep -iE 'zram|swap|hybrid|nandswap|lmk|athena|hans|freezer' | head -n 40

  printf '\n--- config ---\n'
  grep -v '^[[:space:]]*#' "$CONF_FILE" 2>/dev/null | grep -v '^[[:space:]]*$'
  printf '\n--- config raw ---\n'
  printf 'lines=%s bytes=%s md5=%s\n' \
    "$(wc -l <"$CONF_FILE" 2>/dev/null | tr -d ' ')" \
    "$(wc -c <"$CONF_FILE" 2>/dev/null | tr -d ' ')" \
    "$(md5sum "$CONF_FILE" 2>/dev/null | awk '{print $1}')"
  printf '[head 4]\n'
  head -n 4 "$CONF_FILE" 2>/dev/null
  printf '[key lines: %s]\n' "$(grep -c '^[a-z_]' "$CONF_FILE" 2>/dev/null)"
  printf '[first key lines]\n'
  grep '^[a-z_]' "$CONF_FILE" 2>/dev/null | head -n 6
  printf '[last 3 lines]\n'
  tail -n 3 "$CONF_FILE" 2>/dev/null
  printf '\n--- configjson (WebUI 实际读到的值, 截断 1200 字节) ---\n'
  do_configjson 2>/dev/null | head -c 1200
  printf '\n'
  printf '\n--- config write attempts (last 12) ---\n'
  grep -F 'config write' "$LOG_FILE" 2>/dev/null | tail -n 12
  printf '\n--- webui saves (last 12) ---\n'
  grep -F 'WEBUI ' "$LOG_FILE" 2>/dev/null | tail -n 12
  printf '\n--- stats ---\n'
  printf 'total_kills=%s total_paged_mb=%s total_freed_mb=%s total_app_freed=%s wd_restarts=%s\n' \
    "$(num "$(st_read total_kills)")" "$(num "$(st_read total_paged_mb)")" \
    "$(num "$(st_read total_freed_mb)")" "$(num "$(st_read total_app_freed)")" \
    "$(num "$(st_read wd_restarts)")"
  printf '\n--- scan ---\n'
  sh "$CR_BIN/reclaim.sh" --scan 2>/dev/null | head -n 15
  printf '\n--- log (last 40) ---\n'
  tail -n 40 "$LOG_FILE" 2>/dev/null
  printf '\n=== 请把以上内容发到 asui20090213@outlook.com ===\n'
}

# 把诊断信息写成文件：WebView 的剪贴板经常不可用，这是最稳的「把信息带出来」的方式。
# 依次尝试 /sdcard/Download、Android 标准路径、/sdcard、/data/local/tmp，输出 JSON 路径。
do_diagfile() {
  _ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  [ -n "$_ts" ] || _ts=diag
  _name="cirno-diag-$_ts.txt"
  _path=""
  for _d in /sdcard/Download /storage/emulated/0/Download /sdcard /data/local/tmp; do
    [ -d "$_d" ] || continue
    [ -w "$_d" ] || continue
    if do_diag >"$_d/$_name" 2>/dev/null; then
      _path="$_d/$_name"
      break
    fi
  done
  if [ -n "$_path" ]; then
    log "diag file: $_path"
    printf '{"ok":1,"path":"%s"}\n' "$_path"
    return 0
  fi
  printf '{"ok":0,"err":"cannot_write"}\n'
  return 1
}

# 配置的 JSON 形态：单行、只包含模型键，给 WebUI 直接 JSON.parse。
# 为什么不用 `cat config.conf` 让前端自己解析：
#   - 配置文件里有注释、行内注释、单引号，前端解析容易出错；
#   - 某些管理器的 ksu.exec 对多行/大输出不友好（截断、串行化）。
# 这里给的是「cfg_load 之后真正生效的值」，和守护看到的一致。
do_configjson() {
  printf '{"ok":1'
  for _k in enable dry_run interval boot_delay log_max_kb profile device_profile \
            reclaim_order relief_gate heartbeat_sec \
            mem_low_mb mem_low_pct mem_target_mb mem_target_pct psi_enable psi_some_avg10 \
            high_pss_mb high_pss_interval max_kills_per_run max_kills_per_hour max_rounds \
            cooldown_sec min_process_mb min_frozen_min min_oom_score_adj only_frozen kill_mode \
            protect_foreground screen_off_only drop_caches drop_caches_cooldown deep_reclaim \
            deep_pageout_max_mb allow_system_uid \
            app_reclaim app_pss_mb app_reclaim_interval app_reclaim_cooldown app_trim_level \
            app_trim_all_pids app_pageout app_pageout_max_mb app_pageout_passes app_proc_reclaim \
            vm_tune zram_enable zram_disksize_mb zram_algorithm swapfile_enable swapfile_mb \
            swappiness vfs_cache_pressure dirty_writeback_centisecs dirty_expire_centisecs \
            page_cluster io_tune read_ahead_kb keepalive watchdog_interval heartbeat_timeout \
            oom_protect daemon_engine include_packages exclude_packages; do
    # 键名都是本文件里的字面量，值是变量展开（不会二次求值）
    eval "_v=\${$_k:-}"
    printf ',"%s":"%s"' "$_k" "$_v"
  done
  printf ',"_lines":%s,"_bytes":%s,"_loaded":1}\n' \
    "$(wc -l <"$CONF_FILE" 2>/dev/null | tr -d ' ')" \
    "$(wc -c <"$CONF_FILE" 2>/dev/null | tr -d ' ')"
}

# ---------------------------------------------------------------- 日志 / 配置 / 自检
do_info() {
  _lsz=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$_lsz" in ''|*[!0-9]*) _lsz=0 ;; esac
  printf '{"model":"%s","rom":"%s","android":"%s","kernel":"%s","engine":"%s","pageout":%s,"log_size":%s,"log_path":"%s","config_ok":%s,"device_profile":"%s","detected":"%s","tight":%s,"wakeups":%s,"cpu_ms":%s,"heartbeat_sec":%s}\n' \
    "$(json_safe "$(getprop ro.product.model 2>/dev/null)")" \
    "$(json_safe "$(rom_name)")" \
    "$(getprop ro.build.version.release 2>/dev/null)" \
    "$(uname -r 2>/dev/null)" \
    "$(if cpp_daemon_ready; then printf 'cpp'; else printf 'shell'; fi)" \
    "$(bool helper_ready)" \
    "$_lsz" \
    "$LOG_FILE" \
    "$([ -r "$CONF_FILE" ] && printf '1' || printf '0')" \
    "$(json_safe "${device_profile:-generic}")" "$(rom_detect)" \
    "$(num "$(cpp_stat tight -1)" -1)" "$(num "$(cpp_stat wakeups -1)" -1)" \
    "$(num "$(cpp_stat cpu_ms -1)" -1)" "$(num "${heartbeat_sec:-45}" 45)"
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
        printf 'theme=auto\nbg=solid\nbgurl=\nalpha=92\naccent=green\nradius=28\ndim=78\nnav=pill\nperf=0\nliquid=1\n'
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
          liquid) case "$_v" in 0|1) ;; *) continue ;; esac ;;
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
  printf '  cgroup   : %s\n' "$(cg_counts)"
  printf '  rom      : %s\n' "$(rom_name)"
  printf '\n[profile]\n'
  printf '  device_profile: %s\n' "${device_profile:-unknown}"
  printf '  detected      : %s\n' "$(rom_detect)"
  printf '  applied       : %s\n' "$(st_read profile.applied)"
  printf '  reclaim_order : %s\n' "${reclaim_order:-pageout_first}"
  printf '  relief_gate   : %s\n' "${relief_gate:-1}"
  printf '  oem zram      : %s\n' "$(oem_zram_managed && echo managed-by-rom || echo not-managed)"
  printf '\n[power]\n'
  printf '  interval=%ss heartbeat=%ss boot_delay=%ss\n' "${interval:-?}" "${heartbeat_sec:-?}" "${boot_delay:-?}"
  printf '  cpp stats: wakeups=%s probes=%s cpu_ms=%s uptime=%s\n' \
    "$(cpp_stat wakeups -)" "$(cpp_stat probes -)" "$(cpp_stat cpu_ms -)" "$(cpp_stat uptime -)"
  printf '\n[config]\n'
  if [ -r "$CONF_FILE" ]; then
    printf '  size: %s bytes\n' "$(wc -c <"$CONF_FILE" | tr -d ' ')"
    printf '  enable=%s dry_run=%s engine=%s interval=%s\n' "${enable:-?}" "${dry_run:-?}" "${daemon_engine:-?}" "${interval:-?}"
  else
    printf '  MISSING: %s\n' "$CONF_FILE"
  fi
  printf '\n[log tail 8]\n'
  tail -n 8 "$LOG_FILE" 2>/dev/null || printf '  (no log yet)\n'
  return 0
}

# ---------------------------------------------------------------- 系统适配档案
do_profile() {
  _sub=${1:-show}
  _arg=${2:-}
  # `ctl.sh profile --json` 这种写法：把 --json 当成 show 的修饰
  case "$_sub" in
    --json) _arg=--json; _sub=show ;;
  esac
  case "$_sub" in
    show|'')
      case "$_arg" in
        --json)
          _ap=0
          [ "$(st_read profile.applied)" = "${device_profile:-generic}" ] && _ap=1
          printf '{"ok":1,"device_profile":"%s","detected":"%s","rom":"%s","applied":%s}\n' \
            "$(json_safe "${device_profile:-generic}")" "$(rom_detect)" \
            "$(json_safe "$(rom_name)")" "$_ap"
          ;;
        *)
          profile_show
          ;;
      esac
      ;;
    detect)
      rom_detect
      ;;
    list)
      printf '{"ok":1,"list":["hyperos","coloros","generic"],"detected":"%s","current":"%s"}\n' \
        "$(rom_detect)" "$(json_safe "${device_profile:-generic}")"
      ;;
    apply)
      if ! profile_valid "$_arg"; then
        printf '{"ok":0,"err":"invalid_profile"}\n'
        return 2
      fi
      if profile_apply "$_arg"; then
        st_write profile.applied "$_arg"
        printf '{"ok":1,"profile":"%s"}\n' "$_arg"
      else
        printf '{"ok":0,"err":"apply_failed"}\n'
        return 1
      fi
      ;;
    *)
      printf '{"ok":0,"err":"usage: profile [--json|list|detect|apply NAME]"}\n'
      return 2
      ;;
  esac
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
    # WebUI 的「舒缓前台」是用户明确点的按钮，走 --force 绕过压力门控，
    # 但进程内仍然保留 PSS 上限、冷却和 dry_run 保护。
    sh "$CR_BIN/app_relief.sh" --force "$@"
    ;;
  profile)
    do_profile "${1:-show}" "${2:-}"
    ;;
  log)
    do_log "${1:-120}"
    ;;
  diag)
    do_diag
    ;;
  diagfile)
    do_diagfile
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
  configjson)
    do_configjson
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
    log "WEBUI set: $*"
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
