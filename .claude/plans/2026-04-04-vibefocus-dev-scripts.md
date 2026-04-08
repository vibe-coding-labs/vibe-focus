# VibeFocus 开发测试环境脚本实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建完整的开发测试环境自动化脚本，解决签名混乱和权限授权问题

**Architecture:** 使用 4 个独立的 shell 脚本组成工具链：uninstall.sh 完全清理环境，dev-build.sh 编译并签名，dev-run.sh 运行调试，dev-clean.sh 清理构建产物。脚本位于项目 scripts/ 目录，支持一键执行。

**Tech Stack:** Bash, Swift Package Manager, codesign, sqlite3, xattr, launchctl

---

## File Structure

```
scripts/
├── uninstall.sh      # 完全卸载脚本 - 清理所有痕迹
├── dev-build.sh      # 开发构建脚本 - 编译+签名+安装
├── dev-run.sh        # 开发运行脚本 - 调试运行
└── dev-clean.sh      # 清理脚本 - 清理构建产物
```

---

## Task 1: 创建 uninstall.sh 完全卸载脚本

**Files:**
- Create: `scripts/uninstall.sh`

**描述:** 彻底清理系统中的 VibeFocus 所有痕迹，包括应用文件、权限记录、签名缓存等

- [ ] **Step 1: 创建脚本框架和变量定义**

```bash
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
```

- [ ] **Step 2: 实现进程终止功能**

```bash
# Kill all VibeFocus processes
echo -e "${YELLOW}1. 终止所有 VibeFocus 进程...${NC}"
pkill -f "VibeFocus" 2>/dev/null || true
pkill -f "VibeFocusHotkeys" 2>/dev/null || true
sleep 1
echo -e "${GREEN}   ✓ 进程已终止${NC}"
```

- [ ] **Step 3: 实现应用文件删除**

```bash
# Remove app bundles
echo -e "${YELLOW}2. 删除应用文件...${NC}"
rm -rf "/Applications/${APP_NAME}.app"
rm -rf "$HOME/Applications/${APP_NAME}.app"
rm -rf "/Users/Shared/${APP_NAME}.app"
echo -e "${GREEN}   ✓ 应用文件已删除${NC}"
```

- [ ] **Step 4: 实现辅助功能权限清理**

```bash
# Remove from TCC database
echo -e "${YELLOW}3. 清理辅助功能权限...${NC}"
if [ -f "$TCC_DB" ]; then
    # Remove by bundle ID
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client LIKE '%${APP_NAME}%';" 2>/dev/null || true
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client LIKE '%vibefocus%';" 2>/dev/null || true
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE client LIKE '%VibeFocusHotkeys%';" 2>/dev/null || true
    echo -e "${GREEN}   ✓ TCC 数据库已清理${NC}"
else
    echo -e "${YELLOW}   ⚠ TCC 数据库未找到${NC}"
fi
```

- [ ] **Step 5: 实现 LaunchServices 清理**

```bash
# Unregister from LaunchServices
echo -e "${YELLOW}4. 清理 LaunchServices 记录...${NC}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/Applications/${APP_NAME}.app" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
echo -e "${GREEN}   ✓ LaunchServices 已清理${NC}"
```

- [ ] **Step 6: 实现 UserDefaults 清理**

```bash
# Clean UserDefaults
echo -e "${YELLOW}5. 清理用户配置...${NC}"
defaults delete com.vibefocus 2>/dev/null || true
defaults delete com.vibefocus.app 2>/dev/null || true
defaults delete VibeFocusHotkeys 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/com.vibefocus*"
rm -rf "$HOME/Library/Preferences/VibeFocusHotkeys*"
echo -e "${GREEN}   ✓ 用户配置已清理${NC}"
```

- [ ] **Step 7: 实现日志和缓存清理**

```bash
# Clean logs and caches
echo -e "${YELLOW}6. 清理日志和缓存...${NC}"
rm -rf "$HOME/Library/Logs/${APP_NAME}"
rm -rf "$HOME/Library/Caches/${APP_NAME}"
rm -rf "$HOME/Library/Caches/com.vibefocus*"
rm -rf "$HOME/Library/Caches/VibeFocusHotkeys"
echo -e "${GREEN}   ✓ 日志和缓存已清理${NC}"
```

- [ ] **Step 8: 添加完成提示和权限检查**

```bash
# Final message
echo ""
echo -e "${GREEN}✅ VibeFocus 已完全卸载！${NC}"
echo ""
echo "注意：如果需要完全重置权限，建议："
echo "1. 重启系统，或"
echo "2. 在终端执行: tccutil reset Accessibility"
echo ""
echo "=========================================="
```

- [ ] **Step 9: 设置执行权限**

