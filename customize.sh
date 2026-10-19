#!/sbin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - customize.sh
#  安装脚本：Magisk / KernelSU / APatch 通用。
# ============================================================================

SKIPUNZIP=0

ui_print " "
ui_print "=============================================="
ui_print "   Cirno Reclaim Hybrid v2.0.0-coloros.1"
ui_print "   作者: flyingr · ColorOS 17 适配: yishisanren"
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

# ARCH 变量不是所有管理器都会给，用 ABI 兜底
_arch=${ARCH:-}
if [ -z "$_arch" ]; then
  case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
    arm64*) _arch=arm64 ;;
    armeabi*) _arch=arm ;;
    x86_64*) _arch=x64 ;;
    x86*) _arch=x86 ;;
  esac
fi
ui_print "- 架构: ${_arch:-unknown}"

_oplusrom=$(getprop ro.build.version.oplusrom 2>/dev/null)
if [ -n "$_oplusrom" ] || [ -d /my_product ]; then
  ui_print "- 系统: ColorOS ${_oplusrom:-} ($(getprop ro.product.model 2>/dev/null))"
  ui_print "  · 不接管系统的「内存扩展」（zram），不改系统内存参数"
else
  ui_print "- 系统: 非 ColorOS（本分支针对 ColorOS 17 适配，其他系统未验证）"
fi
if pm list packages 2>/dev/null | grep -q 'nep.timeline.cirno'; then
  ui_print "- Cirno: 已安装"
else
  ui_print "- Cirno: 未检测到（没有冻结的进程，本模块基本不会动作）"
fi
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
else
  # 管理器没有提供 set_perm 时退回 chmod
  chmod -R 755 "$MODPATH" 2>/dev/null
  find "$MODPATH" -type f ! -name '*.sh' -exec chmod 644 {} \; 2>/dev/null
fi

# 运行时目录
CR_DATA=/data/adb/cirno_reclaim
mkdir -p "$CR_DATA/state" 2>/dev/null
chmod 700 "$CR_DATA" 2>/dev/null
chmod 700 "$CR_DATA/state" 2>/dev/null

# 已有配置不覆盖（升级保留用户设置），缺失则安装默认
if [ -f "$CR_DATA/config.conf" ]; then
  ui_print "- 保留已有配置: $CR_DATA/config.conf"
  chmod 600 "$CR_DATA/config.conf" 2>/dev/null
else
  cp -f "$MODPATH/config.conf" "$CR_DATA/config.conf" 2>/dev/null
  chmod 600 "$CR_DATA/config.conf" 2>/dev/null
  ui_print "- 已安装默认配置"
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

case "$_arch" in
  arm64)
    [ -x "$MODPATH/bin/cirno_pageout" ] &&
      ui_print "- 页换出 helper: 已内置" ||
      ui_print "- 页换出 helper: 未内置（前台仅 trim，可自行编译）"
    ;;
  *)
    [ -f "$MODPATH/bin/cirno_pageout" ] && rm -f "$MODPATH/bin/cirno_pageout"
    ui_print "- 非 arm64 设备: 已移除 pageout helper，前台只做 trim"
    ;;
esac

ui_print " "
ui_print "- 功能概览"
ui_print "  · 内存紧张时先把 Cirno 冻结的应用压进 zram（不杀）"
ui_print "  · 仍不够才结束最大的冻结应用"
ui_print "  · 前台 trim + 限额页换出"
ui_print "  · 三层保活：service → watchdog → daemon"
ui_print "  · KsuWebUI：状态 / 设置 / 诊断"
ui_print " "
if grep -q "^dry_run=['\"]*1" "$CR_DATA/config.conf" 2>/dev/null; then
  ui_print "- 当前为演练模式：只记录不动手"
  ui_print "  观察一两天日志，再到 WebUI「设置」关闭演练模式"
  ui_print " "
fi
ui_print "- 设置目录: $CR_DATA"
ui_print "- 日志: /data/adb/modules/cirno_reclaim/log/reclaim.log"
ui_print "- 反馈: github.com/yishisanren/cirno-reclaim/issues"
ui_print " "
ui_print "- 安装完成，重启后生效"
ui_print "=============================================="
ui_print " "
