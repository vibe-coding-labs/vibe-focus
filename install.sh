#!/bin/bash
# VibeFocus 开发机构建 + 安装 + 重启（dev loop 主入口）。
#
# Usage:
#   ./install.sh            # 构建 release → 原地更新 ~/Applications/VibeFocus.app → 重启
#
# 本脚本同时是「可 source 的函数库」（2026-09-08 B54，照 install-keepalive.sh 模式）：
# wait_for_process_exit / restart_app 供 Tests/Standalone/InstallRestartHardeningTests.swift
# 做真实行为测试；source 时仅定义函数，不构建、不触碰 ~/Applications（BASH_SOURCE 守卫）。
#
# ## 重启竞态加固（2026-09-08 实证）
# 旧实现 pkill -x（异步）后立即 open：旧进程尚未死透时 LaunchServices 对「正在消失的
# app」返回 -609（LSOpenURLsWithCompletionHandler failed），新包当场没被拉起。
# 现改为 pgrep 取 pid → pkill → wait_for_process_exit 轮询等待（0.2s 间隔、上限 5s、
# 超时不阻塞安装照常 open）→ open。
# keepalive 侧已由 B50 收敛为「仅 fatal 文件 size 差分」裁决：本脚本的 SIGTERM
# 优雅退出不会再被误判为崩溃进入 60s 冷却。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
CERT_NAME="VibeFocus Local Code Signing"
APP_DIR="$HOME/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="$(awk -F'\"' '/static let current/ {print $2}' "$SCRIPT_DIR/Sources/App/AppVersion.swift")"
VERSION="${VERSION:-0.0.0}"
ASSETS_DIR="$SCRIPT_DIR/assets"
APP_ICON_PATH="$ASSETS_DIR/AppIcon.icns"
STATUS_ICON_PATH="$ASSETS_DIR/StatusBarIcon.png"

# 等待给定 pid 全部退出（轮询 kill -0，0.2s 间隔）：全部退出=0；超时=1。
# 用于 pkill（异步）与 open 之间消除「旧进程死透前 LaunchServices -609」竞态。
# 纯轮询原语，不杀进程——超时后由调用方决定兜底动作。
wait_for_process_exit() {
    local timeout="$1"; shift
    local max_iters=$(( timeout * 5 + 1 ))
    local i pid alive
    for ((i = 0; i < max_iters; i++)); do
        alive=0
        for pid in "$@"; do
            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        if [[ "$alive" -eq 0 ]]; then return 0; fi
        sleep 0.2
    done
    return 1
}

restart_app() {
    echo "== Restarting app =="
    local pids
    pids="$(pgrep -x "$EXECUTABLE_NAME" 2>/dev/null || true)"
    pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086 —— 有意按词展开多个 pid
        if wait_for_process_exit 5 $pids; then
            echo "== Old instance exited =="
        else
            echo "== WARN: old instance still exiting after 5s; continuing (keepalive 兜底) =="
        fi
    fi
    open "$APP_DIR"
}

# source 时仅提供函数（测试模板库模式），main 流程不执行。
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

echo "== Building release binary =="
# 只构建可执行产品：swift build -c release 全量构建会把 Tests/Runner 的
# @testable 拖进来直接编译失败；而 --target 只编译模块不重链产品二进制
# （会装上旧二进制），必须用 --product。
swift build -c release --product VibeFocusHotkeys

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
  <string>com.vibefocus.app</string>
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

restart_app

echo
echo "Installed to: $APP_DIR"
echo "If this is the first launch, grant Accessibility access to:"
echo "  $APP_DIR"
