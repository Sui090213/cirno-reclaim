#!/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - src/build.sh
#  交叉编译两个 arm64 组件：
#    bin/cirno_pageout  C  前台页换出（MADV_PAGEOUT）
#    bin/cirno_daemon   C++ 守护进程（调度 / 心跳 / 子进程超时）
#
#  用法：
#      ./build.sh                 # 用 zig 编两个
#      ZIG=/path/to/zig ./build.sh
#      ZIG="python3 -m ziglang" ./build.sh   # pip install ziglang==0.13.0
#      CC=aarch64-linux-android24-clang ./build.sh   # C helper 用 CC，C++ 仍需 zig
# ============================================================================
set -e

cd "$(dirname "$0")"
OUT_DIR=${1:-../bin}
mkdir -p "$OUT_DIR"

# ZIGCMD 可能是多个词（python3 -m ziglang），用的时候故意不加引号
if [ -n "${ZIG:-}" ]; then
  ZIGCMD=$ZIG
elif command -v zig >/dev/null 2>&1; then
  ZIGCMD=zig
elif python3 -m ziglang version >/dev/null 2>&1; then
  ZIGCMD="python3 -m ziglang"
else
  ZIGCMD=""
fi
[ -n "$ZIGCMD" ] && echo "==> zig: $ZIGCMD ($($ZIGCMD version 2>/dev/null))"

build_c() {
  echo "==> C helper -> $OUT_DIR/cirno_pageout"
  if [ -n "${CC:-}" ]; then
    $CC -O2 -static -s -o "$OUT_DIR/cirno_pageout" cirno_pageout.c
  elif [ -n "$ZIGCMD" ]; then
    $ZIGCMD cc -target aarch64-linux-musl -static -Os -s \
      -o "$OUT_DIR/cirno_pageout" cirno_pageout.c
  else
    echo "zig/clang not found, skip C helper (install zig 0.13+, pip install ziglang, or set CC)" >&2
    return 1
  fi
  chmod 755 "$OUT_DIR/cirno_pageout"
}

build_cpp() {
  echo "==> C++ daemon -> $OUT_DIR/cirno_daemon"
  if [ -z "$ZIGCMD" ]; then
    echo "zig not found (C++ needs zig c++), skip daemon" >&2
    return 1
  fi
  $ZIGCMD c++ -target aarch64-linux-musl -static -Os -s \
    -fno-exceptions -fno-rtti -Wall -Wextra \
    -o "$OUT_DIR/cirno_daemon" cirno_daemon.cpp
  chmod 755 "$OUT_DIR/cirno_daemon"
}

rc=0
build_c || rc=1
build_cpp || rc=1

echo "==> done (rc=$rc)"
ls -l "$OUT_DIR"/cirno_pageout "$OUT_DIR"/cirno_daemon 2>/dev/null || true
exit $rc
