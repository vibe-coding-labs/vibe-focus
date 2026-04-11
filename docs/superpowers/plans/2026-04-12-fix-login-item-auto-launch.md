# Fix Login Item Auto-Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复开机自启动功能 — 应用必须以 .app bundle 方式运行才能让 `SMAppService.mainApp` 正常工作，同时清理历史残留的裸二进制 login items。

**Architecture:** 当前 `run.sh` 直接运行裸二进制 → 改为复用 `install.sh` 的 .app bundle 构建逻辑。`LoginItemManager` 添加启动时清理旧 login items 的逻辑（删除指向 `.build/` 裸二进制的条目）。用户执行 `bash run.sh` 后，应用以 .app bundle 方式运行，`SMAppService.mainApp.register()` 可以正常注册。

**Tech Stack:** Swift 5.9, macOS 13+ Ventura, SMAppService API, bash scripting, codesign

**Risks:**
- 迁移到 .app bundle 后辅助功能权限可能需要重新授权 → 缓解：使用相同的 codesign identity
- 清理旧 login items 需要精确匹配路径，不能误删 → 缓解：只删除包含 `.build/` 路径的条目
- `run.sh` 改动影响开发工作流 → 缓解：保留 `--direct` 参数用于直接运行裸二进制

---

### Task 1: Rewrite run.sh to build and install .app bundle

**Depends on:** None
**Files:**
- Modify: `run.sh` (complete rewrite)

- [ ] **Step 1: Rewrite run.sh — 构建 .app bundle 安装到 ~/Applications 并启动**

```bash
#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34b'
NC='\033[0m'

APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
CERT_NAME="VibeFocus Local Code Signing"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="$HOME/Applications/$APP_NAME.app"
APP_DIR="$INSTALL_PATH"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
VERSION="$(awk -F'"' '/static let current/ {print $2}' "$SCRIPT_DIR/Sources/AppVersion.swift")"
VERSION="${VERSION:-0.0.0}"
ASSETS_DIR="$SCRIPT_DIR/assets"
APP_ICON_PATH="$ASSETS_DIR/AppIcon.icns"
STATUS_ICON_PATH="$ASSETS_DIR/StatusBarIcon.png"

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
  echo "构建 release 二进制..."
  swift build -c release

  echo "停止旧进程..."
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
  sleep 1

  echo "后台启动..."
  EXECUTABLE_PATH="$SCRIPT_DIR/.build/release/$EXECUTABLE_NAME"
  STDOUT_LOG="/tmp/vibefocus-run.stdout"
  STDERR_LOG="/tmp/vibefocus-run.stderr"
  nohup "$EXECUTABLE_PATH" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
  APP_PID=$!
  sleep 2
  echo "PID: $APP_PID"
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

if [ -f "$APP_ICON_PATH" ]; then
  cp "$APP_ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
fi

if [ -f "$STATUS_ICON_PATH" ]; then
  cp "$STATUS_ICON_PATH" "$RESOURCES_DIR/StatusBarIcon.png"
fi

# Copy resources from Resources directory
if [ -d "$SCRIPT_DIR/Resources" ]; then
  cp -R "$SCRIPT_DIR/Resources/" "$RESOURCES_DIR/" 2>/dev/null || true
fi

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

echo "签名 .app bundle..."
if security find-identity -v -p codesigning | grep -F "$CERT_NAME" >/dev/null 2>&1; then
  codesign --force --deep --sign "$CERT_NAME" "$APP_DIR" >/dev/null 2>&1
else
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
fi

echo "清理安全属性..."
xattr -rd com.apple.quarantine "$APP_DIR" 2>/dev/null || true

echo "启动应用..."
open "$APP_DIR"

echo ""
echo -e "${GREEN}✅ 已安装并启动${NC}"
echo "安装路径: $APP_DIR"
echo "版本: $VERSION"
echo ""
echo "请在设置中开启「开机启动」以注册登录项"
echo "应用日志: /tmp/vibefocus.log"
```

