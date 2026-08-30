#!/usr/bin/env python3
"""P-INST 埋点收敛脚本（Phase 7）。

把「let xStart = Date() + defer { ... }」且 xStart 无块外引用的标准埋点块
包进 #if PERF_INSTRUMENT / #endif。变量外泄（耗时字段进日志字典）的块自动跳过。

Usage: python3 scripts/condense-perf-instrumentation.py <file.swift> [...]
"""
import re
import sys
from pathlib import Path

START_RE = re.compile(r'^(\s*)let (\w+) = Date\(\)\s*$')
DEFER_RE = re.compile(r'^\s*defer \{\s*$')


def find_block_end(lines, open_idx, base_indent):
    """defer { 在 open_idx，返回其配对 } 的行号（缩进按花括号计数）。"""
    depth = 0
    for i in range(open_idx, len(lines)):
        depth += lines[i].count('{') - lines[i].count('}')
        if depth == 0 and i > open_idx:
            return i
    return None


def condense_file(path: Path) -> tuple[int, int]:
    text = path.read_text()
    lines = text.split('\n')
    wrapped, skipped = 0, 0
    # 从后往前处理，避免行号位移
    i = len(lines) - 1
    starts = []
    for idx, line in enumerate(lines):
        m = START_RE.match(line)
        if m and idx + 1 < len(lines) and DEFER_RE.match(lines[idx + 1]):
            starts.append((idx, m.group(1), m.group(2)))

    for idx, indent, var in reversed(starts):
        if idx > 0 and '#if PERF_INSTRUMENT' in lines[idx - 1]:
            continue  # 已包裹（幂等保护）
        end = find_block_end(lines, idx + 1, indent)
        if end is None:
            continue
        block = '\n'.join(lines[idx:end + 1])
        # 变量外泄检测：块外（不含本块与上方 P-INST 注释行）出现该变量名则跳过
        outside = '\n'.join(lines[:idx] + lines[end + 1:])
        if re.search(r'\b' + re.escape(var) + r'\b', outside):
            skipped += 1
            continue
        lines[idx:idx] = [indent + '#if PERF_INSTRUMENT']
        end += 1
        lines[end + 1:end + 1] = [indent + '#endif']
        wrapped += 1

    path.write_text('\n'.join(lines))
    return wrapped, skipped


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    total_w = total_s = 0
    for arg in sys.argv[1:]:
        w, s = condense_file(Path(arg))
        total_w += w
        total_s += s
        if w or s:
            print(f"{arg}: wrapped={w} skipped={s}")
    print(f"TOTAL wrapped={total_w} skipped={total_s}")


if __name__ == '__main__':
    main()
