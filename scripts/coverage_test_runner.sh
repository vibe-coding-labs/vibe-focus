#!/bin/bash
# 真实覆盖率测量（Tests/Runner 通道，2026-09-02）
#
# 背景：CLT-only 环境无 XCTest/Swift Testing 运行时（playbook 2.10），
# VibeFocusTestRunner 以 @testable import 直测 Sources/ 真实实现。
# 本脚本用 -profile-generate + llvm-cov 产出逐文件真实覆盖率数字，
# 作为「分支穷尽覆盖」验收（2.13 用户裁决）的量化参考。
#
# Run: bash scripts/coverage_test_runner.sh
# 环境变量：
#   WATCHDOG_MINUTES   Runner 看门狗分钟数（默认 25）；CI 无 yabai/AX 时长等待兜底。
#                     注：逐域模式（VIBEFOCUS_PER_DOMAIN_RUN=1）下它是「全局预算」，
#                     预算耗尽即停止后续域并照常出报告，不会丢已采集的 profraw。
#   VIBEFOCUS_RUNNER_SKIP_DOMAINS  整域跳过（见 Tests/Runner/main.swift runDomain）。
#   VIBEFOCUS_PER_DOMAIN_RUN=1     每个 Runner 域独立进程执行（CI 用）。CI 机器无
#                                  yabai/AX，个别域会唤醒单例后台定时器永久空转；单进程
#                                  全量跑会被一个挂起域拖死并丢掉 profraw。逐域化后：
#                                  - 每域独立 profraw，挂起只损失该域；
#                                  - 单域超时（VIBEFOCUS_PER_DOMAIN_TIMEOUT，默认 120s）
#                                    自动跳过，整轮可完成；
#                                  - 各进程 profraw 由 llvm-profdata 合并，覆盖率口径不变。
#   VIBEFOCUS_PER_DOMAIN_TIMEOUT   逐域单进程超时秒数（默认 120）。
#   VIBEFOCUS_PER_DOMAIN_TIMEOUT_OVERRIDES  单域超时覆盖，逗号分隔 name=seconds
#                                  （例 runAgentAccessLoopbackTests=300）。
# 退出码：0 = 成功产出覆盖率报告；2 = 工具链缺失/profraw 缺失。
#         断言失败不阻断报告（CI 覆盖通道无 yabai/AX，红域属环境性），
#         逐域失败/超时数量在汇总中单列；真机门禁仍以 `swift run VibeFocusTestRunner` 为准。

set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH=".build-coverage"
BIN="$SCRATCH/debug/VibeFocusTestRunner"
PROFDATA="$(pwd)/$SCRATCH/coverage.profdata"
LCov="$(pwd)/coverage.lcov"
PER_DOMAIN_RUN="${VIBEFOCUS_PER_DOMAIN_RUN:-0}"
PER_DOMAIN_TIMEOUT="${VIBEFOCUS_PER_DOMAIN_TIMEOUT:-120}"
# 个别域的单域超时覆盖（逗号分隔 name=seconds）。用于 CI 上合法但慢的域：
# 例 runAgentAccessLoopbackTests 内含多轮真实 curl 打环，CI 无 yabai/AX 时
# 单次请求可被拖到 30s 级，120s 不够但并非死循环。
PER_DOMAIN_TIMEOUT_OVERRIDES="${VIBEFOCUS_PER_DOMAIN_TIMEOUT_OVERRIDES:-}"

echo "==> 构建（profile-generate + coverage-mapping）"
swift build --product VibeFocusTestRunner --scratch-path "$SCRATCH" \
  -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping

# 单进程 + 超时看门狗。返回值 = 被测进程退出码；超时杀进程（先 TERM 再 KILL）。
# 注意：SIGKILL 的进程不会写 profraw，因此超时域只损失该域覆盖率。
run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$timeout_seconds"
    kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL "$pid" 2>/dev/null
  ) &
  local watchdog_pid=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  return "$status"
}

