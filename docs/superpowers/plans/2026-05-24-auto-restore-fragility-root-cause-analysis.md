# Research: auto-restore 反复失效的根因分析

**Question:** 为什么 auto-restore（提交提示词后自动回退到副屏幕）这个功能反复失效？如何从架构层面防止？
**Context:** 该功能自 4 月初实现以来，已产生 30+ 个修复计划、15+ 次独立修复，平均每 2-3 天就出一次新问题。用户每次需要手动排查、手动调试才能恢复。
**Deliverable:** 根因分析报告 + 架构脆弱点清单 + 系统性防护方案
**Time Box:** 单次调研
**Scope:** Small

---

## 1. 失效历史梳理

### 1.1 近期失效事件链（2026-05-24，本次会话）

| # | 失效症状 | 根因 | 修复 | 修复提交 |
|---|---------|------|------|---------|
| 1 | Hotkey ⌃Q 看起来不工作 | 实际上是假阳性——48 秒 stuck toggle，热键本身正常 | 无需修复 | — |
| 2 | hook toggle 不同步到 settings.json | UI toggle 修改了 UserDefaults 但未调用 `applyPreferences()` | 添加 applyPreferences() 调用 | d8d369c |
| 3 | autoRestoreOnPromptSubmit 重启后重置为 false | 三处默认值不一致：SettingsUI `true`，ClaudeHookPreferences `false`，PreferencesSync `false` | 统一三处默认值为 `true` | 7e2a1e2 |
| 4 | Stop 事件跳过窗口移动（no_binding_skip） | SessionWindowRegistry binding 在 app 重启后丢失，Stop handler 无 terminal context 降级 | 添加 terminal context fallback | fee0f47 |

**关键观察：4 个问题在同一天出现，每个都是不同的根因，但都导致同一个症状——auto-restore 不工作。**

### 1.2 历史修复频率

`docs/superpowers/plans/` 中 restore 相关计划统计：

| 时间段 | restore 相关计划数 | 典型问题 |
|--------|------------------|---------|
| 2026-04 初 | 6 | 初始实现 + 基础 bug |
| 2026-04 中 | 8 | hook restore chain、terminal matching |
| 2026-05 初 | 12 | toggle engine rewrite、coordinate system |
| 2026-05 中 | 10 | dead code cleanup、redundancy removal |
| 2026-05-24 | 4 | 默认值漂移、hook 同步、binding 丢失 |

**总计 40+ 个计划，涉及同一功能。**

---

## 2. 根因分析：为什么反复失效

### 2.1 架构脆弱点一：N 步串行流水线，零容错

auto-restore 的完整执行路径：

```
SessionStart
  → SessionWindowRegistry.bind()      ← 创建绑定
  → WindowStateStore.saveWindowState()  ← 持久化到 SQLite

Stop
  → handleWindowMoveTrigger()          ← 查找绑定
  → [binding found? → moveBindingToMainScreen()]     ← 有绑定
  → [no binding? → findWindowByTerminalContext()]     ← 无绑定（刚加的 fallback）
  → WindowManager.moveWindowToMainScreen()            ← 移动窗口
  → ToggleEngine.save()                              ← 保存 toggle record

UserPromptSubmit
  → resolveWindowIdentity()            ← 查找窗口
  → validateRestoreEligibility()       ← 验证可恢复
     ├── isWindowOnMainScreen?         ← 必须在主屏
     ├── ToggleEngine.load()           ← 必须有 toggle record
     └── record.isValid()              ← record 必须有效
  → executeRestore()                   ← 执行恢复
  → WindowManager.moveWindow()         ← 移动到副屏
```

**问题：这个流水线有 10+ 个串行步骤，每个步骤都可能静默失败。任何一个步骤失败 = 整个功能不工作。**

10 个步骤、每个 95% 可靠性 → 整体可靠性 = 0.95^10 ≈ **60%**。即每次尝试有 40% 的概率至少一个环节出问题。

### 2.2 架构脆弱点二：多源默认值，无统一 truth

`autoRestoreOnPromptSubmit` 的默认值存在于 3 个位置：

| 位置 | 文件 | 行号 | 作用 |
|------|------|------|------|
| @AppStorage | SettingsUI.swift:87 | UI 绑定默认 | `= true` |
| getter fallback | ClaudeHookPreferences.swift:127 | 运行时默认 | `?? true` |
| preferenceRegistry | PreferencesSync.swift:24 | 磁盘持久化默认 | `true` |

**为什么危险：**
- 三处默认值是三个独立的常量，编译器不会检测不一致
- 每次修改必须同步三处，遗漏一处就会引入 bug
- 新开发者（或 AI）修改时只会改一处，不知道其他两处的存在
- **本次失效就是这个原因**：之前 ClaudeHookPreferences 默认 `false`，PreferencesSync 默认 `false`，只有 SettingsUI 是 `true`

**当前状态：已修复为全部 `true`，但没有机制防止下次修改再次不一致。**

