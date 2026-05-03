# VibeFocus 辅助权限（Accessibility）反复失效问题

## 问题现象

VibeFocus 的辅助功能权限（Accessibility Permission）在以下场景后会失效：
- 重新编译并部署 VibeFocus
- 重启 macOS
- 更新 VibeFocus 到新版本

表现为：系统偏好设置显示已授权，但实际 `AXIsProcessTrusted()` 返回 `false`，窗口管理功能完全不可用。

## 根因分析

### macOS TCC 权限追踪机制

macOS 的 TCC（Transparency, Consent, and Control）系统通过以下方式追踪 app 身份：

1. **有 `CFBundleIdentifier` 的 app**：TCC 用 bundle ID 跟踪（如 `com.vibefocus.app`）。只要 bundle ID 不变，权限就持久有效。
2. **没有 `CFBundleIdentifier` 的 adhoc 签名 app**：TCC 用代码签名的 CDHash 跟踪。每次重新编译产生新的 CDHash，TCC 认为是新 app，之前的授权失效。

### VibeFocus 的问题

VibeFocus 是 Swift Package Manager 项目，`swift build` 产生的二进制文件是 **adhoc 签名**（`flags=0x20002(adhoc,linker-signed)`），每次编译 CDHash 都不同。

之前的部署流程是：
```bash
swift build -c release
cp .build/release/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys
```

这个流程有两个致命问题：
1. **没有 `CFBundleIdentifier`**：Info.plist 中缺少此字段，TCC 无法用 bundle ID 追踪
2. **adhoc 签名**：每次 `swift build` 产生不同 CDHash，TCC 认为是新 app

## 解决方案

### 核心思路

给 VibeFocus 建立稳定的代码签名身份，使 TCC 能跨编译持久追踪。

### 步骤 1：创建本地代码签名证书

1. 打开 **钥匙串访问**（Keychain Access）
2. 菜单：钥匙串访问 → 证书助理 → 创建证书
3. 名称：`VibeFocus Local Code Signing`
4. 身份类型：自签名根证书
5. 证书类型：代码签名
6. 创建

### 步骤 2：创建带 CFBundleIdentifier 的 Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VibeFocus</string>
    <key>CFBundleIdentifier</key>
    <string>com.vibefocus.app</string>
    <key>CFBundleName</key>
    <string>VibeFocus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.14</string>
    <key>CFBundleVersion</key>
    <string>0.0.14</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>VibeFocus needs accessibility permissions to manage windows</string>
</dict>
</plist>
```

关键点：
- `CFBundleIdentifier` 必须设置且跨版本不变
- `CFBundleExecutable` 改为 `VibeFocus`（不是 SwiftPM 默认的 `VibeFocusHotkeys`）
- `NSAccessibilityUsageDescription` 让系统显示权限请求理由

### 步骤 3：构建 app bundle 并签名

```bash
#!/bin/bash
set -e

# 编译
swift build -c release

# 创建 app bundle
APP_BUNDLE=".build/release/VibeFocus.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制二进制（重命名为 VibeFocus）
cp ".build/release/VibeFocusHotkeys" "$APP_BUNDLE/Contents/MacOS/VibeFocus"

# 写入 Info.plist（见步骤 2）
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
  ... (Info.plist 内容)
EOF

# 用本地证书签名
codesign --force --deep --sign "VibeFocus Local Code Signing" "$APP_BUNDLE"

# 安装
rm -rf ~/Applications/VibeFocus.app
cp -R "$APP_BUNDLE" ~/Applications/

# 清除 quarantine
xattr -rd com.apple.quarantine ~/Applications/VibeFocus.app
```

### 步骤 4：验证签名

```bash
codesign -dvvv ~/Applications/VibeFocus.app 2>&1 | grep "Identifier\|Authority"
# 期望输出：
#   Identifier=com.vibefocus.app
#   Authority=VibeFocus Local Code Signing
```

### 步骤 5：首次授权

1. 打开 VibeFocus
2. 系统会弹出辅助权限请求
3. 授权后，以后每次重新部署（使用相同证书签名）权限不会丢失

## 现有脚本

项目已有完整的部署脚本：

- **`scripts/dev-build.sh`**：开发构建 + 自动签名 + 安装（推荐使用）
- **`scripts/package_release.sh`**：打包发布版本

## 禁止的部署方式

```bash
# ❌ 错误：直接 cp 二进制文件，跳过签名
swift build -c release
cp .build/release/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/

# ❌ 错误：用 adhoc 签名
codesign --force --sign - ~/Applications/VibeFocus.app
```

这两种方式都会导致 TCC 权限丢失。

## 排查指南

### 检查当前签名状态

```bash
codesign -dvvv ~/Applications/VibeFocus.app 2>&1 | grep -E "Identifier|Authority|Signature"
```

如果输出：
- `Identifier=com.vibefocus.app` + `Authority=VibeFocus Local Code Signing` → 正确
- `Identifier=VibeFocusHotkeys` + `Signature=adhoc` → 错误，需要重新签名

### 检查 AX 信任状态

在 VibeFocus 日志中查找：
```
AX trusted (prompt=false)=true   → 已授权
AX trusted (prompt=false)=false  → 未授权
```

### 重置 TCC 权限（如果需要重新授权）

打开 **系统设置** → **隐私与安全性** → **辅助功能**，找到 VibeFocus 并切换开关。

## 技术背景

### 为什么 CDHash 会变

Swift Package Manager 的 `swift build` 每次编译都会生成不同的二进制文件（即使源代码不变），因为：
- 编译时间戳嵌入二进制
- Swift 的 whole-module optimization 产生不可预测的输出
- adhoc 签名使用链接器的默认签名

### 为什么本地证书能解决

用 `VibeFocus Local Code Signing` 证书签名后：
- TCC 通过证书的公钥哈希追踪 app 身份
- 即使二进制内容变化，只要用同一证书签名，身份就不变
- `CFBundleIdentifier` 提供额外的身份锚点

### scripting-addition 的相关问题

yabai 的 scripting-addition 是注入到 Dock.app 的插件，每次 macOS 重启或 Dock 重启后需要重新加载。VibeFocus 在 `refreshAvailability()` 中检测 SA 状态并在需要时自动尝试加载。
