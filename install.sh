#!/bin/bash
set -euo pipefail

APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
CERT_NAME="VibeFocus Local Code Signing"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="$(awk -F'\"' '/static let current/ {print $2}' "$(dirname "$0")/Sources/AppVersion.swift")"
VERSION="${VERSION:-0.0.0}"
ASSETS_DIR="$(dirname "$0")/assets"
APP_ICON_PATH="$ASSETS_DIR/AppIcon.icns"
STATUS_ICON_PATH="$ASSETS_DIR/StatusBarIcon.png"

echo "== Building release binary =="
swift build -c release

echo "== Preparing app bundle =="
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

if [ -f "$APP_ICON_PATH" ]; then
  cp "$APP_ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -f "$STATUS_ICON_PATH" ]; then
  cp "$STATUS_ICON_PATH" "$RESOURCES_DIR/StatusBarIcon.png"
fi

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>VibeFocusHotkeys</string>
  <key>CFBundleIdentifier</key>
  <string>com.openai.vibe-focus</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VibeFocus</string>
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

if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning | grep -F "$CERT_NAME" >/dev/null 2>&1; then
    echo "== Applying stable code signature: $CERT_NAME =="
    codesign --force --deep --sign "$CERT_NAME" "$APP_DIR" >/dev/null
  else
    echo "ERROR: Missing code signing identity: $CERT_NAME"
    echo "Refusing to use ad-hoc signing (would break Accessibility authorization)."
    echo ""
    echo "Create a local code signing certificate first:"
    echo "1) Open Keychain Access"
    echo "2) Menu: Keychain Access > Certificate Assistant > Create a Certificate"
    echo "3) Name: $CERT_NAME"
    echo "4) Identity Type: Self Signed Root"
    echo "5) Certificate Type: Code Signing"
    echo "6) Create, then re-run: ./install.sh"
    exit 1
  fi
fi

echo "== Restarting app =="
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
open "$APP_DIR"

echo
echo "Installed to: $APP_DIR"
echo "If this is the first launch, grant Accessibility access to:"
echo "  $APP_DIR"
