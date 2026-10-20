#!/sbin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - customize.sh
#  安装脚本：Magisk / KernelSU / APatch 通用。
#
#  v2.3.0 新增：安装时用音量键选择系统（HyperOS / ColorOS），
#  选择结果写进 profile.pending，首次开机由 post-fs-data.sh 套用对应配置档案。
#  不按键则自动识别；从旧版升级且不按键时只记录识别结果，不动用户已有参数。
# ============================================================================

SKIPUNZIP=0

# 某些精简安装环境没有 ui_print
if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { printf '%s\n' "$1"; }
fi

ui_print " "
ui_print "=============================================="
ui_print "   Cirno Reclaim Hybrid v2.3.4"
ui_print "   作者: flyingr"
ui_print "=============================================="
ui_print " "

if [ -n "$KSU" ]; then
  ui_print "- 环境: KernelSU (KSU=$KSU)"
elif [ -n "$MAGISK_VER" ]; then
  ui_print "- 环境: Magisk $MAGISK_VER"
elif [ -n "$APATCH" ]; then
  ui_print "- 环境: APatch"
else
  ui_print "- 环境: 标准 Magisk 模块接口"
fi

# ARCH 变量不是所有管理器都会给，用 ABI 兜底。
# 注意：管理器给的 ARCH 可能是 arm64-v8a / aarch64，而不是裸 arm64。
# 以前用精确匹配 `case arm64)`，结果在 KernelSU 上把两个原生组件当成「非 arm64」删掉了。
_arch=${ARCH:-}
[ -n "$_arch" ] || _arch=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$_arch" in
  arm64*|aarch64*) _arch=arm64 ;;
  armeabi*|armv7*|arm) _arch=arm ;;
  x86_64*|x64*) _arch=x64 ;;
  x86*) _arch=x86 ;;
esac
ui_print "- 架构: ${_arch:-unknown}"

# ---------------------------------------------------------------- 系统识别
# 与 bin/common.sh 的 rom_detect 保持同样的判定顺序
_detect_rom() {
  if [ -n "$(getprop ro.mi.os.version.name 2>/dev/null)" ] ||
     [ -n "$(getprop ro.miui.ui.version.name 2>/dev/null)" ]; then
    printf '%s' 'hyperos'
    return 0
  fi
  if [ -n "$(getprop ro.build.version.oplusrom 2>/dev/null)" ] ||
     [ -n "$(getprop ro.build.version.opporom 2>/dev/null)" ] ||
     [ -d /my_product ]; then
    printf '%s' 'coloros'
    return 0
  fi
  printf '%s' 'generic'
}

_rom_hint() {
  _v=$(getprop ro.mi.os.version.name 2>/dev/null)
  [ -n "$_v" ] || _v=$(getprop ro.miui.ui.version.name 2>/dev/null)
  [ -n "$_v" ] && { printf 'HyperOS/MIUI %s' "$_v"; return 0; }
  _v=$(getprop ro.build.version.oplusrom 2>/dev/null)
  [ -n "$_v" ] && { printf 'ColorOS %s' "$_v"; return 0; }
  _v=$(getprop ro.build.version.opporom 2>/dev/null)
  [ -n "$_v" ] && { printf 'ColorOS %s' "$_v"; return 0; }
  [ -d /my_product ] && { printf 'ColorOS (OPlus base)'; return 0; }
  printf '其他 ROM'
}

_detected=$(_detect_rom)
ui_print "- 检测到系统: $(_rom_hint)"
ui_print " "

