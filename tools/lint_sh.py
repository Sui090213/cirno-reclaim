#!/usr/bin/env python3
"""POSIX sh 静态检查（无依赖，不执行脚本）。

本机没有 bash/dash，所以用这个脚本来兜底：

  1. 引号是否闭合（' " `）；
  2. if/fi、for|while|until|select/done、case/esac、{/} 是否配对；
  3. 常见 bashism（[[ ]]、function、$'...'、+=、<<<、数组赋值等）；
  4. 可疑写法（[ a == b ]、echo -e、${var:1}）。

实现方式：先把引号内、注释里的内容「打码」成空格（保留换行与偏移），
再打码后的文本上做词法分析与正则检查，避免把字符串里的内容当成语法。

用法：
    python3 tools/lint_sh.py [目录或文件 ...]

退出码：0 = 通过（可能有 warning），1 = 有 error。
"""

from __future__ import annotations

import os
import re
import sys

HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

BLOCK_OPEN = {"if": "fi", "for": "done", "while": "done", "until": "done",
              "select": "done", "case": "esac", "{": "}"}
BLOCK_CLOSE = {"fi": ("if",), "done": ("for", "while", "until", "select"),
               "esac": ("case",), "}": ("{",)}

BASHISMS = [
    (re.compile(r"\[\[(?!:)"), "error", "bashism: [[ ]]"),
    (re.compile(r"(?<!:)\]\]"), "error", "bashism: ]]"),
    (re.compile(r"^\s*function\s+[A-Za-z_]"), "error", "bashism: function 关键字"),
    (re.compile(r"<<<"), "error", "bashism: here-string <<<"),
    (re.compile(r"^\s*(declare|typeset)\b"), "error", "bashism: declare/typeset"),
    (re.compile(r"(?<![$\\])[A-Za-z_][A-Za-z0-9_]*\+="), "error", "bashism: += 追加赋值"),
    (re.compile(r"[A-Za-z_][A-Za-z0-9_]*=(?=\()"), "error", "bashism: 数组赋值"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:(?![=+?~-])"), "warn", "非 POSIX: ${var:offset}"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*//"), "warn", "非 POSIX: ${var//x/y}"),
    (re.compile(r"\becho\s+-[ne]+\b"), "warn", "建议用 printf 代替 echo -e"),
    (re.compile(r"\[\s[^\]]*\s==\s"), "warn", "在 [ ] 里应使用 ="),
    (re.compile(r"^\s*local\s+-\w"), "warn", "local -options 不是 POSIX"),
    # mksh 会把 case 模式方括号里的 ; 当命令分隔符，导致整份脚本语法错误
    (re.compile(r"\[[^\]\n]*;[^\]\n]*\]"), "error", "mksh: 方括号模式里不能出现 ;"),
    # mksh 把 ${v%%|*} 里的 | 当成模式的「或」，取出空串；必须写成 \|
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(?:%%|%|##|#)[^}\n]*(?<!\\)\|"), "error",
     "mksh: ${var%...} / ${var#...} 模式里的 | 要写成 \\|"),
]

DELIMS = " \t\n;|&("


