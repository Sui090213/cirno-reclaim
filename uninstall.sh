#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - uninstall.sh
#  模块卸载时执行：先停进程，再清数据目录和日志。
#  注意：pid 可能被系统复用，杀之前必须核对命令行属于本模块。
# ============================================================================

CR_DATA=/data/adb/cirno_reclaim
CR_MOD=/data/adb/modules/cirno_reclaim

# 是否属于本模块的进程
is_ours() {
  _pid=$1
  [ -r "/proc/$_pid/cmdline" ] || return 1
  tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null | grep -q "cirno_reclaim"
}

kill_pidfile() {
  # $1 = pid 文件, $2 = 信号
  _f=$1
  _sig=$2
  [ -r "$_f" ] || return 0
  _p=$(cat "$_f" 2>/dev/null)
  case "$_p" in
    ''|*[!0-9]*) return 0 ;;
  esac
  is_ours "$_p" || return 0
  kill "-$_sig" "$_p" 2>/dev/null
  return 0
}

# 1. 先 TERM，等一秒再 KILL
kill_pidfile "$CR_DATA/daemon.pid" TERM
kill_pidfile "$CR_DATA/watchdog.pid" TERM
sleep 1
kill_pidfile "$CR_DATA/daemon.pid" KILL
kill_pidfile "$CR_DATA/watchdog.pid" KILL

# 2. pid 文件丢了也要收干净（只杀本模块路径下的进程）
for _d in /proc/[0-9]*; do
  _p=${_d#/proc/}
  [ -r "$_d/cmdline" ] || continue
  _c=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null)
  case "$_c" in
    *"/data/adb/modules/cirno_reclaim/service.sh"*|\
    *"/data/adb/modules/cirno_reclaim/bin/daemon.sh"*|*"/data/adb/modules/cirno_reclaim/bin/cirno_daemon"*|\
    *"/data/adb/modules/cirno_reclaim/bin/watchdog.sh"*)
      kill -9 "$_p" 2>/dev/null
      ;;
  esac
done

# 3. 先停用本模块创建的 swapfile，再删数据目录
if [ -f "$CR_DATA/swapfile" ] && grep -q "$CR_DATA/swapfile" /proc/swaps 2>/dev/null; then
  swapoff "$CR_DATA/swapfile" 2>/dev/null
fi

# 4. 删除运行时数据（配置、状态、swapfile）与模块内日志
rm -rf "$CR_DATA" 2>/dev/null
rm -rf "$CR_MOD/log" 2>/dev/null
rm -f "$CR_MOD/nohup.out" 2>/dev/null
exit 0
