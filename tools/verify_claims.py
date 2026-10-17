"""verify_claims.py - check that README numbers match reality.

Runs on CI after build (see .github/workflows/build.yml) and is also useful
locally. It guards the numbers this project actually sells itself on:

  * per-file and total C++ line counts quoted in cpp/README.md and README.md
  * the built binary sizes quoted in README.md

Line counts are compared EXACTLY (they are deterministic). Binary sizes are
compared with a small tolerance because the exact byte count depends on the
MSVC patch version the runner happens to use (x64 COFF can differ by a few
hundred bytes between compiler updates) - so a size claim is treated as a
range, not an equality. Failing a build because a service pack shifted the PE
header by 128 bytes would train people to ignore the check.

Exit code 0 = all claims consistent; 1 = at least one mismatch (CI fails).
"""
import os
import re
import sys

# CI runner 的 stdout 默认是 cp1252，直接 print 中文标签会 UnicodeEncodeError
# 崩掉（本地控制台是 UTF-8 所以本地跑不出来）。强制 UTF-8 输出，并对极端
# 情况下的不可编码字符降级，绝不让脚本因为打印而失败。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CPP = os.path.join(ROOT, "cpp")
README = os.path.join(ROOT, "README.md")
CPP_README = os.path.join(ROOT, "cpp", "README.md")

# The eight C++ sources the project counts (keep in sync with cpp/README.md).
SOURCES = [
    "main.cpp", "d3dplayer.cpp", "desktop.cpp", "guard.cpp",
    "media.cpp", "render.cpp", "wallpaper.h", "d3dplayer.h",
]

# A binary-size claim in README ("68.5 KB (70,144 B)") is checked with this
# slack in bytes - see module docstring for why it is not exact.
SIZE_SLACK = 4096


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def count_lines(path):
    # Count newline-terminated lines; the files end with a newline, so this
    # matches wc -l on a LF checkout. The repo stores text with LF
    # (.gitattributes), and a Windows working copy is also LF for these, so the
    # number is stable across platforms.
    with open(path, "rb") as f:
        return f.read().count(b"\n")


def fail(problems):
    print("verify_claims: FAIL")
    for p in problems:
        print("  - " + p)
    return 1


def main():
    problems = []
    if not os.path.isdir(CPP):
        print("verify_claims: cpp/ not found - run from the repo?")
        return 1

    cpp_md = read(CPP_README)
    root_md = read(README)

    # ---- line counts (exact) -------------------------------------------------
    counts = {}
    for name in SOURCES:
        path = os.path.join(CPP, name)
        if not os.path.isfile(path):
            problems.append("source missing: cpp/" + name)
            continue
        counts[name] = count_lines(path)
    if len(counts) != len(SOURCES):
        return fail(problems)

    total = sum(counts.values())

    # per-file: cpp/README.md markdown table like "| `main.cpp` | 538 | ... |"
    for name, n in counts.items():
        m = re.search(r"\|\s*`" + re.escape(name) + r"`\s*\|\s*(\d+)\s*\|", cpp_md)
        if not m:
            problems.append("cpp/README.md: no line-count cell for " + name)
            continue
        claimed = int(m.group(1))
        if claimed != n:
            problems.append("cpp/README.md: {} claims {} lines, actual {}".format(
                name, claimed, n))

    # total: cpp/README.md "| **合计** | **1872** | |"
    m = re.search(r"\|\s*\*\*合计\*\*\s*\|\s*\*\*(\d+)\*\*\s*\|", cpp_md)
    if m:
        if int(m.group(1)) != total:
            problems.append("cpp/README.md: 合计 claims {} lines, actual {}".format(
                m.group(1), total))
    else:
        problems.append("cpp/README.md: 合计 row not found")

    # total: README.md "**1872 行**" (there is one occurrence; also the
    # headline "1872 行 C++").
    m = re.search(r"\*{0,2}(\d+)\*{0,2}\s*行\*{0,2}", root_md)
    if m:
        if int(m.group(1)) != total:
            problems.append("README.md: headline claims {} lines, actual {}".format(
                m.group(1), total))
    else:
        problems.append("README.md: '<N> 行' line-count claim not found")

    # ---- binary sizes (within slack) ----------------------------------------
    def size_claim(label):
        # matches "| 主程序二进制 | **68.5 KB**（70,144 B） |" and the guard row
        m = re.search(re.escape(label) + r"\s*\|\s*\*\*[\d.]+ KB\*\*\s*（([\d,]+) B）", root_md)
        return int(m.group(1).replace(",", "")) if m else None

    for label, exe in (("主程序二进制", "DynamicWallpaper.exe"),
                       ("守护进程二进制", "DynamicWallpaperGuard.exe")):
        exe_path = os.path.join(CPP, exe)
        claimed = size_claim(label)
        if claimed is None:
            problems.append("README.md: size claim for " + label + " not parsed")
            continue
        if not os.path.isfile(exe_path):
            # CI builds before this step, so exe should exist; locally it may
            # not. Only flag if we could not find the claim target at all.
            print("  (skip size check: %s not built yet)" % exe)
            continue
        actual = os.path.getsize(exe_path)
        if abs(actual - claimed) > SIZE_SLACK:
            problems.append("README.md: {} claims {} B, built {} (delta {} > {} slack)".format(
                label, claimed, actual, abs(actual - claimed), SIZE_SLACK))
        else:
            print("  {}: claimed {} B, built {} B (within {} slack)".format(
                label, claimed, actual, SIZE_SLACK))

    # ---- result --------------------------------------------------------------
    print("total C++ lines: %d (across %d files)" % (total, len(SOURCES)))
    if problems:
        return fail(problems)
    print("verify_claims: OK - all README numbers consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())