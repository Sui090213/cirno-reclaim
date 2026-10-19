#!/usr/bin/env python3
"""打包脚本。

两种产物：

    python3 tools/pack.py            # 模块 zip（可刷入，根目录直接含 module.prop）
    python3 tools/pack.py --source   # 源码 zip（含 .github / dotfiles，用于上传 GitHub）

模块 zip 只放运行期需要的文件（外加 GPL 要求的 LICENSE 与 helper 源码），
源码 zip 保留 dotfiles 与 `.github/`。
"""

from __future__ import annotations

import argparse
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EXCLUDE_COMMON = {".git", "dist", "log", "state", "__pycache__", "tmp-test"}
EXCLUDE_SUFFIX = (".zip", ".log", ".pyc")
EXCLUDE_NAME = {"nohup.out"}

# 模块 zip 白名单：只放运行期需要的文件。
# 说明：文档（README/SECURITY/CHANGELOG/docs）不进模块，避免刷入包里塞一堆说明；
# 但 LICENSE 与两个原生组件的源码必须保留（GPL-3.0 对二进制分发的要求）。
MODULE_FILES = {
    "module.prop",
    "customize.sh",
    "post-fs-data.sh",
    "service.sh",
    "uninstall.sh",
    "action.sh",
    "config.conf",
    "LICENSE",
    "bin/common.sh",
    "bin/vm_tune.sh",
    "bin/reclaim.sh",
    "bin/app_relief.sh",
    "bin/daemon.sh",
    "bin/watchdog.sh",
    "bin/ctl.sh",
    "bin/cirno_pageout",
    "bin/cirno_daemon",
    "src/cirno_pageout.c",
    "src/cirno_daemon.cpp",
    "src/build.sh",
    "webroot/index.html",
    "webroot/style.css",
    "webroot/app.js",
}

EXEC_NAMES = {"bin/cirno_pageout", "bin/cirno_daemon"}


def module_version() -> str:
    try:
        with open(os.path.join(ROOT, "module.prop"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("version="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def is_exec(rel: str) -> bool:
    return rel.endswith(".sh") or rel in EXEC_NAMES


def iter_source_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = os.path.relpath(dirpath, ROOT)
        if rel_dir == ".":
            rel_dir = ""
        dirnames[:] = [d for d in sorted(dirnames) if d not in EXCLUDE_COMMON]
        for name in sorted(filenames):
            if name in EXCLUDE_NAME or name.endswith(EXCLUDE_SUFFIX):
                continue
            rel = os.path.join(rel_dir, name) if rel_dir else name
            yield rel.replace(os.sep, "/")


def iter_module_files():
    for rel in sorted(MODULE_FILES):
        if os.path.isfile(os.path.join(ROOT, rel)):
            yield rel
        else:
            print(f"  skip missing: {rel}")


def add(zf: zipfile.ZipFile, rel: str) -> None:
    zi = zipfile.ZipInfo(rel)
    zi.compress_type = zipfile.ZIP_DEFLATED
    zi.create_system = 3  # unix
    zi.external_attr = ((0o755 if is_exec(rel) else 0o644) & 0xFFFF) << 16

    with open(os.path.join(ROOT, rel), "rb") as fh:
        data = fh.read()
    zi.file_size = len(data)
    zf.writestr(zi, data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", action="store_true", help="打包源码仓库（含 .github / dotfiles）")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    if not os.path.isfile(os.path.join(ROOT, "module.prop")):
        print("error: module.prop not found at repo root", file=sys.stderr)
        return 1

    version = module_version()
    kind = "source" if args.source else "module"
    default_out = os.path.join(
        ROOT, "dist",
        f"Cirno-Reclaim-Hybrid-{version}{'-source' if args.source else ''}.zip",
    )
    out = args.out or default_out
    if not os.path.isabs(out):
        out = os.path.join(ROOT, out)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    files = list(iter_source_files() if args.source else iter_module_files())
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in files:
            add(zf, rel)

    size = os.path.getsize(out)
    print(f"[{kind}] packed {len(files)} files -> {out} ({size / 1024:.1f} KiB)")
    if args.source:
        for rel in files:
            print(f"  {rel}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
