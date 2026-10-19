#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - bin/vm_tune.sh
#  zram + swapfile + VM 参数调优（吸收 HybridRAM 的思路，代码重写）。
#
#  用法：
#      vm_tune.sh apply     # 一次性应用（开机时调用）
#      vm_tune.sh reassert  # 只把被 Android 改回去的参数写回（守护定时调用）
#      vm_tune.sh status    # 打印当前状态
# ============================================================================

. "$(dirname "$0")/common.sh"

ZRAM_SYS=""
ZRAM_DEV=""

find_zram() {
  for _i in 0 1 2 3; do
    if [ -d "/sys/block/zram$_i" ]; then
      ZRAM_SYS="/sys/block/zram$_i"
      ZRAM_DEV="/dev/block/zram$_i"
      return 0
    fi
  done
  for _d in /sys/block/zram*; do
    [ -d "$_d" ] || continue
    ZRAM_SYS="$_d"
    ZRAM_DEV="/dev/block/$(basename "$_d")"
    return 0
  done
  return 1
}

write_sys() {
  # $1 = 路径, $2 = 值；写入成功返回 0
  [ -w "$1" ] || return 1
  printf '%s' "$2" >"$1" 2>/dev/null && return 0
  return 1
}

read_sys() {
  cat "$1" 2>/dev/null
}

zram_in_use() {
  # /proc/swaps 里的设备名可能是 /dev/block/zram0 也可能是 /dev/zram0，
  # 按 basename 匹配，两种都认。
  [ -n "$ZRAM_DEV" ] || return 1
  _cr_b=$(basename "$ZRAM_DEV")
  awk -v b="$_cr_b" '
    $1 == "/dev/block/" b || $1 == "/dev/" b { found = 1 }
    END { exit(found ? 0 : 1) }
  ' /proc/swaps 2>/dev/null
}

pick_algorithm() {
  # comp_algorithm 的格式类似 "lzo [lz4] lz4hc"，用 awk 选，避免通配符展开
  _avail=$(read_sys "$ZRAM_SYS/comp_algorithm")
  [ -n "$_avail" ] || { printf '%s' ""; return 0; }
  printf '%s\n' "$_avail" | tr '[]' '  ' | tr ' ' '\n' | awk -v want="${zram_algorithm:-lz4}" '
    NF { alg[++n] = $0 }
    END {
      for (i = 1; i <= n; i++) if (alg[i] == want) { print want; exit }
      split("lz4 lz4hc zstd lzo-rle lzo", pri, " ")
      for (j = 1; j <= 5; j++)
        for (i = 1; i <= n; i++) if (alg[i] == pri[j]) { print pri[j]; exit }
    }'
}

zram_disksize_bytes() {
  if [ "${zram_disksize_mb:-0}" -gt 0 ] 2>/dev/null; then
    _mb=$zram_disksize_mb
  else
    _mb=$(( $(mem_total_mb) / 2 ))
    [ "$_mb" -lt 1024 ] && _mb=1024
    [ "$_mb" -gt 6144 ] && _mb=6144
  fi
  printf '%s' $((_mb * 1024 * 1024))
}

