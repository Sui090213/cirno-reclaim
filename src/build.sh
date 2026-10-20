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
  HAVE_ZIG=0
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
  # -Oz + gc-sections：守护进程常驻，体积/映射越小越好（不影响逻辑）
  "$ZIG" c++ -target aarch64-linux-musl -static -Oz -s \
    -fno-exceptions -fno-rtti -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -Wall -Wextra -Wl,--gc-sections \
    -o "$OUT_DIR/cirno_daemon" cirno_daemon.cpp
  chmod 755 "$OUT_DIR/cirno_daemon"
}

rc=0
build_c || rc=1
build_cpp || rc=1

echo "==> done (rc=$rc)"
ls -l "$OUT_DIR"/cirno_pageout "$OUT_DIR"/cirno_daemon 2>/dev/null || true
exit $rc
