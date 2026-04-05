#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

APP_NAME="VibeFocus"
BUNDLE_ID="com.vibefocus.app"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

echo -e "${YELLOW}🧹 VibeFocus 完全卸载脚本${NC}"
echo "=========================================="

# Kill all VibeFocus processes
echo -e "${YELLOW}1. 终止所有 VibeFocus 进程...${NC}"
pkill -9 -f "VibeFocus" 2>/dev/null || true
pkill -9 -f "VibeFocusHotkeys" 2>/dev/null || true
sleep 1
echo -e "${GREEN}   ✓ 进程已终止${NC}"

# Remove app bundles
echo -e "${YELLOW}2. 删除应用文件...${NC}"
rm -rf "/Applications/${APP_NAME}.app"
rm -rf "$HOME/Applications/${APP_NAME}.app"
rm -rf "/Users/Shared/${APP_NAME}.app"
echo -e "${GREEN}   ✓ 应用文件已删除${NC}"

# Remove from TCC database
echo -e "${YELLOW}3. 清理辅助功能权限...${NC}"
if [ -f "$TCC_DB" ]; then
    # Use exact matches to avoid accidentally removing other apps
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client = '${APP_NAME}.app';" 2>/dev/null || true
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client = 'com.vibefocus.app';" 2>/dev/null || true
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client = 'VibeFocusHotkeys';" 2>/dev/null || true
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client LIKE 'VibeFocus%';" 2>/dev/null || true
    echo -e "${GREEN}   ✓ TCC 数据库已清理${NC}"
else
    echo -e "${YELLOW}   ⚠ TCC 数据库未找到${NC}"
fi

# Unregister from LaunchServices
echo -e "${YELLOW}4. 清理 LaunchServices 记录...${NC}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/Applications/${APP_NAME}.app" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
echo -e "${GREEN}   ✓ LaunchServices 已清理${NC}"

# Clean UserDefaults
echo -e "${YELLOW}5. 清理用户配置...${NC}"
defaults delete com.vibefocus 2>/dev/null || true
defaults delete com.vibefocus.app 2>/dev/null || true
defaults delete VibeFocusHotkeys 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/com.vibefocus*"
rm -rf "$HOME/Library/Preferences/VibeFocusHotkeys*"
echo -e "${GREEN}   ✓ 用户配置已清理${NC}"

# Clean logs and caches
echo -e "${YELLOW}6. 清理日志和缓存...${NC}"
rm -rf "$HOME/Library/Logs/${APP_NAME}"
rm -rf "$HOME/Library/Caches/${APP_NAME}"
rm -rf "$HOME/Library/Caches/com.vibefocus*"
rm -rf "$HOME/Library/Caches/VibeFocusHotkeys"
echo -e "${GREEN}   ✓ 日志和缓存已清理${NC}"

# Final message
echo ""
echo -e "${GREEN}✅ VibeFocus 已完全卸载！${NC}"
echo ""
echo "注意：如果需要完全重置权限，建议重启系统"
echo "=========================================="
