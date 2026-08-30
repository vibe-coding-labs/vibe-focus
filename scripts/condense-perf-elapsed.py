#!/usr/bin/env python3
"""P-INST 埋点收敛脚本·第二模式（Phase 7）：elapsed 式埋点。

形态：
    let xStart = Date()          ← 包 #if
    ...业务语句...
    let durMs = elapsedMilliseconds(since: xStart)   ← 与下方 if 块一起包 #if
    if durMs >= 50 { log(...) }
或
    accMs &+= elapsedMilliseconds(since: xStart)     ← 单行包 #if

安全规则：计时变量（xStart/durMs）在包裹区之外出现任何引用则整组跳过。

Usage: python3 scripts/condense-perf-elapsed.py <file.swift> [...]
"""
import re
import sys
from pathlib import Path

DATE_RE = re.compile(r'^(\s*)let (\w+) = Date\(\)\s*$')
DEFER_RE = re.compile(r'^\s*defer \{\s*')
ELAPSED_DECL_RE = re.compile(r'^(\s*)let (\w+) = elapsedMilliseconds\(since: (\w+)\)\s*$')
ELAPSED_ACC_RE = re.compile(r'^(\s*)(\w+) [+&+]= elapsedMilliseconds\(since: (\w+)\)\s*$')


def brace_end(lines, open_idx):
    """从 open_idx 行起做花括号配对，返回闭合行号（允许起始行内闭合）。"""
    depth = 0
    for i in range(open_idx, len(lines)):
        depth += lines[i].count('{') - lines[i].count('}')
        if depth <= 0 and '{' in lines[i] or (depth == 0 and i > open_idx and '}' in lines[i]):
            return i
    return None


def condense_file(path: Path):
    lines = path.read_text().split('\n')
    # 收集所有 Date() 起点（非 defer 式）
    starts = []
    for idx, line in enumerate(lines):
        m = DATE_RE.match(line)
        if m and not (idx + 1 < len(lines) and DEFER_RE.match(lines[idx + 1])):
            starts.append((idx, m.group(1), m.group(2)))

    edits = []  # (insert_at, text)
    wrapped = skipped = 0
    for sidx, indent, var in starts:
        if sidx > 0 and '#if PERF_INSTRUMENT' in lines[sidx - 1]:
            continue  # 已包裹（幂等保护）
        occurrences = [i for i, l in enumerate(lines) if re.search(r'\b' + re.escape(var) + r'\b', l)]
        if len(occurrences) != 2:
            skipped += 1
            continue
        # 找 elapsed 引用行
        ref_idx = ref_kind = ref_info = None
        for i in occurrences:
            if i == sidx:
                continue
            if ELAPSED_DECL_RE.match(lines[i]):
                ref_idx, ref_kind, ref_info = i, 'decl', ELAPSED_DECL_RE.match(lines[i])
                break
            if ELAPSED_ACC_RE.match(lines[i]):
                ref_idx, ref_kind, ref_info = i, 'acc', ELAPSED_ACC_RE.match(lines[i])
                break
        if ref_idx is None:
            skipped += 1
            continue

        if ref_kind == 'acc':
            edits.append((sidx, indent + '#if PERF_INSTRUMENT'))
            edits.append((sidx + 1, indent + '#endif'))
            edits.append((ref_idx, indent + '#if PERF_INSTRUMENT'))
            edits.append((ref_idx + 1, indent + '#endif'))
            wrapped += 1
            continue

        # decl 形态：if 慢日志块
        dur_var = ref_info.group(2)
        dur_occurrences = [i for i, l in enumerate(lines) if re.search(r'\b' + re.escape(dur_var) + r'\b', l)]
        if set(dur_occurrences) - {ref_idx} == set():
            skipped += 1
            continue
        # if 块 = ref_idx 的下一行起？形态为 ref 行后紧跟 if（可能隔注释）
        j = ref_idx + 1
        while j < len(lines) and lines[j].strip() == '':
            j += 1
        if j >= len(lines) or not re.match(r'^\s*if .*' + re.escape(dur_var), lines[j]):
            skipped += 1
            continue
        end = brace_end(lines, j)
        if end is None:
            skipped += 1
            continue
        # dur_var 与 var 在包裹区外无引用（dur_occurrences 应全部落在 [ref_idx, end]）
        if any(o < ref_idx or o > end for o in dur_occurrences):
            skipped += 1
            continue
        # 段1：声明单行；段2：elapsed 声明行 + if 慢日志块
        edits.append((sidx, indent + '#if PERF_INSTRUMENT'))
        edits.append((sidx + 1, indent + '#endif'))
        edits.append((ref_idx, indent + '#if PERF_INSTRUMENT'))
        edits.append((end + 1, indent + '#endif'))
        wrapped += 1

    for at, text in sorted(edits, key=lambda x: (-x[0], x[1])):
        lines.insert(at, text)
    path.write_text('\n'.join(lines))
    return wrapped, skipped


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    tw = ts = 0
    for arg in sys.argv[1:]:
        w, s = condense_file(Path(arg))
        tw += w
        ts += s
        if w or s:
            print(f"{arg}: wrapped={w} skipped={s}")
    print(f"TOTAL wrapped={tw} skipped={ts}")


if __name__ == '__main__':
    main()
