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
#      CC=aarch64-linux-android24-clang ./build.sh   # 只编 C helper
# ============================================================================
set -e

cd "$(dirname "$0")"
OUT_DIR=${1:-../bin}
mkdir -p "$OUT_DIR"

ZIG=${ZIG:-zig}
if command -v "$ZIG" >/dev/null 2>&1; then
  HAVE_ZIG=1
else
  # 没装 zig 时也可以 pip install ziglang==0.13.0，用 python3 -m ziglang
  if [ -n "${ZIG:-}" ]; then
    ZIGCMD=$ZIG
  elif command -v zig >/dev/null 2>&1; then
    ZIGCMD=zig
  elif python3 -m ziglang version >/dev/null 2>&1; then
    ZIGCMD="python3 -m ziglang"
  else
    echo "zig not found. install zig 0.13+ (or pip install ziglang) or set CC to an aarch64 clang" >&2
    exit 1
  fi
  echo "==> zig cc -> aarch64-linux-musl ($ZIGCMD)"
  # ZIGCMD 可能是多个词，故意不加引号
  $ZIGCMD cc -target aarch64-linux-musl -static -Os -s -o "$OUT" cirno_pageout.c
fi

build_c() {
  echo "==> C helper -> $OUT_DIR/cirno_pageout"
  if [ -n "${CC:-}" ]; then
    $CC -O2 -static -s -o "$OUT_DIR/cirno_pageout" cirno_pageout.c
  elif [ "$HAVE_ZIG" = "1" ]; then
    "$ZIG" cc -target aarch64-linux-musl -static -Os -s \
      -o "$OUT_DIR/cirno_pageout" cirno_pageout.c
  else
    echo "zig/clang not found, skip C helper" >&2
    return 1
  fi
  chmod 755 "$OUT_DIR/cirno_pageout"
}

build_cpp() {
  echo "==> C++ daemon -> $OUT_DIR/cirno_daemon"
  if [ "$HAVE_ZIG" != "1" ]; then
    echo "zig not found (C++ needs zig c++), skip daemon" >&2
    return 1
  fi
  "$ZIG" c++ -target aarch64-linux-musl -static -Os -s \
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
