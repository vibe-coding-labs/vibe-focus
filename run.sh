#!/bin/bash
set -euo pipefail

echo "=== VibeFocus 本地运行 ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE_PATH="$SCRIPT_DIR/.build/release/VibeFocusHotkeys"
STDOUT_LOG="/tmp/vibefocus-run.stdout"
STDERR_LOG="/tmp/vibefocus-run.stderr"

echo "构建 release 二进制..."
swift build -c release

echo "停止旧进程..."
pkill -x "VibeFocusHotkeys" >/dev/null 2>&1 || true
sleep 1

echo "后台启动本地二进制..."
nohup "$EXECUTABLE_PATH" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
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
