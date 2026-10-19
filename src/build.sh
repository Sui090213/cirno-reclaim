#!/bin/sh
# ============================================================================
#  Cirno Reclaim Hybrid - src/build.sh
#  交叉编译 arm64 的 pageout helper（可选组件，不编译也能用，只是前台只做 trim）
#
#  推荐：Zig（不需要装 NDK）
#      ./build.sh
#  或指定 NDK：
#      CC=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang \
#          ./build.sh
# ============================================================================
set -e

cd "$(dirname "$0")"
OUT=${1:-../bin/cirno_pageout}

if [ -n "${CC:-}" ]; then
  echo "==> using CC=$CC"
  $CC -O2 -static -s -o "$OUT" cirno_pageout.c
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

chmod 755 "$OUT"
echo "==> built: $OUT"
file "$OUT" 2>/dev/null || true
