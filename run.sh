#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
CERT_NAME="VibeFocus Local Code Signing"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="$HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$INSTALL_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="$(awk -F'"' '/static let current/ {print $2}' "$SCRIPT_DIR/Sources/AppVersion.swift" 2>/dev/null || echo "0.0.0")"
ASSETS_DIR="$SCRIPT_DIR/assets"

# Parse arguments
MODE="bundle"
while [[ $# -gt 0 ]]; do
  case $1 in
    --direct)
      MODE="direct"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$MODE" == "direct" ]; then
  echo -e "${YELLOW}⚠️  直接模式：裸二进制运行，开机自启动将不可用${NC}"
  echo ""
  EXECUTABLE_PATH="$SCRIPT_DIR/.build/release/$EXECUTABLE_NAME"
  STDOUT_LOG="/tmp/vibefocus-run.stdout"
  STDERR_LOG="/tmp/vibefocus-run.stderr"

  echo "构建 release 二进制..."
  swift build -c release

  echo "停止旧进程..."
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  sleep 1

  echo "后台启动..."
  nohup "$EXECUTABLE_PATH" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
  APP_PID=$!
  sleep 2

  echo ""
  echo "PID: $APP_PID"
  echo "可执行文件: $EXECUTABLE_PATH"
  echo "应用日志: /tmp/vibefocus.log"
  exit 0
fi

echo -e "${BLUE}=== VibeFocus 安装运行 ===${NC}"
echo ""

echo "构建 release 二进制..."
swift build -c release

echo "停止旧进程..."
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
sleep 1

echo "创建 .app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRIPT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

# Copy icon resources
if [ -f "$ASSETS_DIR/AppIcon.icns" ]; then
  cp "$ASSETS_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -f "$ASSETS_DIR/StatusBarIcon.png" ]; then
  cp "$ASSETS_DIR/StatusBarIcon.png" "$RESOURCES_DIR/StatusBarIcon.png"
fi

# Copy additional resources
if [ -d "$SCRIPT_DIR/Resources" ]; then
  cp -R "$SCRIPT_DIR/Resources/" "$RESOURCES_DIR/" 2>/dev/null || true
fi

# Generate Info.plist with correct version
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.openai.vibe-focus</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Code sign the .app bundle
echo "签名 .app bundle..."
if security find-identity -v -p codesigning 2>/dev/null | grep -F "$CERT_NAME" >/dev/null 2>&1; then
  codesign --force --deep --sign "$CERT_NAME" "$INSTALL_PATH" >/dev/null 2>&1
  echo "  使用证书: $CERT_NAME"
else
  codesign --force --deep --sign - "$INSTALL_PATH" >/dev/null 2>&1
  echo "  使用 ad-hoc 签名"
fi

# Remove quarantine attribute
xattr -rd com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

echo "启动应用..."
open "$INSTALL_PATH"

echo ""
echo -e "${GREEN}✅ 已安装并启动${NC}"
echo "安装路径: $INSTALL_PATH"
echo "版本: $VERSION"
echo ""
echo "请在设置中开启「开机启动」以注册登录项"
echo "应用日志: /tmp/vibefocus.log"