- [ ] **Step 2: 验证 run.sh 语法**
Run: `bash -n run.sh`
Expected:
  - Exit code: 0
  - No output

- [ ] **Step 3: 提交**
Run: `git add run.sh && git commit -m "fix(launch): rewrite run.sh to build .app bundle for SMAppService compatibility"`

---

### Task 2: Add stale login item cleanup to LoginItemManager

**Depends on:** Task 1
**Files:**
- Modify: `Sources/LoginItemManager.swift:14-16` (init method)

- [ ] **Step 1: 在 LoginItemManager.refresh() 中添加清理旧裸二进制 login items 的逻辑**

文件: `Sources/LoginItemManager.swift` — 替换 `refresh()` 方法（第 18-47 行）

```swift
    func refresh() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            statusTitle = "已启用"
            statusDetail = "登录后会自动启动。"
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            statusTitle = "未启用"
            statusDetail = "不会在登录后自动启动。"
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            statusTitle = "待确认"
            statusDetail = "需要在系统设置中确认。"
        case .notFound:
            isEnabled = false
            requiresApproval = false
            statusTitle = "不可用"
            statusDetail = "未能识别为登录项。请使用 ./run.sh 安装为 .app bundle。"
        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusTitle = "未知"
            statusDetail = "系统返回未知状态。"
        }

        // 清理指向 .build/ 目录的旧裸二进制 login items
        // 这些条目是之前直接运行裸二进制时通过 SMAppService 注册的，无法正常工作
        cleanupStaleLoginItems()
    }

    /// 清理指向 .build/ 目录的旧裸二进制 login items
    /// 只删除路径中包含 ".build/" 的 VibeFocus 相关条目
    private func cleanupStaleLoginItems() {
        do {
            let loginItems = try SMAppService.loginItems(for: .mainApp)
            for item in loginItems {
                let path = item.url?.path ?? ""
                // 只清理指向 .build/ 目录的裸二进制条目
                if path.contains(".build/") && (path.contains("VibeFocus") || path.contains("vibe-focus")) {
                    log(
                        "[LoginItemManager] cleaning up stale login item",
                        fields: ["path": path, "status": String(item.status.rawValue)]
                    )
                    try? item.unregister()
                }
            }
        } catch {
            log(
                "[LoginItemManager] failed to enumerate login items for cleanup",
                level: .warn,
                fields: ["error": error.localizedDescription]
            )
        }
    }
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/LoginItemManager.swift && git commit -m "fix(launch): cleanup stale bare-binary login items on refresh"`

---

### Task 3: End-to-end test — install, register login item, verify

**Depends on:** Task 1, Task 2
**Files:** None (verification only)

- [ ] **Step 1: 运行 run.sh 安装 .app bundle**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash run.sh`
Expected:
  - Exit code: 0
  - Output contains: "✅ 已安装并启动"
  - `~/Applications/VibeFocus.app` exists

- [ ] **Step 2: 验证 .app bundle 结构完整**
Run: `ls -la ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && ls -la ~/Applications/VibeFocus.app/Contents/Info.plist && ls -la ~/Applications/VibeFocus.app/Contents/Resources/AppIcon.icns`
Expected:
  - All three files exist
  - Info.plist contains `com.openai.vibe-focus`

- [ ] **Step 3: 验证应用启动并获取 bundle ID**
Run: `sleep 3 && grep "applicationDidFinishLaunching bundle=" /tmp/vibefocus.log | tail -1`
Expected:
  - Output contains `bundle=com.openai.vibe-focus`
  - Output contains `path=~/Applications/VibeFocus.app` (expanded)

- [ ] **Step 4: 在设置中开启登录项，验证 SMAppService 状态**
Run: `sleep 2 && grep "login item\|SMAppService\|LoginItem" /tmp/vibefocus.log | tail -5`
Expected:
  - No errors related to login item cleanup
  - Stale .build/ login items are cleaned up