if [ "$PER_DOMAIN_RUN" = "1" ]; then
  echo "==> 逐域执行 VibeFocusTestRunner（单域超时 ${PER_DOMAIN_TIMEOUT}s）"
  RAW_DIR="$(pwd)/$SCRATCH/profraw"
  LOG_DIR="$(pwd)/$SCRATCH/domain-logs"
  rm -rf "$RAW_DIR" "$LOG_DIR"
  mkdir -p "$RAW_DIR" "$LOG_DIR"

  # 域清单从注册表提取（main.swift 的 runDomain("...") / runDomainUIGated("...")
  # 调用，保持注册顺序去重）。
  DOMAINS="$(grep -oE 'runDomain(UIGated)?\("[^"]+"' Tests/Runner/main.swift \
    | sed -E 's/^runDomain(UIGated)?\("//; s/"$//' \
    | awk '!seen[$0]++')"
  if [ -z "$DOMAINS" ]; then
    echo "ERROR: 未能从 Tests/Runner/main.swift 提取域清单" >&2
    exit 2
  fi
  SKIP_DOMAINS="${VIBEFOCUS_RUNNER_SKIP_DOMAINS:-}"
  ONLY_DOMAINS="${VIBEFOCUS_RUNNER_DOMAINS:-}"
  # 弹窗门只对 UI 域放开：CI 是临时 runner，不碰用户共享桌面；其余域保持
  # VIBEFOCUS_UI_E2E=0（runAllTests 的自动唤起保险丝照旧）。逐域进程相互隔离，
  # 因此这里可以按域精确给开关，不会让 UI 域在 280 个进程里重复展开。
  UI_DOMAINS="$(grep -oE 'runDomainUIGated\("[^"]+"' Tests/Runner/main.swift \
    | sed -E 's/^runDomainUIGated\("//; s/"$//' \
    | awk '!seen[$0]++')"

  START_SECONDS="$(date +%s)"
  BUDGET_SECONDS=$(( ${WATCHDOG_MINUTES:-80} * 60 ))
  RAN=0
  SKIPPED=0
  TIMED_OUT=0
  FAILED=0
  PASSED_CHECKS=0
  FAILED_CHECKS=0
  BUDGET_EXHAUSTED=0

  for domain in $DOMAINS; do
    case ",${SKIP_DOMAINS}," in
      *",${domain},"*)
        echo "  SKIP(env): ${domain}"
        SKIPPED=$((SKIPPED + 1))
        continue
        ;;
    esac
    # workflow_dispatch 的 domains 定向采集：非空时只跑清单内域。
    if [ -n "$ONLY_DOMAINS" ]; then
      case ",${ONLY_DOMAINS}," in
        *",${domain},"*) ;;
        *) continue ;;
      esac
    fi
    NOW="$(date +%s)"
    if [ $(( NOW - START_SECONDS )) -ge "$BUDGET_SECONDS" ]; then
      echo "WARN: 全局预算 ${WATCHDOG_MINUTES:-80} 分钟耗尽，停止后续域（已完成部分照常出报告）" >&2
      BUDGET_EXHAUSTED=1
      break
    fi

    DOMAIN_LOG="$LOG_DIR/${domain}.log"
    DOMAIN_UI_E2E=0
    if printf '%s\n' "$UI_DOMAINS" | grep -qx -- "$domain"; then
      DOMAIN_UI_E2E=1
    fi
    DOMAIN_TIMEOUT="$PER_DOMAIN_TIMEOUT"
    if [ -n "$PER_DOMAIN_TIMEOUT_OVERRIDES" ]; then
      OVERRIDE="$(printf '%s' "$PER_DOMAIN_TIMEOUT_OVERRIDES" | tr ',' '\n' \
        | awk -F= -v d="$domain" '$1 == d { print $2; exit }')"
      if [ -n "$OVERRIDE" ]; then
        DOMAIN_TIMEOUT="$OVERRIDE"
        echo "  (单域超时覆盖 ${domain} → ${DOMAIN_TIMEOUT}s)"
      fi
    fi
    echo "=== [domain] ${domain} ==="
    set +e
    LLVM_PROFILE_FILE="$RAW_DIR/${domain}-%p.profraw" \
      VIBEFOCUS_RUNNER_DOMAINS="$domain" \
      VIBEFOCUS_UI_E2E="$DOMAIN_UI_E2E" \
      run_with_timeout "$DOMAIN_TIMEOUT" "$BIN" > "$DOMAIN_LOG" 2>&1
    DOMAIN_STATUS=$?
    set -e
    # UI 域带 VIBEFOCUS_UI_E2E=1 会触发 Runner 的真机 E2E 互斥锁（atexit 释放）。
    # 超时被杀时 atexit 不执行，锁会把后续 UI 域全部挡成 exit 3（零 profraw）；
    # 本脚本严格串行，子进程已退出，残留锁必然属于刚才这一步，直接回收。
    if [ "$DOMAIN_UI_E2E" = "1" ] && [ -e /tmp/vibefocus-e2e.lock ]; then
      rm -rf /tmp/vibefocus-e2e.lock
    fi
    cat "$DOMAIN_LOG"

    RAN=$((RAN + 1))
    domain_passed="$(grep -c '^  PASS:' "$DOMAIN_LOG" 2>/dev/null || true)"
    domain_failed="$(grep -c '^  FAIL:' "$DOMAIN_LOG" 2>/dev/null || true)"
    PASSED_CHECKS=$((PASSED_CHECKS + ${domain_passed:-0}))
    FAILED_CHECKS=$((FAILED_CHECKS + ${domain_failed:-0}))
    if [ "$DOMAIN_STATUS" -eq 143 ] || [ "$DOMAIN_STATUS" -eq 137 ]; then
      echo "  TIMEOUT: ${domain}（超过 ${DOMAIN_TIMEOUT}s，已跳过；该域无 profraw）"
      TIMED_OUT=$((TIMED_OUT + 1))
    elif [ "$DOMAIN_STATUS" -ne 0 ]; then
      FAILED=$((FAILED + 1))
    fi
  done

  echo ""
  echo "==> 逐域汇总：执行 ${RAN} 域（断言 ${PASSED_CHECKS} 过 / ${FAILED_CHECKS} 败），"
  echo "    env 跳过 ${SKIPPED} 域，超时 ${TIMED_OUT} 域，断言失败 ${FAILED} 域$(
    [ "$BUDGET_EXHAUSTED" -eq 1 ] && echo '；全局预算耗尽，剩余域未执行'
  )"

  if ! compgen -G "$RAW_DIR/*.profraw" > /dev/null; then
    echo "ERROR: 未生成任何 profraw（所有域均被杀/崩溃）" >&2
    exit 2
  fi
  RAW_GLOB="$RAW_DIR/*.profraw"
