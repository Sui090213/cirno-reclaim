#!/system/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - post-fs-data.sh
#  开机早期执行：建目录、迁移配置、清掉重启后残留的 pid/状态。
#  这里必须快，不能起常驻进程。
# ============================================================================

. "$(dirname "$0")/bin/common.sh"

cr_init_dirs

# 重启后旧 pid 全部失效
rm -f "$PID_FILE" "$WD_PID_FILE" 2>/dev/null
rm -f "$STATE_DIR/supervisor.pid" "$DATA_DIR/.stop" 2>/dev/null
rm -f "$STATE_DIR/can_pageout" "$STATE_DIR/zram_retry" 2>/dev/null
rm -f "$MODDIR/nohup.out" 2>/dev/null

# 把模块自带 config.conf 里新增的键补进运行时配置
migrate_config() {
  _src="$MODDIR/config.conf"
  [ -r "$_src" ] || return 0
  _tmp="$CONF_FILE.tmp"
  cp -f "$CONF_FILE" "$_tmp" 2>/dev/null || return 0
  while IFS= read -r _line; do
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    case "$_line" in
      *=*) ;;
      *) continue ;;
    esac
    _k=${_line%%=*}
    [ -n "$_k" ] || continue
    if ! grep -q "^${_k}=" "$CONF_FILE" 2>/dev/null; then
      printf '%s\n' "$_line" >>"$_tmp"
      log "config: added new key $_k"
    fi
  done <"$_src"
  mv -f "$_tmp" "$CONF_FILE" 2>/dev/null
  chmod 600 "$CONF_FILE" 2>/dev/null
  return 0
}

if [ ! -f "$CONF_FILE" ]; then
  cp -f "$MODDIR/config.conf" "$CONF_FILE" 2>/dev/null
  chmod 600 "$CONF_FILE" 2>/dev/null
  log "post-fs-data: default config installed -> $CONF_FILE"
else
  migrate_config
fi

# 旧版本可能留下的日志文件统一收归模块目录
[ -f "$DATA_DIR/reclaim.log" ] && mv -f "$DATA_DIR/reclaim.log" "$LOG_DIR/reclaim.log.old" 2>/dev/null

# 首次安装时清一次缓存探测结果
[ -d "$STATE_DIR" ] && chmod 700 "$STATE_DIR" 2>/dev/null

log "post-fs-data: done $MODULE_VERSION"
exit 0