setup_zram() {
  [ "${zram_enable:-0}" = "1" ] || return 0
  # ColorOS 的「内存扩展」= zram + 把冷页写回存储（hybridswap），由系统守护进程管理。
  # reset / 重建 zram0 会把它整套打断，所以在 ColorOS 上无论配置如何都不碰 zram。
  if is_coloros; then
    log "VM zram: ColorOS manages zram (memory extension), skipped"
    return 0
  fi
  find_zram || { log "VM zram: no zram device, skipped"; return 0; }

  if zram_in_use; then
    log "VM zram: already active ($ZRAM_DEV), keep existing setup"
    return 0
  fi

  # swapoff 失败说明还有页面没换回来（内存紧张），此时绝不能 mkswap 覆盖
  if swapoff "$ZRAM_DEV" >/dev/null 2>&1; then
    :
  else
    if zram_in_use; then
      log "VM zram: swapoff failed and still in use, refuse to touch it"
      return 0
    fi
  fi

  # disksize 非 0 说明设备还处于已初始化状态，直接写会 EBUSY
  _ds=$(read_sys "$ZRAM_SYS/disksize")
  case "$_ds" in
    ''|0) : ;;
    *)
      if [ -w "$ZRAM_SYS/reset" ]; then
        if write_sys "$ZRAM_SYS/reset" 1; then
          log "VM zram: reset (was disksize=$_ds)"
        fi
      fi
      _ds=$(read_sys "$ZRAM_SYS/disksize")
      case "$_ds" in
        ''|0) : ;;
        *)
          log "VM zram: device busy (disksize=$_ds), skip"
          return 0
          ;;
      esac
      ;;
  esac

  _alg=$(pick_algorithm)
  if [ -n "$_alg" ]; then
    write_sys "$ZRAM_SYS/comp_algorithm" "$_alg" && log "VM zram: algorithm=$_alg"
  fi
  [ -w "$ZRAM_SYS/max_comp_streams" ] && write_sys "$ZRAM_SYS/max_comp_streams" 4

  if [ -w "$ZRAM_SYS/disksize" ]; then
    _bytes=$(zram_disksize_bytes)
    if write_sys "$ZRAM_SYS/disksize" "$_bytes"; then
      log "VM zram: disksize=$((_bytes / 1024 / 1024))MB"
    else
      log "VM zram: disksize write failed"
      return 0
    fi
  fi

  mkswap "$ZRAM_DEV" >/dev/null 2>&1
  if swapon -p 100 "$ZRAM_DEV" >/dev/null 2>&1; then
    log "VM zram: swapon priority=100"
  elif swapon "$ZRAM_DEV" >/dev/null 2>&1; then
    log "VM zram: swapon (no priority support)"
  else
    log "VM zram: swapon failed"
  fi
  return 0
}

setup_swapfile() {
  [ "${swapfile_enable:-0}" = "1" ] || return 0
  _mb=${swapfile_mb:-2048}
  [ "$_mb" -ge 256 ] 2>/dev/null || _mb=256
  _f="$DATA_DIR/swapfile"

  # 剩余空间不足就别写：写满 /data 会直接让系统出问题
  _avail_kb=$(df -k "$DATA_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
  case "$_avail_kb" in
    ''|*[!0-9]*) : ;;
    *)
      _need_kb=$((_mb * 1024 + 262144))
      if [ "$_avail_kb" -lt "$_need_kb" ]; then
        log "VM swapfile: not enough space (${_avail_kb}KB < ${_need_kb}KB), skip"
        return 0
      fi
      ;;
  esac

  # 已在用且大小对得上：什么都不做
  if grep -q "$_f" /proc/swaps 2>/dev/null; then
    _cur_mb=$(( $(wc -c <"$_f" 2>/dev/null | tr -d ' ') / 1024 / 1024 ))
    if [ "$_cur_mb" = "$_mb" ]; then
      log "VM swapfile: already active, keep"
      return 0
    fi
    # 大小不对要重建，先 swapoff；失败就保持原样，绝不 rm 活动文件
    if ! swapoff "$_f" >/dev/null 2>&1; then
      log "VM swapfile: swapoff failed, keep existing to avoid data loss"
      return 0
    fi
  fi

  if [ -f "$_f" ]; then
    rm -f "$_f" 2>/dev/null
  fi

  log "VM swapfile: creating ${_mb}MB at $_f"
  _ok=1
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${_mb}M" "$_f" 2>/dev/null || _ok=0
  else
    _ok=0
  fi
  if [ "$_ok" = "0" ]; then
    dd if=/dev/zero of="$_f" bs=1M count="$_mb" 2>/dev/null || _ok=0
  fi
  if [ "$_ok" = "0" ] || [ ! -s "$_f" ]; then
    log "VM swapfile: allocation failed, cleanup"
    rm -f "$_f" 2>/dev/null
    return 0
  fi
  chmod 600 "$_f" 2>/dev/null

  if ! mkswap "$_f" >/dev/null 2>&1; then
    log "VM swapfile: mkswap failed, cleanup"
    rm -f "$_f" 2>/dev/null
    return 0
  fi

  if swapon -p 10 "$_f" >/dev/null 2>&1; then
    log "VM swapfile: swapon priority=10"
  elif swapon "$_f" >/dev/null 2>&1; then
    log "VM swapfile: swapon"
  else
    log "VM swapfile: swapon failed"
  fi
  return 0
}

set_vm_param() {
  # $1 = 键, $2 = 值
  _p="/proc/sys/vm/$1"
  [ -w "$_p" ] || return 0
  _cur=$(cat "$_p" 2>/dev/null)
  [ "$_cur" = "$2" ] && return 0
  printf '%s' "$2" >"$_p" 2>/dev/null
  return 0
}