else
  RAW="$(pwd)/$SCRATCH/runner.profraw"
  echo "==> 执行 VibeFocusTestRunner（profraw → ${RAW}）"
  # 覆盖率采集不因个别断言失败而丢报告：Runner 非 0 时照常 merge/report。
  # 看门狗：CI 机器无 yabai/AX，个别域可能进入长等待；超时 kill -9 并保留截止前输出。
  WATCHDOG_MINUTES="${WATCHDOG_MINUTES:-25}"
  set +e
  run_with_timeout $((10#$WATCHDOG_MINUTES * 60)) env LLVM_PROFILE_FILE="$RAW" "$BIN"
  RUNNER_STATUS=$?
  set -e
  if [ "$RUNNER_STATUS" -eq 137 ] || [ "$RUNNER_STATUS" -eq 143 ]; then
    echo "ERROR: Runner 被看门狗杀死（超过 ${WATCHDOG_MINUTES} 分钟）" >&2
  fi
  echo "==> Runner 退出码：${RUNNER_STATUS}（仍继续出覆盖率报告）"
  if [ ! -f "$RAW" ]; then
    echo "ERROR: 未生成 profraw（进程可能被 SIGKILL/崩溃）" >&2
    exit 2
  fi
  RAW_GLOB="$RAW"
fi

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
# shellcheck disable=SC2086
"$PROFDATA_TOOL" merge -sparse $RAW_GLOB -o "$PROFDATA"

echo "==> llvm-cov 报告（Sources/ 逐文件）"
# 注意：传 Sources 路径过滤后 llvm-cov 的 Filename 列是相对该路径的（如 Settings/...，
# 不含 "Sources/" 前缀），任何按 /Sources\// 过滤的 awk 都会把逐文件行全部滤掉，
# 只剩 TOTAL——逐文件 100% 验收数字在门禁输出里不可见。路径过滤已限定范围，全量输出。
"$COV_TOOL" report "$BIN" -instr-profile="$PROFDATA" "$(pwd)/Sources"

echo "==> 导出 LCOV（coverage.lcov：逐行命中数，供离线定位未覆盖行）"
"$COV_TOOL" export "$BIN" -instr-profile="$PROFDATA" -format=lcov > "$LCov"
echo "    $(wc -l < "$LCov" | tr -d ' ') 行 → ${LCov}"

if [ "$PER_DOMAIN_RUN" = "1" ]; then
  echo "==> 逐域执行完成（超时 ${TIMED_OUT} 域；断言失败 ${FAILED} 域；报告已生成）"
else
  echo "==> Runner 断言状态：$([ "$RUNNER_STATUS" -eq 0 ] && echo '全绿' || echo "失败(exit $RUNNER_STATUS)")"
fi
exit 0