# ---------------------------------------------------------------- 音量键选择
# 读一次音量键事件：输出 up / down / none。
# 用 timeout + getevent 轮询，单次 1 秒，外层再控制总时长。
_read_volume_key() {
  _want=${1:-8}
  command -v getevent >/dev/null 2>&1 || { printf 'none'; return 0; }
  command -v timeout >/dev/null 2>&1 || { printf 'none'; return 0; }

  _devs=""
  for _d in /dev/input/event*; do
    [ -e "$_d" ] || continue
    _devs="$_devs $_d"
  done
  [ -n "$_devs" ] || { printf 'none'; return 0; }

  _deadline=$(( $(date +%s) + _want ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    # 这里故意不加引号：要把多个设备路径拆成多个参数
    _out=$(timeout 1 getevent -lc 20 $_devs 2>/dev/null)
    case "$_out" in
      *KEY_VOLUMEUP*) printf 'up'; return 0 ;;
      *KEY_VOLUMEDOWN*) printf 'down'; return 0 ;;
    esac
  done
  printf 'none'
}

_choice=""
# 环境变量优先，方便脚本化安装
case "${CR_PROFILE:-}" in
  hyperos|coloros|generic|auto) _choice=$CR_PROFILE ;;
esac

if [ -z "$_choice" ]; then
  ui_print "----------------------------------------------"
  ui_print "   选择你的系统（用音量键，8 秒内）"
  ui_print "----------------------------------------------"
  ui_print "   音量上  →  HyperOS / MIUI（小米）"
  ui_print "   音量下  →  ColorOS / realmeUI / OxygenOS"
  ui_print "   不按键  →  自动识别（$(_rom_hint)）"
  ui_print " "
  _key=$(_read_volume_key 8)
  case "$_key" in
    up) _choice=hyperos; ui_print "[音量上] 使用 HyperOS 适配档案" ;;
    down) _choice=coloros; ui_print "[音量下] 使用 ColorOS 适配档案" ;;
    *) ui_print "[未按键] 使用自动识别" ;;
  esac
fi