### 2.3 架构脆弱点三：状态分散在 4 个存储层，无原子性

```
UserDefaults (内存)
  ↕ restoreFromDisk / persistToDisk
~/.vibefocus/config.json (磁盘)
  ↕ applyPreferences
~/.claude/settings.json (外部文件)
  ↕ binding / load
~/.vibefocus/vibefocus.db (SQLite)
```

| 存储层 | 什么数据 | 同步方向 | 失败后果 |
|--------|---------|---------|---------|
| UserDefaults | 运行时偏好 | ← config.json (启动时) | 配置丢失 |
| config.json | 持久化偏好 | ← UserDefaults (运行时) | 重启后恢复旧值 |
| settings.json | Claude Code hooks | ← applyPreferences() | hooks 不注册 |
| vibefocus.db | session bindings, toggle records | 独立读写 | 绑定/toggle 丢失 |

**关键问题：这四层之间没有事务性保证。**
- 修改 UserDefaults 后，config.json 异步写入——如果 app 在中间 crash，状态不一致
- `applyPreferences()` 是手动调用的，容易遗漏（本次失效 #2）
- settings.json 是外部文件，格式由 Claude Code 控制，VibeFocus 只是"寄生"写入

### 2.4 架构脆弱点四：静默失败，无可见性

整个 auto-restore pipeline 的每一步失败都是**静默的**：

```swift
// 失败模式 1：直接 return，不抛异常
guard let binding = ... else {
    return (200, ClaudeHookResponse(ok: true, code: "no_binding_skip", ...))
}

// 失败模式 2：guard + return nil
guard WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID) else {
    return nil  // → "no_action_needed"
}

// 失败模式 3：可选值链断裂
guard let record = engine.load(windowID: identity.windowID) else {
    return nil  // → "Window not eligible for restore"
}
```

**所有失败都返回 HTTP 200 + `handled: false`**。hook-forwarder.sh 的 `curl` 命令执行 `>/dev/null 2>&1 || true`，静默丢弃所有响应。

结果：
- 用户看不到任何错误信息
- 日志里只有 WARN 级别的记录
- 没有任何聚合/告警机制来发现"auto-restore 成功率下降了"

### 2.5 架构脆弱点五：App 重启状态断裂

即使 SessionWindowRegistry 绑定已持久化到 SQLite（`windows` 表有 8 条历史记录），app 重启后仍然有问题：

1. **In-memory cache 为空**：`SessionWindowRegistry.init()` 从 SQLite 加载，但如果绑定已标记 `isCompleted=1`（上一次 Stop 事件已处理），则后续 UserPromptSubmit 无法使用该绑定
2. **Toggle record 可能在内存中丢失**：虽然 ToggleEngine 也用 SQLite，但 `loadAllWindowStates()` 的查询可能因时间窗口过滤掉旧记录
3. **SessionStart 不会重新触发**：Claude Code 的 SessionStart 只在会话开始时发送一次。如果 VibeFocus 在会话中间重启，收不到新的 SessionStart，无法重建 binding

当前 session `ac2352bf` 的数据库状态：
```
session_id: ac2352bf-...
app_name: iTerm2
window_id: 1467
is_completed: 1     ← Stop 已处理
```

Stop 已标记完成 → UserPromptSubmit 的 `binding(for:)` 返回该绑定但 `isCompleted=true` → `resolveWindowIdentity()` 检查 `verifyBinding()` → 如果 PID 仍有效则继续，但如果窗口已移回主屏...

**核心矛盾：pipeline 假设 "SessionStart → Stop → UserPromptSubmit" 严格按顺序发生，且中间没有 app 重启。但现实中 app 经常在会话中途重启（开发迭代、部署更新）。**

---

## 3. 系统性防护方案

### 方案 A：统一默认值源（Single Source of Truth for Defaults）

**问题**：默认值散落在 3 处，无编译期检查。
**方案**：在 `ClaudeHookPreferences` 中定义所有默认值为 `static let` 常量，其他位置引用该常量。

```swift
enum ClaudeHookPreferences {
    // 统一定义所有默认值
    static let defaultAutoRestoreOnPromptSubmit = true
    static let defaultAutoFocusOnSessionEnd = true
    // ...

    static var autoRestoreOnPromptSubmit: Bool {
        get { UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool
              ?? defaultAutoRestoreOnPromptSubmit }
    }
}
```

SettingsUI、PreferencesSync 全部引用 `ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit`。
**效果**：编译器保证所有默认值引用同一个常量，不会漂移。

### 方案 B：Pipeline Health Check（端到端自检）

**问题**：pipeline 每步可静默失败，无可见性。
**方案**：在 Settings UI 添加 "Test Auto-Restore Pipeline" 按钮，执行端到端检查：

