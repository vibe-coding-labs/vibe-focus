# Bug 模式：部署导致辅助功能（TCC）权限失效

## Bug 表现
重新部署 VibeFocus 后，快捷键能触发但窗口无法移动。
系统设置中"辅助功能"权限显示已授权，但实际不生效。

## 发生频率
**高** — 每次 AI 或开发者用 `cp` 替换二进制文件时必触发。

## 根因分析

### macOS TCC 权限追踪机制

macOS 使用 **CDHash**（Code Directory Hash）追踪每个 app 的身份。
TCC 数据库记录的是 app bundle 的 CDHash，不是路径或 bundle ID。

```
TCC 数据库条目: /Applications/VibeFocus.app → CDHash=abc123...
```

当 `cp` 覆盖 `Contents/MacOS/VibeFocusHotkeys` 时：
- 新二进制的 CDHash 变了
- TCC 数据库中的 CDHash 与新二进制不匹配
- macOS 认为这是一个"不同的 app"，拒绝授权
- 但系统设置 UI 可能仍显示"已授权"（缓存未刷新）

### 错误的部署方式

```bash
# ❌ 这会破坏 TCC 权限
swift build -c release
cp .build/release/VibeFocusHotkeys /Applications/VibeFocus.app/Contents/MacOS/

# ❌ 这也会破坏（即使指定了路径）
cp .build/release/VibeFocusHotkeys ~/Applications/VibeFocus.app/Contents/MacOS/
```

### 正确的部署方式

```bash
# ✅ 使用 dev-build.sh — 它会：
# 1. 创建完整的 app bundle 结构
# 2. 写入 Info.plist（含 CFBundleIdentifier）
# 3. 用 codesign 签名（产生稳定的 CDHash）
# 4. 替换整个 app bundle（不只是二进制）
bash scripts/dev-build.sh
```

### dev-build.sh 做了什么

```bash
# 简化的关键步骤：
APP_PATH="$HOME/Applications/VibeFocus.app"
# 1. 编译
swift build -c release
# 2. 创建 app bundle
mkdir -p "$APP_PATH/Contents/MacOS"
cp ".build/release/VibeFocusHotkeys" "$APP_PATH/Contents/MacOS/"
# 3. 写入 Info.plist（必需！CFBundleIdentifier 是 TCC 识别 key）
cat > "$APP_PATH/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.vibefocus.app</string>
    ...
</dict>
</plist>
EOF
# 4. Code signing（关键！稳定 CDHash）
codesign --force --deep --sign - "$APP_PATH"
```

## 防范规则

1. **永远不要用 `cp` 替换 .app bundle 内的单个文件**
   - 必须替换整个 .app bundle 或用 `codesign` 重签

2. **部署必须使用 `bash scripts/dev-build.sh`**
   - 这是唯一的正确部署方式
   - 其他任何方式都可能破坏 TCC 权限

3. **部署后必须重启 app**
   - `open ~/Applications/VibeFocus.app` 或 `open /Applications/VibeFocus.app`
   - 不要 kill 后不管，app 必须处于运行状态

4. **权限破坏后的恢复步骤**
   ```bash
   # 方法 1: 重新用 dev-build.sh 部署（推荐）
   bash scripts/dev-build.sh

   # 方法 2: 重置 TCC 数据库中的条目（需要重启 app）
   tccutil reset Accessibility com.vibefocus.app
   ```

5. **AI 编辑代码后部署的检查清单**
   - [ ] 使用 `bash scripts/dev-build.sh`（不是 `cp`）
   - [ ] 确认构建成功（看到 "Build Succeeded" 或 exit code 0）
   - [ ] 用 `open` 命令启动 app
   - [ ] 不要关闭 app（必须保持运行状态）

## 快速排查

当"快捷键触发但窗口不动"时：

```bash
# 检查 app 是否在运行
pgrep -l VibeFocus

# 检查辅助功能权限（需要 AX.trusted）
# 在 Console.app 中搜索 "AXIsProcessTrusted" 或检查 VibeFocus 日志
grep "accessibility\|ax.*trusted\|permission" ~/Library/Logs/VibeFocus/vibefocus.log | tail -5

# 检查部署方式（如果用 cp 部署过，这里会是最近时间）
stat -f "%Sm" ~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys

# 重新正确部署
bash scripts/dev-build.sh
```