Run: `chmod +x scripts/uninstall.sh`
Expected: 文件变为可执行

---

## Task 2: 创建 dev-build.sh 开发构建脚本

**Files:**
- Create: `scripts/dev-build.sh`

**描述:** 编译 Swift 项目，创建签名的 .app bundle，安装到 Applications

- [ ] **Step 1: 创建脚本框架**

```bash
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
```

- [ ] **Step 2: 实现前置清理检查**

```bash
# Check and kill existing processes
echo -e "${YELLOW}1. 检查现有进程...${NC}"
if pgrep -f "VibeFocus" > /dev/null; then
    echo "   发现运行中的 VibeFocus，正在终止..."
    pkill -f "VibeFocus" || true
    sleep 1
fi
echo -e "${GREEN}   ✓ 检查完成${NC}"
```

- [ ] **Step 3: 实现 Swift 编译**

```bash
# Build
echo -e "${YELLOW}2. 编译项目...${NC}"
cd "$(dirname "$0")/.."
swift build -c "$BUILD_CONFIG"
echo -e "${GREEN}   ✓ 编译完成${NC}"
```

- [ ] **Step 4: 实现 .app bundle 创建**

```bash
# Create app bundle
echo -e "${YELLOW}3. 创建应用包...${NC}"
APP_BUNDLE=".build/${BUILD_CONFIG}/${APP_NAME}.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/${BUILD_CONFIG}/VibeFocusHotkeys" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

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
```

- [ ] **Step 5: 实现代码签名**

```bash
# Sign the app
echo -e "${YELLOW}4. 签名应用...${NC}"
codesign --force --deep --sign "VibeFocus Local Code Signing" \
    --entitlements "$(dirname "$0")/../VibeFocus.entitlements" \
    "$APP_BUNDLE" 2>/dev/null || \
codesign --force --deep --sign - "$APP_BUNDLE"

echo -e "${GREEN}   ✓ 签名完成${NC}"
```

- [ ] **Step 6: 实现安装和属性清理**

```bash
# Install
echo -e "${YELLOW}5. 安装应用...${NC}"
rm -rf "${INSTALL_PATH}/${APP_NAME}.app"
cp -R "$APP_BUNDLE" "$INSTALL_PATH/"

# Remove quarantine
echo -e "${YELLOW}6. 清理安全属性...${NC}"
xattr -rd com.apple.quarantine "${INSTALL_PATH}/${APP_NAME}.app" 2>/dev/null || true

echo -e "${GREEN}   ✓ 安装完成${NC}"
```

- [ ] **Step 7: 实现签名验证**

```bash
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
```

- [ ] **Step 8: 设置执行权限**

Run: `chmod +x scripts/dev-build.sh`
Expected: 文件变为可执行

---

## Task 3: 创建 dev-run.sh 开发运行脚本

**Files:**
- Create: `scripts/dev-run.sh`

**描述:** 运行 VibeFocus 进行调试，支持直接运行 debug 版本或安装后的 .app

- [ ] **Step 1: 创建脚本框架和参数解析**

```bash
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default mode
MODE="direct"  # direct or app
LOG_LEVEL="debug"

echo -e "${BLUE}▶️ VibeFocus 开发运行脚本${NC}"
echo "=========================================="

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app)
            MODE="app"
            shift
            ;;
        --direct)
            MODE="direct"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--app|--direct]"
            exit 1
            ;;
    esac
done
```

- [ ] **Step 2: 实现进程检查和清理**

```bash
# Check existing processes
echo -e "${YELLOW}检查现有进程...${NC}"
if pgrep -f "VibeFocus" > /dev/null; then
    echo "发现运行中的 VibeFocus，正在终止..."
    pkill -9 -f "VibeFocus" || true
    sleep 1
    echo -e "${GREEN}✓ 已终止旧进程${NC}"
fi
```

- [ ] **Step 3: 实现日志清理**

```bash
# Clean old logs
echo -e "${YELLOW}清理旧日志...${NC}"
rm -f "$HOME/Library/Logs/VibeFocus/*.log" 2>/dev/null || true
echo -e "${GREEN}✓ 日志清理完成${NC}"
echo ""
```

- [ ] **Step 4: 实现直接运行模式**

```bash
if [ "$MODE" == "direct" ]; then
    echo -e "${BLUE}运行模式: 直接运行 debug 版本${NC}"
    echo "按 Ctrl+C 停止"
    echo "----------------------------------------"
    
    cd "$(dirname "$0")/.."
    
    # Build first if needed
    if [ ! -f ".build/debug/VibeFocusHotkeys" ]; then
        echo "正在编译..."
        swift build
    fi
    
    # Run with output
    exec ".build/debug/VibeFocusHotkeys"
fi
```

