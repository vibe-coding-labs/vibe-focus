#!/bin/bash
# 真实覆盖率测量（Tests/Runner 通道，2026-09-02）
#
# 背景：CLT-only 环境无 XCTest/Swift Testing 运行时（playbook 2.10），
# VibeFocusTestRunner 以 @testable import 直测 Sources/ 真实实现。
# 本脚本用 -profile-generate + llvm-cov 产出逐文件真实覆盖率数字，
# 作为「分支穷尽覆盖」验收（2.13 用户裁决）的量化参考。
#
# Run: bash scripts/coverage_test_runner.sh
# 退出码：0 = Runner 全过并成功出报告；非 0 = Runner 失败或工具链缺失。

set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH=".build-coverage"
BIN="$SCRATCH/debug/VibeFocusTestRunner"
RAW="$(pwd)/$SCRATCH/runner.profraw"
PROFDATA="$(pwd)/$SCRATCH/coverage.profdata"

echo "==> 构建（profile-generate + coverage-mapping）"
swift build --product VibeFocusTestRunner --scratch-path "$SCRATCH" \
  -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping

echo "==> 执行 VibeFocusTestRunner（profraw → ${RAW}）"
LLVM_PROFILE_FILE="$RAW" "$BIN"

echo "==> merge profdata"
llvm_profdata_bin() {
  if command -v llvm-profdata >/dev/null 2>&1; then echo llvm-profdata
  elif xcrun -f llvm-profdata >/dev/null 2>&1; then xcrun -f llvm-profdata
  else echo ""; fi
}
llvm_cov_bin() {
  if command -v llvm-cov >/dev/null 2>&1; then echo llvm-cov
  elif xcrun -f llvm-cov >/dev/null 2>&1; then xcrun -f llvm-cov
  else echo ""; fi
}
PROFDATA_TOOL="$(llvm_profdata_bin)"
COV_TOOL="$(llvm_cov_bin)"
if [ -z "$PROFDATA_TOOL" ] || [ -z "$COV_TOOL" ]; then
  echo "ERROR: 找不到 llvm-profdata/llvm-cov（需完整 Xcode 或 brew install llvm）" >&2
  exit 2
fi
"$PROFDATA_TOOL" merge -sparse "$RAW" -o "$PROFDATA"

echo "==> llvm-cov 报告（Sources/ 逐文件）"
# 注意：传 Sources 路径过滤后 llvm-cov 的 Filename 列是相对该路径的（如 Settings/...，
# 不含 "Sources/" 前缀），任何按 /Sources\// 过滤的 awk 都会把逐文件行全部滤掉，
# 只剩 TOTAL——逐文件 100% 验收数字在门禁输出里不可见。路径过滤已限定范围，全量输出。
"$COV_TOOL" report "$BIN" -instr-profile="$PROFDATA" "$(pwd)/Sources"
