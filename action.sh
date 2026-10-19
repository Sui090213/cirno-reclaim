#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - action.sh
#  KernelSU / APatch 管理器里的「操作」按钮：执行一次手动回收并展示结果。
# ============================================================================

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR=$(pwd) ;;
esac
CTL="$MODDIR/bin/ctl.sh"

echo "Cirno Reclaim Hybrid - 手动回收"
echo "--------------------------------"
sh "$CTL" status
echo
echo "--------------------------------"
echo "回收结果"
sh "$MODDIR/bin/reclaim.sh" --run --manual --json
echo
echo "--------------------------------"
echo "最新日志"
sh "$CTL" log 20
echo
echo "反馈: github.com/yishisanren/cirno-reclaim/issues"