- [ ] **Step 5: 实现 App 运行模式**

```bash
if [ "$MODE" == "app" ]; then
    echo -e "${BLUE}运行模式: 运行安装的应用${NC}"
    
    APP_PATH="/Applications/VibeFocus.app"
    if [ ! -d "$APP_PATH" ]; then
        echo -e "${RED}错误: 未找到 $APP_PATH${NC}"
        echo "请先运行: ./scripts/dev-build.sh"
        exit 1
    fi
    
    echo "启动应用..."
    open "$APP_PATH"
    
    echo -e "${GREEN}✓ 应用已启动${NC}"
    echo ""
    echo "查看日志:"
    echo "  tail -f ~/Library/Logs/VibeFocus/*.log"
    echo ""
    echo "停止应用:"
    echo "  pkill -f VibeFocus"
fi
```

- [ ] **Step 6: 设置执行权限**

Run: `chmod +x scripts/dev-run.sh`
Expected: 文件变为可执行

---

## Task 4: 创建 dev-clean.sh 清理脚本

**Files:**
- Create: `scripts/dev-clean.sh`

**描述:** 清理 Swift 构建产物，解决编译问题

- [ ] **Step 1: 创建脚本**

```bash
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
rm -rf ~/Library/Caches/org.swift.swift-package-manager/*
echo -e "${GREEN}   ✓ SPM 缓存已清理${NC}"

echo -e "${YELLOW}4. 清理 DerivedData...${NC}"
rm -rf ~/Library/Developer/Xcode/DerivedData/${PROJECT_NAME}-*
echo -e "${GREEN}   ✓ DerivedData 已清理${NC}"

echo ""
echo -e "${GREEN}✅ 清理完成！${NC}"
echo "可以重新运行: ./scripts/dev-build.sh"
echo "=========================================="
```

- [ ] **Step 2: 设置执行权限**

Run: `chmod +x scripts/dev-clean.sh`
Expected: 文件变为可执行

---

## Task 5: 创建快速开发脚本 dev-all.sh

**Files:**
- Create: `scripts/dev-all.sh`

**描述:** 一键执行完整流程：卸载→清理→构建→运行

- [ ] **Step 1: 创建整合脚本**

```bash
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${CYAN}🚀 VibeFocus 完整开发流程${NC}"
echo "=========================================="
echo ""

# Step 1: Uninstall
echo -e "${BLUE}[1/4] 执行卸载...${NC}"
"${SCRIPT_DIR}/uninstall.sh" || true
echo ""

# Step 2: Clean
echo -e "${BLUE}[2/4] 执行清理...${NC}"
"${SCRIPT_DIR}/dev-clean.sh" || true
echo ""

# Step 3: Build
echo -e "${BLUE}[3/4] 执行构建...${NC}"
"${SCRIPT_DIR}/dev-build.sh"
echo ""

# Step 4: Run
echo -e "${BLUE}[4/4] 启动应用...${NC}"
echo -e "${YELLOW}首次运行请手动在系统设置中授予辅助功能权限${NC}"
echo ""
sleep 1
open "/Applications/VibeFocus.app"

echo ""
echo -e "${GREEN}✅ 流程完成！${NC}"
echo ""
echo "后续操作:"
echo "  查看日志: tail -f ~/Library/Logs/VibeFocus/*.log"
echo "  重新构建: ./scripts/dev-build.sh"
echo "  停止应用: pkill -f VibeFocus"
echo "=========================================="
```

- [ ] **Step 2: 设置执行权限**

Run: `chmod +x scripts/dev-all.sh`
Expected: 文件变为可执行

---

## 使用说明

### 单独使用脚本

```bash
# 完全卸载
./scripts/uninstall.sh

# 清理构建产物
./scripts/dev-clean.sh

# 构建并安装
./scripts/dev-build.sh

# 运行 debug 版本（快速测试）
./scripts/dev-run.sh --direct

# 运行安装的应用
./scripts/dev-run.sh --app
```

### 一键完整流程

```bash
# 卸载 → 清理 → 构建 → 运行
./scripts/dev-all.sh
```

### 日常开发流程

```bash
# 快速测试修改
./scripts/dev-run.sh --direct

# 完整测试（重新安装）
./scripts/dev-build.sh && ./scripts/dev-run.sh --app
```

---

## 注意事项

1. **首次运行**: 需要通过系统设置手动授予辅助功能权限
2. **签名问题**: 脚本使用 "VibeFocus Local Code Signing" 证书，如果不存在会使用临时签名
3. **TCC 清理**: 某些情况下可能需要重启系统才能完全重置权限
4. **sudo 权限**: uninstall.sh 中的 TCC 清理可能需要 sudo，脚本会提示
