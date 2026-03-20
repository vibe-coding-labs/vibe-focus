#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
VERSION="$(awk -F'\"' '/static let current/ {print $2}' "$ROOT_DIR/Sources/AppVersion.swift")"
VERSION="${VERSION:-0.0.0}"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"

echo "== Building release binary =="
swift build -c release

echo "== Preparing app bundle =="
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"

# Copy icon resources
if [ -f "$ROOT_DIR/assets/AppIcon.icns" ]; then
  cp "$ROOT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -f "$ROOT_DIR/assets/StatusBarIcon.png" ]; then
  cp "$ROOT_DIR/assets/StatusBarIcon.png" "$RESOURCES_DIR/StatusBarIcon.png"
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
  CERT_NAME="VibeFocus Local Code Signing"
  if security find-identity -v -p codesigning | grep -F "$CERT_NAME" >/dev/null 2>&1; then
    echo "== Applying local code signature: $CERT_NAME =="
    codesign --force --deep --sign "$CERT_NAME" "$APP_DIR" >/dev/null
  else
    echo "WARNING: Local certificate '$CERT_NAME' not found, using ad-hoc signature"
    echo "Create it with: security create-certificate -c '$CERT_NAME' -p codeSigning"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
  fi
fi

ZIP_NAME="${APP_NAME}-${VERSION}-macos.zip"
mkdir -p "$OUTPUT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUTPUT_DIR/$ZIP_NAME"

echo "== Package ready: $OUTPUT_DIR/$ZIP_NAME =="
