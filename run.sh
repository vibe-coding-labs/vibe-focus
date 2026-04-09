#!/bin/bash
set -euo pipefail

echo "=== VibeFocus 本地运行 ==="
echo ""

# 解析参数
SKIP_LAUNCH=false
DEBUG_MODE=false
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-launch)
      SKIP_LAUNCH=true
      shift
      ;;
    -d|--debug)
      DEBUG_MODE=true
      shift
      ;;
    -q|--quick)
      QUICK_MODE=true
      shift
      ;;
    -h|--help)
      echo "用法: ./run.sh [选项]"
      echo ""
      echo "选项:"
      echo "  -s, --skip-launch    跳过启动窗口"
      echo "  -d, --debug          启用调试日志"
      echo "  -q, --quick          快速启动"
      echo "  -h, --help           显示帮助"
      exit 0
      ;;
    *)
      echo "未知选项: $1"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE_PATH="$SCRIPT_DIR/.build/release/VibeFocusHotkeys"
STDOUT_LOG="/tmp/vibefocus-run.stdout"
STDERR_LOG="/tmp/vibefocus-run.stderr"

echo "构建 release 二进制..."
swift build -c release

echo "停止旧进程..."
pkill -x "VibeFocusHotkeys" >/dev/null 2>&1 || true
sleep 1

# 构建启动参数
LAUNCH_ARGS=""
if [[ "$SKIP_LAUNCH" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --skip-launch-window"
fi
if [[ "$DEBUG_MODE" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --debug"
fi
if [[ "$QUICK_MODE" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --quick"
fi

echo "启动参数: $LAUNCH_ARGS"
echo "后台启动本地二进制..."
nohup "$EXECUTABLE_PATH" $LAUNCH_ARGS >"$STDOUT_LOG" 2>"$STDERR_LOG" &
APP_PID=$!
sleep 2

echo ""
echo "PID: $APP_PID"
echo "可执行文件: $EXECUTABLE_PATH"
echo "应用日志: /tmp/vibefocus.log"
echo "stdout: $STDOUT_LOG"
echo "stderr: $STDERR_LOG"

if grep -q "AX trusted (prompt=false)=true" /tmp/vibefocus.log 2>/dev/null; then
  echo "辅助功能权限: 已就绪"
else
  echo "辅助功能权限: 尚未确认，请检查 /tmp/vibefocus.log"
fi
