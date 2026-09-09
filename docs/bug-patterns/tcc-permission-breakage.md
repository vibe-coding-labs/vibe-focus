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

## 模式二：tccd 竞态误判（同证书重装后 ~1s 内拉起，2026-09-10 立项）

### 表现
- 重装（install replaced）后新进程 `ax=false`，热键/窗口管理全失效
- **钥匙串证书签名身份前后一致**（DR = `certificate leaf = H"805659a6…"` 不变）
- 授权本体从未被吊销：**重启进程即恢复**，不需要 tccutil、不需要用户重新勾选
- 误判绑定进程存活期：不重启可卡死一整夜（pid 28750 实证 22 分钟+，pid 44322 同）

### 实证时间线（exits.jsonl + /tmp/vibefocus-keepalive.log）
- 09-09 23:12 重装 → 新进程 ax=true（竞态未命中）
- 09-09 23:42 重装 → 新进程 ax=false（中招，卡到 00:05 人工重启）
- 09-10 00:05 人工重启 → ax=true；00:15 并行会话重装 → ax=false（再中招）
- 规律：旧进程退出后 ~1s 内拉起的新进程约半数被 tccd 误判；退让数秒后拉起则正常

### 防护（fix/ax-tccd-race-hardening + fix/ax-user-selfheal 批次，四层）
1. **App 自愈（自包含，不依赖 keepalive——真实用户机器没有那条链；启动 + 运行期双覆盖）**：
   启动路径 `AXSelfHeal.decide`（纯决策表）——启动未授权且上轮非自愈退出 → 派生 detached；
   运行期路径 `AXSelfHeal.decideRuntimeFlip`——WindowManager 翻转检测挂钩 true→false →
   5s 复核防抖仍假 → 同一看护自拉起（每进程一次，防循环标记独立于启动路径）。
   启动未授权且上轮非自愈退出 → 派生 detached
   看护进程（`relaunchScript`：等本进程死亡 → sleep 3 退让 → open 产物）后显式
   `recordExit(ax-selfheal-relaunch)` 优雅退出，看护进程拉起全新进程；上轮已自愈
   过仍假 = 真未授权，防循环，落回「打开系统设置」提示（AppDelegate ADFL 接线，
   看护派生失败则不退出、直接走人工提示）
2. **wrapper 退让**：install-keepalive.sh 生成器在 `open -W` 返回后 `sleep 3` 再裁决/重拉，
   让 tccd 完成旧进程注销
3. **装机后验证**：`--check-ax` 轻量探针（exit 0/3）+ run.sh / deploy-release.sh 装机尾段——
   装机脚本当场发现竞态并自动重启一次，安装会话立刻可见，不再等用户第二天报障
4. **取证增强**：`--diagnose` 增「安装副本盘点」段（几份活体/谁在跑/各自身份 adhoc 或证书），
   「是不是又装了两个版本」一条命令出答案

### 用户态签名分流（fix/ax-user-selfheal 批次）
run.sh 无证书时不再一刀切拒装（把无证书的真实用户堵死在门外）：ad-hoc 照装并按
首次安装/更新分别告知后续动作——ad-hoc 的代价已从「静默毒化到必须 tccutil」降为
「更新后一次重新勾选」（app 侧自愈 + 设置页直开兜底恢复）。证书仍是首选：授权跨
版本存续。真要面向大众分发（免勾选、免 Gatekeeper 放行），需 Apple Developer ID
签名 + 公证——产品化阶段决策项。

### 判别口诀
- 重启进程能好 → 竞态误判（本模式），自愈逻辑会自动处理
- 重启也不好 + 系统设置显示已勾选 → ad-hoc 毒化（模式一），必须 tccutil reset + 重新勾选
- `--diagnose` 副本盘点签名列显示 adhoc → 模式一，先查部署脚本是否绕过了「证书或拒绝」
