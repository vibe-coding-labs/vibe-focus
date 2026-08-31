#!/bin/bash
# 构建 VibeFocus release .app 产物到 dist/VibeFocus.app（不动运行中的 app、不写 ~/Applications）。
# 组装流程与 run.sh 一致（二进制 + 图标 + Resources + Info.plist + ad-hoc 签名）。
# 替换运行中的 app 请执行 scripts/deploy-release.sh。
set -euo pipefail

APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$SCRIPT_DIR/dist"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="$(awk -F'"' '/static let current/ {print $2}' "$SCRIPT_DIR/Sources/AppVersion.swift" 2>/dev/null || echo "0.0.0")"
ASSETS_DIR="$SCRIPT_DIR/assets"

cd "$SCRIPT_DIR"
echo "构建 release 二进制..."
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -f "$ASSETS_DIR/AppIcon.icns" ]; then
    cp "$ASSETS_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [ -f "$ASSETS_DIR/StatusBarIcon.png" ]; then
    cp "$ASSETS_DIR/StatusBarIcon.png" "$RESOURCES_DIR/StatusBarIcon.png"
fi
if [ -d "$SCRIPT_DIR/Resources" ]; then
    cp -R "$SCRIPT_DIR/Resources/" "$RESOURCES_DIR/" 2>/dev/null || true
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "产物: $APP_BUNDLE (版本 $VERSION)"
echo "验证新代码标记: $(strings "$MACOS_DIR/$EXECUTABLE_NAME" | grep -c 'CRASH LOOP detected') 处熔断标记"
echo ""
echo "替换运行中的 app：bash scripts/deploy-release.sh"