apply_page_cluster() {
  _want=${page_cluster:-1}
  _p=/proc/sys/vm/page-cluster
  [ -w "$_p" ] || return 0
  for _v in "$_want" 0 1 2; do
    printf '%s' "$_v" >"$_p" 2>/dev/null
    [ "$(cat "$_p" 2>/dev/null)" = "$_v" ] && return 0
  done
  return 0
}

apply_io_tune() {
  [ "${io_tune:-0}" = "1" ] || return 0
  for _q in /sys/block/*/queue; do
    [ -d "$_q" ] || continue
    _s="$_q/scheduler"
    [ -f "$_s" ] || continue
    if grep -qw noop "$_s" 2>/dev/null; then
      printf 'noop' >"$_s" 2>/dev/null
    elif grep -qw deadline "$_s" 2>/dev/null; then
      printf 'deadline' >"$_s" 2>/dev/null
    fi
    [ -f "$_q/read_ahead_kb" ] && printf '%s' "${read_ahead_kb:-128}" >"$_q/read_ahead_kb" 2>/dev/null
  done
  return 0
}

apply_vm_params() {
  [ -w /proc/sys/vm/swappiness ] || { log "VM: /proc/sys/vm not writable, skipped"; return 0; }
  set_vm_param swappiness "${swappiness:-80}"
  set_vm_param vfs_cache_pressure "${vfs_cache_pressure:-100}"
  set_vm_param dirty_writeback_centisecs "${dirty_writeback_centisecs:-1500}"
  set_vm_param dirty_expire_centisecs "${dirty_expire_centisecs:-500}"
  apply_page_cluster
  apply_io_tune
  return 0
}

vm_apply() {
  [ "${vm_tune:-0}" = "1" ] || { log "VM: vm_tune=0, skipped"; return 0; }
  log "VM: applying tuning (total=$(mem_total_mb)MB)"
  is_coloros && log "VM: WARN ColorOS also tunes swappiness/zram itself; values may be overridden"
  setup_zram
  setup_swapfile
  apply_vm_params
  log "VM: done swap=$(swap_total_mb)MB free=$(swap_free_mb)MB avail=$(mem_avail_mb)MB"
  return 0
}

vm_reassert() {
  [ "${vm_tune:-0}" = "1" ] || return 0
  apply_vm_params
  # swap 整个消失时才重建，且 10 分钟内不重复尝试，避免和用户手动关闭打架
  if [ "${zram_enable:-0}" = "1" ] && ! is_coloros && find_zram; then
    if [ "$(swap_total_mb)" = "0" ] && [ "$(since_epoch_file zram_retry)" -gt 600 ]; then
      date +%s >"$STATE_DIR/zram_retry" 2>/dev/null
      log "VM: swap is gone, re-applying zram"
      setup_zram
      setup_swapfile
    fi
  fi
  return 0
}

vm_status() {
  find_zram && _z="$ZRAM_DEV" || _z="none"
  printf 'mem_total=%s\n' "$(mem_total_mb)"
  printf 'mem_avail=%s\n' "$(mem_avail_mb)"
  printf 'swap_total=%s\n' "$(swap_total_mb)"
  printf 'swap_free=%s\n' "$(swap_free_mb)"
  printf 'zram_dev=%s\n' "$_z"
  printf 'zram_disksize=%s\n' "$(read_sys "$ZRAM_SYS/disksize")"
  printf 'zram_algorithm=%s\n' "$(read_sys "$ZRAM_SYS/comp_algorithm")"
  printf 'swappiness=%s\n' "$(read_sys /proc/sys/vm/swappiness)"
  printf 'vfs_cache_pressure=%s\n' "$(read_sys /proc/sys/vm/vfs_cache_pressure)"
  printf 'page_cluster=%s\n' "$(read_sys /proc/sys/vm/page-cluster)"
  printf '%s\n' '--- /proc/swaps ---'
  cat /proc/swaps 2>/dev/null
  return 0
}

cr_init_dirs
cfg_load

case "$1" in
  apply) vm_apply ;;
  reassert) vm_reassert ;;
  status) vm_status ;;
  *)
    printf 'usage: %s {apply|reassert|status}\n' "$0"
    exit 2
    ;;
esac
