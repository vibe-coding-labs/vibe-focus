#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="VibeFocus"
BUILD_CONFIG="debug"
INSTALL_PATH="/Applications"

echo -e "${BLUE}🔨 VibeFocus 开发构建脚本${NC}"
echo "=========================================="

# Check and kill existing processes
echo -e "${YELLOW}1. 检查现有进程...${NC}"
if pgrep -f "VibeFocus" > /dev/null; then
    echo "   发现运行中的 VibeFocus，正在终止..."
    pkill -9 -f "VibeFocus" || true
    sleep 1
fi
echo -e "${GREEN}   ✓ 检查完成${NC}"

# Build
echo -e "${YELLOW}2. 编译项目...${NC}"
cd "$(dirname "$0")/.."
swift build -c "$BUILD_CONFIG"
echo -e "${GREEN}   ✓ 编译完成${NC}"

# Create app bundle
echo -e "${YELLOW}3. 创建应用包...${NC}"
APP_BUNDLE=".build/${BUILD_CONFIG}/${APP_NAME}.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/${BUILD_CONFIG}/VibeFocusHotkeys" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

# Copy resources
cp -R "Resources/" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>VibeFocus</string>
    <key>CFBundleIdentifier</key>
    <string>com.vibefocus.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VibeFocus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>VibeFocus 需要辅助功能权限来管理窗口</string>
</dict>
</plist>
PLIST

echo -e "${GREEN}   ✓ 应用包创建完成${NC}"

# Sign the app
echo -e "${YELLOW}4. 签名应用...${NC}"
codesign --force --deep --sign "VibeFocus Local Code Signing" \
    "$APP_BUNDLE" 2>/dev/null || \
codesign --force --deep --sign - "$APP_BUNDLE"

echo -e "${GREEN}   ✓ 签名完成${NC}"

# Install
echo -e "${YELLOW}5. 安装应用...${NC}"
rm -rf "${INSTALL_PATH}/${APP_NAME}.app"
cp -R "$APP_BUNDLE" "$INSTALL_PATH/"

# Remove quarantine
echo -e "${YELLOW}6. 清理安全属性...${NC}"
xattr -rd com.apple.quarantine "${INSTALL_PATH}/${APP_NAME}.app" 2>/dev/null || true

echo -e "${GREEN}   ✓ 安装完成${NC}"

# Verify signature
echo -e "${YELLOW}7. 验证签名...${NC}"
if codesign -v "${INSTALL_PATH}/${APP_NAME}.app" 2>&1; then
    echo -e "${GREEN}   ✓ 签名验证通过${NC}"
else
    echo -e "${RED}   ✗ 签名验证失败${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ 构建成功！${NC}"
echo "应用已安装到: ${INSTALL_PATH}/${APP_NAME}.app"
echo ""
echo "首次运行请手动打开应用以授予权限"
echo "=========================================="