# ---------------------------------------------------------------- 文件权限
ui_print " "
ui_print "- 设置文件权限"
if command -v set_perm_recursive >/dev/null 2>&1; then
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
  set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
  for f in "$MODPATH/service.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/uninstall.sh" "$MODPATH/action.sh"; do
    [ -f "$f" ] && set_perm "$f" 0 0 0755
  done
  for f in "$MODPATH"/bin/*.sh; do
    [ -f "$f" ] && set_perm "$f" 0 0 0755
  done
  [ -f "$MODPATH/bin/cirno_pageout" ] && set_perm "$MODPATH/bin/cirno_pageout" 0 0 0755
  [ -f "$MODPATH/bin/cirno_daemon" ] && set_perm "$MODPATH/bin/cirno_daemon" 0 0 0755
else
  # 管理器没有提供 set_perm 时退回 chmod
  chmod -R 755 "$MODPATH" 2>/dev/null
  find "$MODPATH" -type f ! -name '*.sh' -exec chmod 644 {} \; 2>/dev/null
fi

# ---------------------------------------------------------------- 运行时目录
CR_DATA=/data/adb/cirno_reclaim
_had_config=0
[ -s "$CR_DATA/config.conf" ] && _had_config=1
mkdir -p "$CR_DATA/state" 2>/dev/null
chmod 700 "$CR_DATA" 2>/dev/null
chmod 700 "$CR_DATA/state" 2>/dev/null

# 已有配置不覆盖（升级保留用户设置），缺失则安装默认
if [ "$_had_config" = "1" ]; then
  ui_print "- 保留已有配置: $CR_DATA/config.conf"
  chmod 600 "$CR_DATA/config.conf" 2>/dev/null
else
  cp -f "$MODPATH/config.conf" "$CR_DATA/config.conf" 2>/dev/null
  chmod 600 "$CR_DATA/config.conf" 2>/dev/null
  ui_print "- 已安装默认配置（首次为演练模式 dry_run=1）"
fi

# 停掉旧版本守护，避免升级后两个实例打架。
# pid 可能已被系统复用，杀之前必须核对命令行属于本模块。
stop_module_pid() {
  _pf=$1
  [ -r "$_pf" ] || return 0
  _p=$(cat "$_pf" 2>/dev/null)
  case "$_p" in
    ''|*[!0-9]*) rm -f "$_pf"; return 0 ;;
  esac
  if [ -r "/proc/$_p/cmdline" ]; then
    _cmd=$(tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null)
    case "$_cmd" in
      *"cirno_reclaim"*) kill -9 "$_p" 2>/dev/null ;;
    esac
  fi
  rm -f "$_pf" 2>/dev/null
  return 0
}

stop_module_pid "$CR_DATA/daemon.pid"
stop_module_pid "$CR_DATA/watchdog.pid"
[ -f "$CR_DATA/.stop" ] && rm -f "$CR_DATA/.stop"
rm -rf "$CR_DATA/lock.daemon" "$CR_DATA/lock.watchdog" "$CR_DATA/lock.reclaim" 2>/dev/null
rm -f "$CR_DATA/state/cpp.stats" "$CR_DATA/state/profile.applied" 2>/dev/null

# ---------------------------------------------------------------- 写入档案选择
# 首次开机由 post-fs-data.sh -> profile_bootstrap 读取并删除。
_pending=""
if [ -n "$_choice" ]; then
  _pending=$_choice
else
  if [ "$_had_config" = "1" ]; then
    # 升级安装且没按键：保留用户现有参数，只记录识别结果
    _pending=keep
  else
    _pending=auto
  fi
fi
printf '%s' "$_pending" >"$MODPATH/profile.pending" 2>/dev/null
chmod 600 "$MODPATH/profile.pending" 2>/dev/null

case "$_pending" in
  keep)
    ui_print "- 配置档案: 保留现有参数（识别结果会在下次开机写入）"
    ;;
  auto)
    ui_print "- 配置档案: 自动识别 → 下次开机套用"
    ;;
  *)
    ui_print "- 配置档案: $_pending（下次开机套用，可在 WebUI 场景页修改）"
    ;;
esac

# ---------------------------------------------------------------- 原生组件
case "$_arch" in
  arm64)
    [ -x "$MODPATH/bin/cirno_pageout" ] &&
      ui_print "- 页换出 helper: 已内置" ||
      ui_print "- 页换出 helper: 未内置（前台仅 trim，可自行编译）"
    [ -x "$MODPATH/bin/cirno_daemon" ] &&
      ui_print "- C++ 守护: 已内置（低功耗调度）" ||
      ui_print "- C++ 守护: 未内置，将回退到 Shell 守护"
    ;;
  *)
    [ -f "$MODPATH/bin/cirno_pageout" ] && rm -f "$MODPATH/bin/cirno_pageout"
    [ -f "$MODPATH/bin/cirno_daemon" ] && rm -f "$MODPATH/bin/cirno_daemon"
    ui_print "- 非 arm64 设备: 已移除原生组件，前台只做 trim、守护回退 shell"
    ;;
esac

ui_print " "
ui_print "- 功能概览"
ui_print "  · 冻结进程回收（Cirno cgroup v2 freezer，兼容两种 cgroup 布局）"
ui_print "  · 先页换出、不够才结束进程（reclaim_order=pageout_first）"
ui_print "  · 前台 trim + 多轮匿名页换出（只在内存紧张时执行）"
ui_print "  · zram / swapfile / VM 调参（OEM 自管 zram 时安全跳过）"
ui_print "  · 三层保活：service → watchdog → daemon"
ui_print "  · C++ 守护事件驱动调度，空闲时几乎不唤醒"
ui_print "  · KsuWebUI：控制台 / 场景 / 外观 / 关于"
ui_print " "
ui_print "- 设置目录: $CR_DATA"
ui_print "- 日志: /data/adb/modules/cirno_reclaim/log/reclaim.log"
ui_print "- 反馈邮箱: asui20090213@outlook.com"
ui_print " "
ui_print "- 安装完成，重启后生效"
ui_print "=============================================="
ui_print " "
