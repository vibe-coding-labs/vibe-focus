#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🧹 VibeFocus 清理脚本${NC}"
echo "=========================================="

cd "$(dirname "$0")/.."
PROJECT_NAME=$(basename "$(pwd)")

echo -e "${YELLOW}1. 终止运行中的进程...${NC}"
pkill -f "VibeFocus" 2>/dev/null || true
sleep 1
echo -e "${GREEN}   ✓ 进程已终止${NC}"

echo -e "${YELLOW}2. 清理 Swift 构建产物...${NC}"
swift package clean 2>/dev/null || true
rm -rf .build/debug/*
rm -rf .build/release/*
echo -e "${GREEN}   ✓ 构建产物已清理${NC}"

echo -e "${YELLOW}3. 清理 SPM 缓存...${NC}"
# Only clean VibeFocus specific cache if identifiable, otherwise skip
# The SPM cache is shared across projects, we should not delete everything
rm -rf ~/Library/Caches/org.swift.swift-package-manager/repositories/VibeFocus* 2>/dev/null || true
echo -e "${GREEN}   ✓ SPM 缓存已清理${NC}"

echo -e "${YELLOW}4. 清理 DerivedData...${NC}"
rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}-*
echo -e "${GREEN}   ✓ DerivedData 已清理${NC}"

echo ""
echo -e "${GREEN}✅ 清理完成！${NC}"
echo "可以重新运行: ./scripts/dev-build.sh"
echo "=========================================="