def strip_heredocs(lines: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = HEREDOC_RE.search(line)
        if m and not line.lstrip().startswith("#"):
            marker = m.group(2)
            i += 1
            while i < len(lines):
                if lines[i].strip() == marker:
                    out.append(lines[i])
                    break
                out.append("")
                i += 1
        i += 1
    return out


def mask(text: str) -> str:
    """把引号内容、注释替换成空格（保留长度与换行）。"""
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        c = text[i]

        if c == "\\":
            out[i] = " "
            if i + 1 < n and text[i + 1] != "\n":
                out[i + 1] = " "
                i += 2
            else:
                i += 1
            continue

        if c in "'\"`":
            quote = c
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\" and quote == '"':
                    out[i] = " "
                    if i + 1 < n:
                        out[i + 1] = " "
                    i += 2
                    continue
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
            i += 1
            continue

        if c == "#" and (i == 0 or text[i - 1] in " \t\n;|&"):
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue

        i += 1

    return "".join(out)


def scan(text: str):
    """在打码后的文本上取关键字；跳过 $(...) / ${...} 展开体。"""
    words: list[tuple[str, int]] = []
    errors: list[str] = []
    i, n, line = 0, len(text), 1

    while i < n:
        c = text[i]

        if c == "\n":
            line += 1
            i += 1
            continue

        if c in " \t\r;|&()<>":
            i += 1
            continue

        # ${...}
        if c == "$" and i + 1 < n and text[i + 1] in "{(":
            open_c = text[i + 1]
            close_c = "}" if open_c == "{" else ")"
            depth = 0
            j = i + 1
            while j < n:
                if text[j] == open_c:
                    depth += 1
                elif text[j] == close_c:
                    depth -= 1
                    if depth == 0:
                        break
                elif text[j] == "\n":
                    line += 1
                j += 1
            i = j + 1
            continue

        if c == "\\":
            i += 2
            continue

        m = WORD_RE.match(text, i)
        if m:
            word = m.group(0)
            before = text[i - 1] if i > 0 else "\n"
            after = text[m.end()] if m.end() < n else "\n"
            if before in DELIMS and after in DELIMS and word in BLOCK_OPEN or \
               before in DELIMS and after in DELIMS and word in BLOCK_CLOSE:
                words.append((word, line))
            i = m.end()
            continue

        if c in "{}":
            words.append((c, line))
            i += 1
            continue

        i += 1

    return words, errors


def check_blocks(words, errors):
    stack: list[tuple[str, int]] = []
    for tok, line in words:
        if tok in BLOCK_OPEN:
            stack.append((tok, line))
        elif tok in BLOCK_CLOSE:
            if not stack:
                errors.append(f"line {line}: 多余的 '{tok}'")
                continue
            want = BLOCK_CLOSE[tok]
            if stack[-1][0] in want:
                stack.pop()
            else:
                errors.append(
                    f"line {line}: '{tok}' 与 line {stack[-1][1]} 的 '{stack[-1][0]}' 不匹配"
                )
                stack.pop()
    for tok, line in stack:
        errors.append(f"line {line}: '{tok}' 没有闭合")


def check_file(path: str) -> int:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"{path}: 读取失败: {exc}")
        return 1

    lines = text.split("\n")
    cleaned = "\n".join(strip_heredocs(lines))
    masked = mask(cleaned)

    words, errors = scan(masked)
    check_blocks(words, errors)

    warnings = []
    raw_lines = cleaned.split("\n")
    for idx, line in enumerate(masked.split("\n"), start=1):
        if not line.strip():
            continue
        for rx, level, msg in BASHISMS:
            if rx.search(line):
                (errors if level == "error" else warnings).append(f"line {idx}: {msg}")
        # $'...' 打码后看不到引号，单独在原文上按「前面是分隔符」判断
        if re.search(r"(?:^|[\s;|&(])\$'", raw_lines[idx - 1]):
            errors.append(f"line {idx}: bashism: $'...'")

    if text and not text.endswith("\n"):
        warnings.append("文件末尾没有换行")

    rel = os.path.relpath(path)
    for w in warnings:
        print(f"{rel}: warning: {w}")
    for e in errors:
        print(f"{rel}: error: {e}")
    return 1 if errors else 0


def collect(targets: list[str]) -> list[str]:
    files = []
    for t in targets:
        if os.path.isdir(t):
            for dirpath, dirnames, filenames in os.walk(t):
                dirnames[:] = [d for d in dirnames if d not in
                               (".git", "dist", "log", "state", "__pycache__")]
                for f in filenames:
                    if f.endswith(".sh"):
                        files.append(os.path.join(dirpath, f))
        elif t.endswith(".sh"):
            files.append(t)
    return sorted(set(files))


def main(argv: list[str]) -> int:
    targets = argv[1:] or ["."]
    files = collect(targets)
    if not files:
        print("no shell scripts found")
        return 0

    bad = 0
    for f in files:
        bad |= check_file(f)

    print(f"\nchecked {len(files)} scripts, {'FAILED' if bad else 'OK'}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
