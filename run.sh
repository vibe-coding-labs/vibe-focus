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
  swift build -c release --product VibeFocusHotkeys

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
swift build -c release --product VibeFocusHotkeys

echo "停止旧进程..."
# 哈希比对：构建产物与上次安装的构建产物一致时不动 bundle、不重启进程。
# 替换二进制 = 新 CDHash = 辅助功能等 TCC 授权失效（macOS 对本地签名 app 按
# CDHash 校验），无谓重装会白白逼用户重新授权。
# 注意比对基准是 sidecar 记录的「上次安装的构建产物哈希」，而非已装文件本身——
# 已装文件经 codesign 改写（嵌入签名），哈希必然不同于构建产物，直接比对永远
# 不相等（2026-09-06 实测踩坑）。
NEW_BIN="$SCRIPT_DIR/.build/release/$EXECUTABLE_NAME"
NEW_HASH=$(shasum -a 256 "$NEW_BIN" 2>/dev/null | awk '{print $1}')
LAST_HASH_FILE="$HOME/Library/Application Support/VibeFocus/last-install.sha256"
LAST_HASH=$(cat "$LAST_HASH_FILE" 2>/dev/null || echo "")
if [ -f "$INSTALL_PATH/Contents/MacOS/$EXECUTABLE_NAME" ] && [ -n "$NEW_HASH" ] && [ "$NEW_HASH" = "$LAST_HASH" ]; then
  echo "二进制无变化（hash ${NEW_HASH:0:12}…），跳过替换——保留 TCC 授权。"
  open "$INSTALL_PATH"
  echo ""
  echo -e "${GREEN}✅ 已是最新（未替换 bundle）${NC}"
  echo "安装路径: $INSTALL_PATH"
  exit 0
fi
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
# 必须等旧进程真正退出才能替换 bundle：SIGTERM 后 SwiftUI/AppKit 撕卸可能超过 1s，
# 若此刻 cp 就地覆盖运行中的可执行文件，旧进程随后缺页读到哈希不匹配的新内容，
# 内核直接 SIGKILL（CODESIGNING Invalid Page）——即「莫名其妙的崩溃退出」。
for i in {1..50}; do
  pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
  echo "  旧进程 5s 未退出，SIGKILL 兜底..."
  pkill -9 -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  sleep 0.5
fi

echo "创建 .app bundle..."
# rm 掉旧 bundle 再建：保证可执行文件落在全新 inode 上。即使残留竞态下旧进程尚存，
# 它的代码映射仍指向已 unlink 的旧 inode（内容完整），不会因磁盘内容被替换而被击杀。
rm -rf "$INSTALL_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$NEW_BIN" "$MACOS_DIR/$EXECUTABLE_NAME"
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
  <key>NSAppleEventsUsageDescription</key>
  <string>VibeFocus 需要 Automation 权限来设置 iTerm2 和 Terminal.app 的窗口标题</string>
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

# 记录本次安装的构建产物哈希（下次 run.sh 的无变化比对基准）
if [ -n "$NEW_HASH" ]; then
  mkdir -p "$(dirname "$HOME/Library/Application Support/VibeFocus/last-install.sha256")"
  echo "$NEW_HASH" > "$LAST_HASH_FILE"
fi

echo "启动应用..."
open "$INSTALL_PATH"

echo ""
echo -e "${GREEN}✅ 已安装并启动${NC}"
echo "安装路径: $INSTALL_PATH"
echo "版本: $VERSION"
echo ""
echo "请在设置中开启「开机启动」以注册登录项"
echo "应用日志: /tmp/vibefocus.log"
