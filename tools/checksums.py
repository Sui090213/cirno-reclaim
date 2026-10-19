#!/usr/bin/env python3
"""为 dist/ 下的发布产物生成 SHA-256 校验文件。

用法：
    python3 tools/checksums.py            # 扫描 dist/，写 dist/CHECKSUMS.txt
    python3 tools/checksums.py --verify   # 按 CHECKSUMS.txt 校验
"""

from __future__ import annotations

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
OUT = os.path.join(DIST, "CHECKSUMS.txt")


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def artifacts() -> list[str]:
    if not os.path.isdir(DIST):
        return []
    return sorted(
        os.path.join(DIST, n) for n in os.listdir(DIST)
        if os.path.isfile(os.path.join(DIST, n))
        and n.endswith(".zip")
        and n != "CHECKSUMS.txt"
    )


def write_checksums() -> int:
    files = artifacts()
    if not files:
        print("no artifacts in dist/, run tools/pack.py first", file=sys.stderr)
        return 1

    lines = []
    for path in files:
        rel = os.path.relpath(path, DIST).replace(os.sep, "/")
        digest = sha256(path)
        size = os.path.getsize(path)
        lines.append(f"{digest}  {rel}")
        print(f"{rel}  {size / 1024:.1f} KiB  {digest}")

    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"\nwrote {OUT}")
    return 0


def verify() -> int:
    if not os.path.isfile(OUT):
        print("CHECKSUMS.txt not found", file=sys.stderr)
        return 1

    bad = 0
    with open(OUT, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            digest, name = line.split(None, 1)
            path = os.path.join(DIST, name.strip())
            if not os.path.isfile(path):
                print(f"MISSING {name}")
                bad = 1
                continue
            actual = sha256(path)
            if actual == digest:
                print(f"OK      {name}")
            else:
                print(f"FAILED  {name}\n  expected {digest}\n  actual   {actual}")
                bad = 1
    return bad


def main(argv: list[str]) -> int:
    if "--verify" in argv[1:]:
        return verify()
    return write_checksums()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
