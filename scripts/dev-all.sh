#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${CYAN}🚀 VibeFocus 完整开发流程${NC}"
echo "=========================================="
echo ""

# Step 1: Uninstall
echo -e "${BLUE}[1/4] 执行卸载...${NC}"
"${SCRIPT_DIR}/uninstall.sh" || true
echo ""

# Step 2: Clean
echo -e "${BLUE}[2/4] 执行清理...${NC}"
"${SCRIPT_DIR}/dev-clean.sh" || true
echo ""

# Step 3: Build
echo -e "${BLUE}[3/4] 执行构建...${NC}"
"${SCRIPT_DIR}/dev-build.sh"
echo ""

# Step 4: Run
echo -e "${BLUE}[4/4] 启动应用...${NC}"
echo -e "${YELLOW}首次运行请手动在系统设置中授予辅助功能权限${NC}"
echo ""
sleep 1
open "/Applications/VibeFocus.app"

echo ""
echo -e "${GREEN}✅ 流程完成！${NC}"
echo ""
echo "后续操作:"
echo "  查看日志: tail -f ~/Library/Logs/VibeFocus/*.log"
echo "  重新构建: ./scripts/dev-build.sh"
echo "  停止应用: pkill -f VibeFocus"
echo "=========================================="
