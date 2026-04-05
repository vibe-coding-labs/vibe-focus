#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default mode
MODE="direct"  # direct or app

echo -e "${BLUE}▶️ VibeFocus 开发运行脚本${NC}"
echo "=========================================="

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app)
            MODE="app"
            shift
            ;;
        --direct)
            MODE="direct"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--app|--direct]"
            exit 1
            ;;
    esac
done

# Check existing processes
echo -e "${YELLOW}检查现有进程...${NC}"
if pgrep -f "VibeFocus" > /dev/null; then
    echo "发现运行中的 VibeFocus，正在终止..."
    pkill -9 -f "VibeFocus" || true
    sleep 1
    echo -e "${GREEN}✓ 已终止旧进程${NC}"
fi

# Clean old logs
echo -e "${YELLOW}清理旧日志...${NC}"
rm -f "$HOME/Library/Logs/VibeFocus/*.log" 2>/dev/null || true
echo -e "${GREEN}✓ 日志清理完成${NC}"
echo ""

if [ "$MODE" == "direct" ]; then
    echo -e "${BLUE}运行模式: 直接运行 debug 版本${NC}"
    echo "按 Ctrl+C 停止"
    echo "----------------------------------------"

    cd "$(dirname "$0")/.."

    # Build first if needed
    if [ ! -f ".build/debug/VibeFocusHotkeys" ]; then
        echo "正在编译..."
        swift build
    fi

    # Run with output
    exec ".build/debug/VibeFocusHotkeys"
fi

if [ "$MODE" == "app" ]; then
    echo -e "${BLUE}运行模式: 运行安装的应用${NC}"

    APP_PATH="/Applications/VibeFocus.app"
    if [ ! -d "$APP_PATH" ]; then
        echo -e "${RED}错误: 未找到 $APP_PATH${NC}"
        echo "请先运行: ./scripts/dev-build.sh"
        exit 1
    fi

    echo "启动应用..."
    open "$APP_PATH"

    echo -e "${GREEN}✓ 应用已启动${NC}"
    echo ""
    echo "查看日志:"
    echo "  tail -f ~/Library/Logs/VibeFocus/*.log"
    echo ""
    echo "停止应用:"
    echo "  pkill -f VibeFocus"
fi