```
Step 1: hooks 是否已注册？→ 检查 ~/.claude/settings.json
Step 2: autoRestoreOnPromptSubmit 是否 true？→ 读 UserDefaults
Step 3: SessionStart binding 是否存在？→ 读 vibefocus.db
Step 4: 窗口是否在主屏？→ WindowManager.isWindowOnMainScreen
Step 5: Toggle record 是否存在？→ ToggleEngine.load()

✅ All 5 checks passed → Pipeline healthy
❌ Check 3 failed → "No session binding. Try restarting your Claude Code session."
```

**效果**：用户一键诊断，不再需要手动查日志。

### 方案 C：Hook 事件成功率追踪

**问题**：无聚合数据，无法量化"功能是否正常工作"。
**方案**：在 HookEventHandler 中添加成功/失败计数器，持久化到 SQLite：

```swift
// 每次事件处理后记录
enum HookEventOutcome: String {
    case success, skipped_binding, skipped_disabled,
         skipped_already_main, skipped_non_terminal,
         failed_move, failed_restore
}

struct HookEventLog: Codable {
    let eventType: String      // "Stop", "UserPromptSubmit", "SessionStart"
    let sessionID: String
    let outcome: HookEventOutcome
    let timestamp: Date
}
```

在 Settings UI 展示最近 24 小时的事件成功率：
```
Auto-Restore Health: 7/10 (70%) last 24h
Recent failures:
  - 14:32 UserPromptSubmit → skipped_binding (session ac2352bf)
  - 14:28 Stop → skipped_binding (session ac2352bf)
```

**效果**：用户和开发者都能看到功能是否正常工作，失败原因一目了然。

### 方案 D：App 重启后主动恢复 Session State

**问题**：app 重启后 binding 虽在数据库中，但 pipeline 状态不连续。
**方案**：app 启动时，从 SQLite 加载所有 active（`isCompleted=0`）的 bindings，尝试重新定位窗口并补全 toggle record：

```swift
// AppDelegate.applicationDidFinishLaunching() 中
func recoverActiveSessions() {
    let activeBindings = SessionWindowRegistry.shared.loadActiveBindings()
    for binding in activeBindings {
        // 验证窗口是否仍然存在
        if WindowManager.shared.windowExists(windowID: binding.windowID) {
            // 如果窗口在主屏 → 补全 toggle record
            if WindowManager.shared.isWindowOnMainScreen(windowID: binding.windowID) {
                log("Recovered active session", fields: ["sessionID": binding.sessionID])
            }
        }
    }
}
```

**效果**：app 重启后自动恢复 pipeline 状态，不再依赖 "SessionStart → Stop → UserPromptSubmit" 严格顺序。

### 方案 E：最小防护——统一默认值（推荐立即实施）

方案 A 成本最低、收益最高。只需要：
1. 在 `ClaudeHookPreferences` 中将所有默认值提取为 `static let` 常量
2. SettingsUI 和 PreferencesSync 引用这些常量
3. 添加编译期断言确保一致性

**投入**：~30 分钟
**回报**：永久消除"默认值漂移"这类 bug

---

## 4. 结论

auto-restore 反复失效不是一个 bug，而是**架构脆弱性的系统性表现**。五个脆弱点互相放大：

1. **N 步串行流水线** → 每步都可能失败，总体可靠性 = 各步可靠性的乘积
2. **多源默认值** → 编译器不检查一致性，手动同步容易遗漏
3. **四层状态存储** → 无原子性保证，中间状态不一致
4. **静默失败** → 用户和开发者都无法感知失败
5. **重启状态断裂** → pipeline 假设连续运行，但开发迭代频繁重启

**优先行动建议：**
1. **立即**：实施方案 E（统一默认值源），消除默认值漂移风险
2. **短期**：实施方案 B（Pipeline Health Check），提供一键诊断能力
3. **中期**：实施方案 C（事件成功率追踪），提供运行时可见性
4. **长期**：方案 D（重启恢复）可作为后续迭代

---

## 5. 信息源

| # | 来源 | 内容 |
|---|------|------|
| 1 | `docs/superpowers/plans/` 目录 | 40+ 个 restore 相关修复计划，证明反复失效模式 |
| 2 | `Sources/Hook/HookEventHandler.swift:145-300` | UserPromptSubmit handler，展示串行流水线 |
| 3 | `Sources/Hook/HookEventHandler+WindowMove.swift:1-268` | Stop handler，展示无 binding 时的静默跳过 |
| 4 | `Sources/Hook/ClaudeHookPreferences.swift:14,127` | 默认值定义（已修复为 `true`） |
| 5 | `Sources/Support/PreferencesSync.swift:17-38` | preferenceRegistry 默认值（已修复） |
| 6 | `Sources/Settings/SettingsUI.swift:87` | @AppStorage 默认值 |
| 7 | `~/.vibefocus/vibefocus.db` windows 表 | 8 条历史绑定记录，session ac2352bf isCompleted=1 |
| 8 | `~/.vibefocus/config.json` | 当前 autoRestoreOnPromptSubmit=true |
| 9 | Git log fee0f47, 7e2a1e2, d8d369c, ccb0ae2 | 本次会话的 4 个修复提交 |
