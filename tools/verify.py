#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布前静态校验（无第三方依赖，不执行任何 shell 脚本）。

本机通常没有 bash / mksh / adb，所以这里只做「静态」检查，覆盖历史上真出过问题的地方：

  1. 文本文件编码 / 换行 / 末尾换行 / BOM；
  2. shell 语法体检（tools/lint_sh.py 的规则：块配对、bashism、mksh 方括号分号）；
  3. webroot/app.js 的 JS 语法（有 node 才查，没有就跳过）；
  4. 配置键在各处（config.conf / common.sh / ctl.sh 预设 / profiles/*）是否一致；
  5. 每个被脚本引用的运行期文件是否真的存在，且都在 tools/pack.py 的模块白名单里；
  6. 原生组件是不是 aarch64 静态 ELF、是否覆盖了源码里的 --include-art 等新参数；
  7. module.prop 版本号是否和文档/发布说明一致。

用法：
    python3 tools/verify.py

退出码：0 = 通过，1 = 有 failure。
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TEXT_EXT = {".sh", ".conf", ".prop", ".md", ".c", ".cpp", ".js", ".html", ".css", ".py", ".yml", ".txt"}
SKIP_DIRS = {".git", "dist", "log", "state", "__pycache__", "tmp-test"}

fails: list[str] = []
warns: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def warn(msg: str) -> None:
    warns.append(msg)


def walk_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in sorted(dirnames) if d not in SKIP_DIRS]
        for name in sorted(filenames):
            yield os.path.join(dirpath, name)


def rel(p: str) -> str:
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


# ---------------------------------------------------------------- 1. 编码 / 换行
def check_text_files(files):
    for p in files:
        if os.path.splitext(p)[1].lower() not in TEXT_EXT:
            continue
        data = open(p, "rb").read()
        if data.startswith(b"\xef\xbb\xbf"):
            fail(f"{rel(p)}: 有 UTF-8 BOM")
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            fail(f"{rel(p)}: 不是合法 UTF-8")
            continue
        if "\r\n" in text:
            fail(f"{rel(p)}: 含 CRLF（模块内统一 LF）")
        if text and not text.endswith("\n"):
            fail(f"{rel(p)}: 末尾缺换行")
        for i, line in enumerate(text.split("\n"), 1):
            if line != line.rstrip():
                fail(f"{rel(p)}:{i}: 行尾有多余空白")
                break


# ---------------------------------------------------------------- 2. shell lint
def check_shell():
    lint = os.path.join(ROOT, "tools", "lint_sh.py")
    if not os.path.isfile(lint):
        fail("tools/lint_sh.py 缺失")
        return
    r = subprocess.run([sys.executable, lint, ROOT], capture_output=True, text=True)
    if r.returncode != 0:
        fail("shell lint 未通过:\n" + (r.stdout or "") + (r.stderr or ""))
    else:
        print("  shell lint: OK (" + (r.stdout or "").strip().splitlines()[-1] + ")")


# ---------------------------------------------------------------- 3. JS 语法
def check_js():
    js = os.path.join(ROOT, "webroot", "app.js")
    node = shutil.which("node")
    if not node:
        warn("没找到 node，跳过 webroot/app.js 语法检查")
        return
    r = subprocess.run([node, "--check", js], capture_output=True, text=True)
    if r.returncode != 0:
        fail("app.js 语法错误:\n" + (r.stderr or ""))
    else:
        print("  app.js: OK")


# ---------------------------------------------------------------- 4. 配置键一致性
def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as fh:
        return fh.read()


def kv_keys(text):
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k = s.split("=", 1)[0].strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            out.append(k)
    return out


def block(text, start, end=None):
    i = text.index(start)
    j = text.index(end, i) if end else len(text)
    return text[i:j]


def check_config_keys():
    conf = set(kv_keys(read("config.conf")))
    common = read("bin/common.sh")
    defaults = set(re.findall(
        r': "\$\{([a-z_][a-z0-9_]*):=',
        block(common, "cfg_defaults()", "return 0\n}\n")))
    wd = set(kv_keys(block(common, "write_default_config()", "CR_EOF\n").split("<<'CR_EOF'", 1)[1]))
    assign = set(re.findall(r"\n\s{4}([a-z_][a-z0-9_]*)\) [a-z_][a-z0-9_]*=\$2 ;;",
                            block(common, "cfg_assign()", "\n}\n")))
    allowed = set()
    ab = block(common, "cfg_key_allowed()", "\n}\n")
    for tok in re.findall(r"[a-z_][a-z0-9_]*", ab):
        if tok not in {"return", "esac", "case", "in"}:
            allowed.add(tok)
    typed = set()
    for grp in re.findall(r"^\s{4}([a-z_][a-z0-9_]*(?:\|[a-z_][a-z0-9_]*)*)\)",
                          block(common, "cfg_value_type_ok()", "return 1\n}\n"), re.M):
        typed.update(grp.split("|"))
    presets = set(re.findall(r"^([a-z_][a-z0-9_]*)=",
                             block(read("bin/ctl.sh"), "preset_pairs()", "\n}\n"), re.M))

    groups = {
        "config.conf": conf,
        "write_default_config": wd,
        "cfg_assign": assign,
    }
    for name, keys in groups.items():
        for k in sorted(keys):
            if k not in assign:
                fail(f"{name}: 键 {k} 不在 cfg_assign")
            if k not in wd and name != "write_default_config":
                fail(f"{name}: 键 {k} 不在 write_default_config")
            if k not in conf and name != "config.conf":
                fail(f"{name}: 键 {k} 不在 config.conf")
            if k not in defaults:
                fail(f"{name}: 键 {k} 不在 cfg_defaults")
            if k not in allowed:
                fail(f"{name}: 键 {k} 不在 cfg_key_allowed")
    for k in sorted(presets):
        if k not in assign:
            fail(f"preset: 键 {k} 不在 cfg_assign")
        if k not in allowed:
            fail(f"preset: 键 {k} 不在 cfg_key_allowed")
    for name in sorted(os.listdir(os.path.join(ROOT, "profiles"))):
        if not name.endswith(".conf"):
            continue
        p = "profiles/" + name
        for k in kv_keys(read(p)):
            if k not in allowed:
                fail(f"{p}: 键 {k} 不在 cfg_key_allowed")
            if k not in assign:
                fail(f"{p}: 键 {k} 不在 cfg_assign")
    for k in ("reclaim_order", "device_profile", "kill_mode", "app_trim_level",
              "profile", "zram_algorithm", "daemon_engine"):
        if k not in typed:
            fail(f"cfg_value_type_ok 缺少枚举分支: {k}")
    print(f"  config keys: {len(conf)} 个，cfg_assign {len(assign)}，白名单 {len(allowed)}")


# ---------------------------------------------------------------- 5. 被引用的文件存在 + 在打包白名单里
PACK_WHITELIST = None


def pack_whitelist():
    global PACK_WHITELIST
    if PACK_WHITELIST is not None:
        return PACK_WHITELIST
    src = read("tools/pack.py")
    m = re.search(r"MODULE_FILES\s*=\s*\{(.*?)\}", src, re.S)
    PACK_WHITELIST = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
    return PACK_WHITELIST


def check_runtime_files():
    wl = pack_whitelist()
    required = [
        "module.prop", "customize.sh", "post-fs-data.sh", "service.sh", "uninstall.sh",
        "action.sh", "config.conf", "LICENSE", "THIRD-PARTY-NOTICES.md",
        "bin/common.sh", "bin/ctl.sh", "bin/reclaim.sh", "bin/app_relief.sh",
        "bin/vm_tune.sh", "bin/daemon.sh", "bin/watchdog.sh",
        "bin/cirno_daemon", "bin/cirno_pageout",
        "src/cirno_daemon.cpp", "src/cirno_pageout.c", "src/build.sh",
        "webroot/index.html", "webroot/style.css", "webroot/app.js",
        "profiles/hyperos.conf", "profiles/coloros.conf",
    ]
    for p in required:
        if not os.path.isfile(os.path.join(ROOT, p)):
            fail(f"缺少运行期文件: {p}")
        elif p not in wl:
            fail(f"{p} 不在 tools/pack.py 的模块白名单里，刷入包会缺文件")
    for p in sorted(wl):
        if not os.path.isfile(os.path.join(ROOT, p)):
            fail(f"pack.py 白名单里的 {p} 不存在")
    # common.sh 里写死的脚本路径要和实际名字一致
    common = read("bin/common.sh")
    for m in re.finditer(r'CR_BIN/([A-Za-z0-9_.]+)', common):
        name = m.group(1)
        if not name.endswith(".sh"):
            continue
        if not os.path.isfile(os.path.join(ROOT, "bin", name)):
            fail(f"common.sh 引用了不存在的 bin/{name}")
    print(f"  运行期文件: {len(required)} 项齐全，白名单 {len(wl)} 个")


# ---------------------------------------------------------------- 6. 原生组件
def check_binaries():
    for name in ("cirno_daemon", "cirno_pageout"):
        p = os.path.join(ROOT, "bin", name)
        data = open(p, "rb").read()
        if data[:4] != b"\x7fELF":
            fail(f"bin/{name}: 不是 ELF")
            continue
        if data[4] != 2:
            fail(f"bin/{name}: 不是 ELF64")
        machine = int.from_bytes(data[18:20], "little")
        if machine != 183:  # EM_AARCH64
            fail(f"bin/{name}: 不是 aarch64（e_machine={machine}）")
        if data[5] != 1:  # EI_DATA = ELFDATA2LSB
            fail(f"bin/{name}: 不是 little-endian（EI_DATA={data[5]}）")
        e_type = int.from_bytes(data[16:18], "little")
        if e_type not in (2, 3):  # ET_EXEC / ET_DYN
            fail(f"bin/{name}: 不是可执行 ELF（e_type={e_type}）")
        print(f"  bin/{name}: {len(data)} bytes, aarch64 ELF64, e_type={e_type}")
    src = read("src/cirno_pageout.c")
    for token in ("--include-art", "VmSwap", "read_vmswap_kb"):
        if token not in src:
            fail(f"src/cirno_pageout.c 缺少 {token}（本版要求按 VmSwap 计量）")
    dsrc = read("src/cirno_daemon.cpp")
    for token in ("read_meminfo", "read_psi_avg10", "pressure_tight", "heartbeat_sec",
                  "boot_delay", "write_stats", "sleep_until"):
        if token not in dsrc:
            fail(f"src/cirno_daemon.cpp 缺少 {token}")


# ---------------------------------------------------------------- 7. 版本号
def check_version():
    prop = read("module.prop")
    ver = re.search(r"^version=(.+)$", prop, re.M).group(1).strip()
    code = re.search(r"^versionCode=(\d+)$", prop, re.M).group(1).strip()
    print(f"  module.prop: {ver} / {code}")

    nums = re.match(r"v(\d+)\.(\d+)\.(\d+)$", ver)
    if not nums:
        fail(f"module.prop 版本格式异常: {ver}")
    else:
        major, minor, patch = (int(x) for x in nums.groups())
        want = major * 10000 + minor * 100 + patch
        if str(want) != code:
            fail(f"versionCode 应为 {want}（{ver}），实际 {code}")

    head = read("CHANGELOG.md")[:600]
    if f"## {ver}" not in head:
        fail(f"CHANGELOG.md 顶部没有 `## {ver}` 条目")

    notes = f"RELEASE_NOTES-{ver}.md"
    if not os.path.isfile(os.path.join(ROOT, notes)):
        fail(f"缺少 {notes}")


# ---------------------------------------------------------------- 8. 打包产物（若已构建）
def check_dist():
    prop = read("module.prop")
    ver = re.search(r"^version=(.+)$", prop, re.M).group(1).strip()
    mod_zip = os.path.join(ROOT, "dist", f"Cirno-Reclaim-Hybrid-{ver}.zip")
    if not os.path.isfile(mod_zip):
        warn(f"dist/ 里还没有 {os.path.basename(mod_zip)}，跳过包内检查")
        return
    with zipfile.ZipFile(mod_zip) as zf:
        names = set(zf.namelist())
    wl = pack_whitelist()
    missing = wl - names
    if missing:
        fail(f"模块 zip 缺少: {sorted(missing)}")
    if "module.prop" not in names:
        fail("模块 zip 根目录没有 module.prop")
    print(f"  dist 包: {os.path.basename(mod_zip)} 含 {len(names)} 个文件，白名单齐全")


def main() -> int:
    files = list(walk_files())
    print(f"检查 {len(files)} 个文件 ...")
    print("[1] 文本编码 / 换行")
    check_text_files(files)
    print("[2] shell lint")
    check_shell()
    print("[3] JS 语法")
    check_js()
    print("[4] 配置键一致性")
    check_config_keys()
    print("[5] 运行期文件")
    check_runtime_files()
    print("[6] 原生组件")
    check_binaries()
    print("[7] 版本号")
    check_version()
    print("[8] 打包产物")
    check_dist()
    print()
    for w in warns:
        print("WARN", w)
    for f in fails:
        print("FAIL", f)
    if fails:
        print(f"\n{len(fails)} 项未通过")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
