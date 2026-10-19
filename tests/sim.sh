#!/bin/sh
# ============================================================================
#  tests/sim.sh - 在普通 Linux 上模拟 Android 跑引擎（开发用，不打进模块包）
#
#  模拟两种真机执行环境：
#    mksh     /system/bin/sh + toybox + BWK awk（WebUI / 终端调 ctl.sh 时）
#    busybox  KernelSU 跑 service.sh 时的 busybox ash + applet
#  配合假的 cgroup 目录和 dumpsys / am / getprop 等桩，起一批「真实」进程
#  （真实 UID、真实内存、真实 oom_score_adj），让扫描、换出、结束进程都真刀真枪地跑。
#
#  需要：root、python3、setpriv、bash、cc、mksh、busybox、toybox、original-awk；
#  页换出用例会临时建一个 swapfile 并 swapon，结束时 swapoff。
#
#  用法：sh tests/sim.sh [mksh|busybox]
# ============================================================================

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
KIND=${1:-mksh}
T=$(mktemp -d /tmp/cr-sim.XXXXXX)
chmod 755 "$T"
PASS=0
FAIL=0
SWAP_ON=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
# SIM_ONLY="2 3" 只跑这几个场景；SIM_KEEP=1 保留临时目录便于排查
want() {
  [ -z "${SIM_ONLY:-}" ] && return 0
  case " $SIM_ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

check() {
  _d=$1
  shift
  if "$@"; then ok "$_d"; else bad "$_d"; fi
}

# 结束之前场景起的测试进程（每个场景 ~2.4GB，不收掉的话几轮下来测试机自己就 OOM 了）
kill_apps() {
  # pid 文件没有换行，逐个读（一起 cat 会把数字粘在一起）
  for _f in "$T"/pids/*.pid; do
    [ -f "$_f" ] || continue
    _p=$(cat "$_f")
    kill -9 "$_p" 2>/dev/null
    rm -f "$_f"
  done
  sleep 1
}

cleanup() {
  kill_apps
  # 守护进程（按命令行里的模块路径找，只杀本次测试起的）
  for _d in /proc/[0-9]*; do
    tr '\0' ' ' 2>/dev/null <"$_d/cmdline" | grep -qF "$T/mod/" && kill -9 "${_d#/proc/}" 2>/dev/null
  done
  if [ "$SWAP_ON" = "1" ]; then
    if [ -n "$ZRAM_ID" ]; then
      swapoff "/dev/zram$ZRAM_ID" 2>/dev/null
      echo "$ZRAM_ID" >/sys/class/zram-control/hot_remove 2>/dev/null
    else
      swapoff "$T/swapfile" 2>/dev/null
    fi
  fi
  if [ "${SIM_KEEP:-0}" = "1" ]; then
    printf 'kept: %s\n' "$T"
    return 0
  fi
  case "$T" in
    /tmp/cr-sim.*) rm -rf -- "$T" ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 模块副本
MOD=$T/mod
mkdir -p "$MOD" "$T/pids" "$T/tools" "$T/stub"
chmod 1777 "$T/pids"
cp -R "$REPO/bin" "$REPO/module.prop" "$REPO/config.conf" "$REPO/service.sh" \
  "$REPO/post-fs-data.sh" "$REPO/action.sh" "$MOD/"
# 本机架构的 helper（仓库里的是 arm64）
cc -O2 -static -o "$MOD/bin/cirno_pageout" "$REPO/src/cirno_pageout.c" || exit 1

# ---------------------------------------------------------------- 用户态工具
TOOLS=$T/tools
if [ "$KIND" = "busybox" ]; then
  # KernelSU 跑模块脚本时：busybox ash，所有 applet 优先
  BB=$(command -v busybox)
  for _c in $(busybox --list); do
    ln -s "$BB" "$TOOLS/$_c"
  done
else
  # /system/bin：mksh + toybox 全部 applet + BWK awk
  TB=$(command -v toybox)
  for _c in $(toybox); do
    ln -s "$TB" "$TOOLS/$_c"
  done
  # Ubuntu 的 toybox 没编 tr / dd，Android 上有；用 busybox 补
  for _c in tr dd; do
    [ -e "$TOOLS/$_c" ] || ln -s "$(command -v busybox)" "$TOOLS/$_c"
  done
  rm -f "$TOOLS/awk" "$TOOLS/sh"
  ln -s "$(command -v original-awk)" "$TOOLS/awk"
  ln -s "$(command -v mksh)" "$TOOLS/sh"
fi

# ---------------------------------------------------------------- 系统命令桩
STUB=$T/stub
mkstub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$STUB/$1"
  chmod 755 "$STUB/$1"
}
mkstub getprop '
F="$SIM_ROOT/props"
if [ $# -eq 0 ]; then
  while IFS="=" read -r k v; do printf "[%s]: [%s]\n" "$k" "$v"; done <"$F"
  exit 0
fi
while IFS="=" read -r k v; do
  [ "$k" = "$1" ] && { printf "%s\n" "$v"; exit 0; }
done <"$F"
printf "\n"'
mkstub dumpsys '
echo "dumpsys $*" >>"$SIM_ROOT/calls.log"
fg=$(cat "$SIM_ROOT/fg" 2>/dev/null)
case "$1" in
  activity)
    printf "Display #0 (activities from top to bottom):\n"
    printf "  ResumedActivity: ActivityRecord{1a2b3c u0 %s/.MainActivity t42}\n" "$fg"
    printf "  topResumedActivity=ActivityRecord{1a2b3c u0 %s/.MainActivity t42}\n" "$fg" ;;
  window) printf "  mCurrentFocus=Window{9f8e u0 %s/%s.MainActivity}\n" "$fg" "$fg" ;;
  power) printf "  mWakefulness=Awake\n" ;;
esac'
mkstub am '
echo "am $*" >>"$SIM_ROOT/calls.log"
if [ "$1" = "kill" ]; then
  for d in /proc/[0-9]*; do
    c=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null | head -n 1)
    case "$c" in "$2"|"$2":*) kill -9 "${d#/proc/}" ;; esac
  done
fi'
mkstub cmd '
echo "cmd $*" >>"$SIM_ROOT/calls.log"
printf "priority=0 preferredOrder=0 match=0x108000\ncom.android.launcher/com.android.launcher.Launcher\n"'
mkstub settings 'printf "com.baidu.input_oppo/com.baidu.input_oppo.ImeService\n"'
mkstub pm 'printf "package:nep.timeline.cirno\npackage:com.android.launcher\n"'
for _c in mkswap swapon swapoff; do
  mkstub "$_c" "echo \"$_c \$*\" >>\"\$SIM_ROOT/calls.log\""
done

# ---------------------------------------------------------------- swap
# 用 zram，和手机一样：zram 是同步设备，MADV_PAGEOUT 写完立刻释放内存。
# 磁盘 swapfile 是异步回写，页会在 swap cache 里多待一阵，MemAvailable 不会马上涨。
ZRAM_ID=""
if [ -r /sys/class/zram-control/hot_add ]; then
  ZRAM_ID=$(cat /sys/class/zram-control/hot_add 2>/dev/null)
fi
if [ -n "$ZRAM_ID" ] && [ -d "/sys/block/zram$ZRAM_ID" ]; then
  grep -qw lz4 "/sys/block/zram$ZRAM_ID/comp_algorithm" && echo lz4 >"/sys/block/zram$ZRAM_ID/comp_algorithm"
  echo 2G >"/sys/block/zram$ZRAM_ID/disksize"
  /sbin/mkswap "/dev/zram$ZRAM_ID" >/dev/null 2>&1
  swapon -p 100 "/dev/zram$ZRAM_ID" 2>/dev/null && SWAP_ON=1
else
  ZRAM_ID=""
  dd if=/dev/zero of="$T/swapfile" bs=1M count=1536 status=none
  chmod 600 "$T/swapfile"
  /sbin/mkswap "$T/swapfile" >/dev/null 2>&1
  swapon "$T/swapfile" 2>/dev/null && SWAP_ON=1
fi

# ---------------------------------------------------------------- 测试进程
cat >"$T/app.py" <<'EOF'
import os, sys, time
mb = int(sys.argv[1])
pf = sys.argv[2]
buf = bytearray(b"\x01") * (mb * 1024 * 1024)
with open(pf + ".tmp", "w") as f:
    f.write(str(os.getpid()))
os.rename(pf + ".tmp", pf)
while True:
    time.sleep(3600)
EOF
chmod 644 "$T/app.py"

# $1 = 场景目录, $2 = 标签, $3 = uid, $4 = 进程名, $5 = MB, $6 = oom_score_adj,
# $7 = 冻结方式 pid|uid|none, $8 = 布局 apps|root
spawn_app() {
  _s=$1; _tag=$2; _uid=$3; _name=$4; _mb=$5; _oom=$6; _frz=$7; _lay=$8
  _pf="$T/pids/$(basename "$_s").$_tag.pid"
  setpriv --reuid="$_uid" --regid="$_uid" --clear-groups -- \
    bash -c 'exec -a "$0" python3 "$@"' "$_name" "$T/app.py" "$_mb" "$_pf" </dev/null >/dev/null 2>&1 &
  _i=0
  while [ ! -s "$_pf" ] && [ "$_i" -lt 100 ]; do sleep 0.1; _i=$((_i + 1)); done
  _pid=$(cat "$_pf")
  printf '%s' "$_oom" >"/proc/$_pid/oom_score_adj"
  if [ "$_lay" = "apps" ]; then _base="$_s/cg/apps"; else _base="$_s/cg"; fi
  _d="$_base/uid_$_uid/pid_$_pid"
  mkdir -p "$_d"
  case "$_frz" in
    pid) echo 1 >"$_d/cgroup.freeze"; printf 'populated 1\nfrozen 1\n' >"$_d/cgroup.events" ;;
    uid) echo 0 >"$_d/cgroup.freeze"; printf 'populated 1\nfrozen 1\n' >"$_d/cgroup.events"
         echo 1 >"$_base/uid_$_uid/cgroup.freeze" ;;
    none) echo 0 >"$_d/cgroup.freeze"; printf 'populated 1\nfrozen 0\n' >"$_d/cgroup.events" ;;
  esac
  eval "PID_$_tag=$_pid"
}

# 新场景：独立的 cgroup / 数据 / 日志目录
# $1 = 名字, $2 = 布局, 其余 = 追加到配置里的 key=value
new_scene() {
  kill_apps
  S="$T/$1"
  _lay=$2
  shift 2
  mkdir -p "$S/cg" "$S/data/state" "$S/log"
  if [ "$_lay" = "apps" ]; then
    mkdir -p "$S/cg/apps" "$S/cg/system/uid_1000/pid_1"
  else
    mkdir -p "$S/cg/uid_1000/pid_1"
  fi
  : >"$S/calls.log"
  printf 'com.fg.app' >"$S/fg"
  cat >"$S/props" <<'EOF'
ro.build.version.oplusrom=V17.0.0
ro.product.brand=OPPO
ro.product.model=PME110
ro.soc.model=SM8850
ro.build.version.release=17
ro.build.version.sdk=37
ro.build.display.id=PME110_17.0.0.102(CN01)
persist.sys.oplus.nandswap=true
EOF
  cp "$REPO/config.conf" "$S/data/config.conf"
  printf '\n# test overrides\nmin_frozen_min=0\nmem_low_pct=0\nmem_target_pct=0\n' >>"$S/data/config.conf"
  for _kv in "$@"; do printf '%s\n' "$_kv" >>"$S/data/config.conf"; done
}

# 在当前场景里用目标 shell 跑模块脚本
run_mod() {
  _script=$1
  shift
  env -i PATH="$STUB:$TOOLS" HOME=/ SIM_ROOT="$S" DATA_DIR="$S/data" LOG_DIR="$S/log" \
    CR_CGROOT="$S/cg" "$TOOLS/sh" "$MOD/$_script" "$@"
}

alive() { [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
dead() { ! alive "$1"; }
logged() { grep -qE "$1" "$S/log/reclaim.log"; }
not_logged() { ! logged "$1"; }
avail_mb() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }
vmswap_mb() { awk '/^VmSwap:/ {print int($2 / 1024)}' "/proc/$1/status" 2>/dev/null; }

# 标准的一组应用：期望候选按 PSS 依次是 A(400) B(250) K(150) B2(60)
spawn_standard() {
  _lay=$1
  spawn_app "$S" A 10101 com.big.game 400 905 pid "$_lay"
  spawn_app "$S" B 10102 com.mid.video 250 910 pid "$_lay"
  spawn_app "$S" B2 10102 com.mid.video:push 60 915 pid "$_lay"
  spawn_app "$S" C 10103 com.small.tool 20 950 pid "$_lay"
  spawn_app "$S" D 10104 com.oplus.camera 200 905 pid "$_lay"
  spawn_app "$S" E 10105 com.tencent.mm 200 905 pid "$_lay"
  spawn_app "$S" F 10106 com.fg.app 200 905 pid "$_lay"
  spawn_app "$S" G 10107 com.notfrozen.app 200 905 none "$_lay"
  spawn_app "$S" H 10108 com.lowadj.app 200 200 pid "$_lay"
  spawn_app "$S" I 1001 com.sys.thing 200 905 pid "$_lay"
  spawn_app "$S" J 10109 nep.timeline.cirno 100 905 pid "$_lay"
  spawn_app "$S" K 10110 com.ancestor.frozen 150 905 uid "$_lay"
}

protected_alive() {
  alive "$PID_C" && alive "$PID_D" && alive "$PID_E" && alive "$PID_F" && alive "$PID_G" &&
    alive "$PID_H" && alive "$PID_I" && alive "$PID_J"
}

printf '== shell: %s  swap: %sMB (%s) ==\n' "$KIND" "$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)" \
  "${ZRAM_ID:+zram$ZRAM_ID}"

# ---------------------------------------------------------------- 0. 语法
if want 0; then
printf '\n[0] 所有脚本都能被设备上的 shell 解析\n'
for _f in "$REPO"/*.sh "$REPO"/bin/*.sh; do
  for _sh in mksh "busybox sh"; do
    check "$_sh -n ${_f#"$REPO"/}" $_sh -n "$_f"
  done
done

# ---------------------------------------------------------------- 1. 扫描 + 演练
fi

if want 1; then
printf '\n[1] apps/ 布局：候选与保护名单；演练模式不动手\n'
new_scene s1 apps dry_run=1 mem_low_mb=60000 mem_target_mb=60000
spawn_standard apps
run_mod bin/reclaim.sh --scan >"$S/scan.txt" 2>&1
_order=$(awk 'NR > 3 {print $5}' "$S/scan.txt" | tr '\n' ' ')
# 候选按包名显示，B2（com.mid.video:push）显示为 com.mid.video
check "扫描顺序 = 大到小 [$_order]" [ "$_order" = "com.big.game com.mid.video com.ancestor.frozen com.mid.video " ]
check "只冻结在 uid 层的进程也算冻结" grep -q com.ancestor.frozen "$S/scan.txt"
check "保护/排除/前台/未冻结/低 adj/系统 UID/小进程都不在候选里" \
  sh -c "! grep -qE 'com.oplus.camera|com.tencent.mm|com.fg.app|com.notfrozen|com.lowadj|com.sys.thing|nep.timeline|com.small' '$S/scan.txt'"
run_mod bin/reclaim.sh --run --manual >/dev/null 2>&1
check "演练：记录了会换出的进程" logged 'DRY would pageout pid=[0-9]+ pkg=com.big.game'
check "演练：记录了会结束的进程" logged 'DRY would reclaim pid=[0-9]+ pkg=com.big.game'
check "演练：所有进程都还活着" sh -c "kill -0 $PID_A && kill -0 $PID_B && kill -0 $PID_K && kill -0 $PID_B2"
check "演练：没有真的换出" [ "$(vmswap_mb "$PID_A")" -lt 5 ]

# ---------------------------------------------------------------- 2. 先换出再结束
fi

if want 2; then
printf '\n[2] apps/ 布局：先换出，目标仍不够再结束（单轮上限 2）\n'
new_scene s2 apps dry_run=0 mem_low_mb=60000 mem_target_mb=60000 max_kills_per_run=2 deep_pageout_max_mb=200
spawn_standard apps
run_mod bin/reclaim.sh --run --manual --json >"$S/out.json" 2>&1
check "先换出：大进程换出 ~200MB" logged 'DEEP pid=[0-9]+ pkg=com.big.game pss=[0-9]+MB pageout=(1[5-9][0-9]|20[0-9])MB'
check "换出发生在结束进程之前" sh -c "awk '/DEEP pid/ {d = NR} /RECLAIM pid/ && !r {r = NR} END {exit !(d && r && d < r)}' '$S/log/reclaim.log'"
check "单轮最多结束 2 个" [ "$(grep -c 'RECLAIM pid=' "$S/log/reclaim.log")" = "2" ]
check "结束的是最大的两个（A、B）" sh -c "! kill -0 $PID_A 2>/dev/null && ! kill -0 $PID_B 2>/dev/null"
check "其余候选还活着（K、B2）" sh -c "kill -0 $PID_K && kill -0 $PID_B2"
check "保护对象全部存活" protected_alive
check "结束前没有先解冻（cgroup.freeze 仍为 1）" \
  sh -c "[ \"\$(cat $S/cg/apps/uid_10101/pid_$PID_A/cgroup.freeze)\" = 1 ]"
check "JSON 输出合法且计数正确" python3 -c "
import json,sys; d=json.load(open('$S/out.json')); sys.exit(not (d['kills']==2 and d['paged']>=150))"

# ---------------------------------------------------------------- 3. 换出够了就不杀
fi

if want 3; then
printf '\n[3] 根布局 uid_*/pid_*：换出就达到目标时一个都不杀\n'
new_scene s3 root dry_run=0 mem_low_mb=60000 deep_pageout_max_mb=400
spawn_standard root
_tgt=$(($(avail_mb) + 150))
printf 'mem_target_mb=%s\n' "$_tgt" >>"$S/data/config.conf"
run_mod bin/reclaim.sh --scan >"$S/scan.txt" 2>&1
check "根布局能识别 (cgroup: $S/cg)" grep -q "^cgroup: $S/cg\$" "$S/scan.txt"
check "根布局下候选正确" grep -q com.big.game "$S/scan.txt"
run_mod bin/reclaim.sh --run --manual >/dev/null 2>&1
check "有换出" logged 'DEEP total=[0-9]+MB'
check "没有结束任何进程" logged 'RECLAIM done kills=0 '
check "所有进程都还活着" sh -c "kill -0 $PID_A && kill -0 $PID_B && kill -0 $PID_K && kill -0 $PID_B2"
check "保护对象全部存活" protected_alive

# ---------------------------------------------------------------- 4. 大进程看门狗
fi

if want 4; then
printf '\n[4] 内存不紧张、但有冻结大进程：只换出，不结束\n'
new_scene s4 apps dry_run=0 mem_low_mb=1 psi_enable=0 high_pss_mb=300
spawn_standard apps
run_mod bin/reclaim.sh --run --high-check >/dev/null 2>&1
check "对大进程做了换出" logged "HIGH pid=$PID_A pkg=com.big.game reason=high_pss\\([0-9]+MB\\) pageout=[1-9][0-9]*MB"
check "大进程还活着" alive "$PID_A"
check "没有结束任何进程" not_logged 'RECLAIM pid='

# ---------------------------------------------------------------- 5. 上游顺序
fi

if want 5; then
printf '\n[5] reclaim_order=kill_first：先结束最大的，再换出\n'
new_scene s5 apps dry_run=0 mem_low_mb=60000 mem_target_mb=60000 max_kills_per_run=1 reclaim_order=kill_first
spawn_standard apps
run_mod bin/reclaim.sh --run --manual >/dev/null 2>&1
check "最大的 A 被结束" dead "$PID_A"
check "结束在换出之前" sh -c "awk '/RECLAIM pid/ {r = NR} /DEEP pid/ && !d {d = NR} END {exit !(r && d && r < d)}' '$S/log/reclaim.log'"
check "保护对象全部存活" protected_alive

# ---------------------------------------------------------------- 6. 前台舒缓
fi

if want 6; then
printf '\n[6] 前台舒缓：内存充足时不动；手动触发时换出量受限\n'
new_scene s6 apps dry_run=0 mem_low_mb=1 psi_enable=0 app_pageout_max_mb=64 app_pageout_passes=2 app_pss_mb=100
spawn_app "$S" P1 10120 com.fg.relief 300 0 none apps
spawn_app "$S" P2 10120 com.fg.relief:render 200 0 none apps
printf 'com.fg.relief' >"$S/fg"
run_mod bin/app_relief.sh >/dev/null 2>&1
check "内存充足：没有发 trim" sh -c "! grep -q 'send-trim-memory' '$S/calls.log'"
check "内存充足：没有换出" [ "$(vmswap_mb "$PID_P1")" -lt 5 ]
run_mod bin/app_relief.sh --force --json >"$S/relief.json" 2>&1
check "手动：两个进程都发了 trim" [ "$(grep -c 'send-trim-memory' "$S/calls.log")" = "2" ]
_sw=$(($(vmswap_mb "$PID_P1") + $(vmswap_mb "$PID_P2")))
check "手动：实际换出 ${_sw}MB ≤ 上限 64MB（+4MB 取整余量）" [ "$_sw" -le 68 ]
check "手动：实际换出 > 0" [ "$_sw" -gt 0 ]
check "手动：两个进程都没被结束" sh -c "kill -0 $PID_P1 && kill -0 $PID_P2"
printf 'mem_low_mb=60000\n' >>"$S/data/config.conf"
rm -f "$S/data/state/last_app_run"
run_mod bin/app_relief.sh >/dev/null 2>&1
check "内存紧张：自动舒缓会执行" logged 'APP RELIEF done pkg=com.fg.relief'

# ---------------------------------------------------------------- 7. VM / zram
fi

if want 7; then
printf '\n[7] ColorOS 上不碰 zram 与 swap\n'
new_scene s7 apps
run_mod bin/vm_tune.sh apply >/dev/null 2>&1
check "默认 vm_tune=0：跳过" logged 'VM: vm_tune=0, skipped'
_saved=""
for _k in swappiness vfs_cache_pressure dirty_writeback_centisecs dirty_expire_centisecs page-cluster; do
  _saved="$_saved $_k=$(cat /proc/sys/vm/$_k)"
done
printf 'vm_tune=1\nzram_enable=1\n' >>"$S/data/config.conf"
run_mod bin/vm_tune.sh apply >/dev/null 2>&1
for _kv in $_saved; do printf '%s' "${_kv#*=}" >"/proc/sys/vm/${_kv%%=*}"; done
check "即使打开 zram_enable：ColorOS 上跳过" logged 'VM zram: ColorOS manages zram'
check "没有调用 mkswap / swapon / swapoff" sh -c "! grep -qE '^(mkswap|swapon|swapoff)' '$S/calls.log'"

# ---------------------------------------------------------------- 8. ctl.sh
fi

if want 8; then
printf '\n[8] ctl.sh：状态、设置、预设、诊断、配置注入\n'
new_scene s8 apps
spawn_app "$S" A 10101 com.big.game 120 905 pid apps
run_mod bin/ctl.sh status --json >"$S/st.json" 2>&1
check "status --json 是合法 JSON" python3 -c "
import json,sys; d=json.load(open('$S/st.json')); sys.exit(not (d['coloros']==1 and d['cgroup']==1 and d['dry_run']==1 and d['order']=='pageout_first'))"
run_mod bin/ctl.sh set dry_run=0 >"$S/set1.json" 2>&1
check "set dry_run=0 成功" grep -q '"ok":1' "$S/set1.json"
check "配置里 dry_run 变成 0" grep -q "^dry_run='0'" "$S/data/config.conf"
run_mod bin/ctl.sh set reclaim_order=bogus >"$S/set2.json" 2>&1
check "非法取值被拒绝" grep -q '"ok":0' "$S/set2.json"
run_mod bin/ctl.sh preset aggressive >/dev/null 2>&1
check "预设切换写入 profile 与 reclaim_order" sh -c "grep -q \"^profile='aggressive'\" '$S/data/config.conf' && grep -q \"^reclaim_order='pageout_first'\" '$S/data/config.conf'"
run_mod bin/ctl.sh diag >"$S/diag.txt" 2>&1
check "诊断：识别 ColorOS" grep -q '^coloros   : yes' "$S/diag.txt"
check "诊断：报告 cgroup 冻结数" grep -qE '^cgroup    : root=.* app_procs=1 frozen=1' "$S/diag.txt"
check "诊断：前台识别" grep -q '^foreground: com.fg.app' "$S/diag.txt"
printf 'dry_run=$(touch %s/pwned)\nenable=1;touch %s/pwned2\n' "$S" "$S" >>"$S/data/config.conf"
run_mod bin/ctl.sh status >/dev/null 2>&1
check "配置里的命令不会被执行" sh -c "[ ! -e '$S/pwned' ] && [ ! -e '$S/pwned2' ]"
check "非法配置行被记录" logged 'WARN config: [0-9]+ invalid line'

# ---------------------------------------------------------------- 9. 守护全链路
fi

if want 9; then
printf '\n[9] 守护进程全链路（ctl start → daemon → reclaim → stop）\n'
new_scene s9 apps dry_run=1 interval=5 mem_low_mb=60000 mem_target_mb=60000 cooldown_sec=0
spawn_standard apps
run_mod bin/ctl.sh start >"$S/start.json" 2>&1
sleep 12
run_mod bin/ctl.sh status --json >"$S/st.json" 2>&1
check "daemon 与 watchdog 在跑" python3 -c "
import json,sys; d=json.load(open('$S/st.json')); sys.exit(not (d['daemon']==1 and d['watchdog']==1 and d['hb_age']<15))"
check "daemon 启动并执行了（演练）回收" sh -c "grep -q 'daemon start' '$S/log/reclaim.log' && grep -q 'DRY would' '$S/log/reclaim.log'"
check "daemon 刷新了桌面 / 输入法保护" grep -q 'com.android.launcher' "$S/data/state/protect.dynamic"
run_mod bin/ctl.sh stop >/dev/null 2>&1
sleep 2
_left=0
for _d in /proc/[0-9]*; do
  tr '\0' ' ' 2>/dev/null <"$_d/cmdline" | grep -qE "$MOD/bin/(daemon|watchdog).sh" && _left=$((_left + 1))
done
check "stop 之后守护全部退出" [ "$_left" = "0" ]
check "演练期间所有应用都还活着" sh -c "kill -0 $PID_A && kill -0 $PID_B && kill -0 $PID_K"

fi

printf '\n== %s: %s passed, %s failed ==\n' "$KIND" "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
