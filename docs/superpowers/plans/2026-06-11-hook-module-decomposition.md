# Refactor: Hook Module Decomposition — 拆分巨型文件提升可维护性

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 Hook 模块中 4 个超过 300 行的巨型文件拆分为职责单一的小文件，使每个文件 < 300 行、每个函数 < 80 行，同时保持所有 992 个测试通过。

**Architecture:** 纯迁移型重构 — 复制代码到新文件 → 调用方指向新文件 → 删除旧文件中的已迁移代码。数据流不变：Claude Hook → HTTP Server → EventHandler → Registry → WindowManager。只改文件组织，不改运行时行为。

**Tech Stack:** Swift 5.9+, Swift Package Manager, swift-testing (992 tests)

**Scope:** Large (影响 Hook 模块 8 个文件中的 5 个 + 新增 1 个常量文件)

**Risk:** Medium — 修改共享模块，但纯结构变更，不变行为

**Before:** Hook 模块 5 个巨型文件 (ClaudeHookPreferences 686行, HookEventHandler 536行, HookEventHandler+WindowMove 441行, SessionWindowRegistry 413行, ClaudeHookModels 含散落的常量)

**After:** 每个文件 < 300 行，职责单一，新增 HookScriptGenerator.swift、HookInstaller.swift、BindingVerifier.swift、VibeFocusConstants.swift

**Safety Net:** 992 个现有测试作为安全网，每个 Task 后必须全量通过

**Risks:**
- Task 1 拆分 ClaudeHookPreferences 可能影响 Settings UI 和 HookServer 的引用路径 → 缓解：使用 extension 而非新类，保持类型名不变
- Task 2 拆分 WindowMove 逻辑涉及多个回调路径 → 缓解：先复制全部逻辑到新 extension，验证通过后再删旧代码
- Task 3 提取 BindingVerifier 涉及 SessionWindowRegistry 的内部状态 → 缓解：Verifier 接收参数而非直接访问 state
- Task 4 常量迁移可能遗漏使用点 → 缓解：用 grep 全局搜索每个旧值

**Autonomy Level:** Full — AI 自行完成所有 Task，仅在真正阻塞时通知用户

---

### Task 1: 拆分 ClaudeHookPreferences — 提取脚本生成逻辑

**Depends on:** None
**Files:**
- Create: `Sources/Hook/HookScriptGenerator.swift`
- Modify: `Sources/Hook/ClaudeHookPreferences.swift:295-549`（删除已迁移代码，保留调用入口）
- Test: `swift test`（全量回归）

**目标：** 将 ClaudeHookPreferences 从 686 行降至 ~350 行，把 bash 脚本生成逻辑（~250 行）独立到 HookScriptGenerator.swift

- [ ] **Step 1: 创建 HookScriptGenerator.swift — 承载所有脚本生成函数**

文件: `Sources/Hook/HookScriptGenerator.swift`

从 `ClaudeHookPreferences.swift` 中提取以下函数到新文件的 extension：

| 原始位置 | 函数 | 新位置 |
|----------|------|--------|
| Lines 295-352 | `generateHelperScriptContent()` | HookScriptGenerator.swift |
| Lines 357-445 | `generateRemoteInstallScript()` | HookScriptGenerator.swift |
| Lines 448-505 | `generateRemoteHelperScriptContent()` | HookScriptGenerator.swift |
| Lines 507-514 | `makeHookEntry()` | HookScriptGenerator.swift |
| Lines 516-536 | `generateHooksDict()` | HookScriptGenerator.swift |
| Lines 538-549 | `generateHooksJSON()` | HookScriptGenerator.swift |

**实现方式：** 创建 `extension ClaudeHookPreferences` 新文件，将上述函数**原封不动**复制过去。不改变任何函数签名、访问级别或实现。这些函数目前都是 `ClaudeHookPreferences` 的成员方法，通过 extension 保持在同一个类型上，所有调用方无需改动。

- [ ] **Step 2: 删除 ClaudeHookPreferences.swift 中已迁移的代码**

文件: `Sources/Hook/ClaudeHookPreferences.swift`

删除 Lines 295-549（已迁移到 HookScriptGenerator.swift 的 6 个函数）。这些函数现在通过 extension 文件提供，所以删除后不影响编译。

- [ ] **Step 3: 验证 — 全量测试通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

Run: `swift test 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Test suite summary shows no new failures
  - 如果有 pre-existing 失败（已知 5 个 restore 测试），数量不变

- [ ] **Step 4: 质量门禁检查**

Run: `swift build 2>&1 && swift test 2>&1 | grep -E "Test Suite|passed|failed"`
Expected:
  - Build complete
  - 无新增失败测试
  - 无 TODO/FIXME 遗留

**手工检查（AI 自行验证）：**
- [ ] HookScriptGenerator.swift 中代码与原始代码完全一致（无行为变更）
- [ ] ClaudeHookPreferences.swift 中已删除对应行
- [ ] 其他文件中对 `generateHelperScriptContent()` 等函数的调用仍然有效

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/HookScriptGenerator.swift Sources/Hook/ClaudeHookPreferences.swift && git commit -m "refactor(hook): extract HookScriptGenerator from ClaudeHookPreferences"`

---

### Task 2: 拆分 ClaudeHookPreferences — 提取安装逻辑

**Depends on:** Task 1
**Files:**
- Create: `Sources/Hook/HookInstaller.swift`
- Modify: `Sources/Hook/ClaudeHookPreferences.swift:551-679`（删除已迁移代码）
- Test: `swift test`（全量回归）

**目标：** 将 ClaudeHookPreferences 进一步从 ~350 行降至 ~200 行，把 Hook 安装/卸载逻辑（~130 行）独立到 HookInstaller.swift

- [ ] **Step 1: 创建 HookInstaller.swift — 承载安装/卸载函数**

文件: `Sources/Hook/HookInstaller.swift`

从 `ClaudeHookPreferences.swift` 中提取以下函数到新文件的 extension：

| 原始位置（Task 1 后可能偏移） | 函数 | 新位置 |
|------|------|--------|
| 原 Lines 553-624 | `installHookToClaudeSettings()` | HookInstaller.swift |
| 原 Lines 627-650 | `cleanVibeFocusHooks()` | HookInstaller.swift |
| 原 Lines 653-679 | `uninstallHookFromClaudeSettings()` | HookInstaller.swift |
| 原 Lines 257-281 | `installHelperScript()` | HookInstaller.swift |
| 原 Lines 284-292 | `removeHelperFiles()` | HookInstaller.swift |
| 原 Lines 233-253 | `writeConfigFile()` | HookInstaller.swift |

**实现方式：** 同 Task 1，创建 `extension ClaudeHookPreferences`，函数原封不动复制。不改变签名或行为。

**如果行号因 Task 1 偏移：** 用函数名 grep 定位 → `grep -n "func installHookToClaudeSettings\|func cleanVibeFocusHooks\|func uninstallHookFromClaudeSettings\|func installHelperScript\|func removeHelperFiles\|func writeConfigFile" Sources/Hook/ClaudeHookPreferences.swift`

- [ ] **Step 2: 删除 ClaudeHookPreferences.swift 中已迁移的代码**

用 Step 1 中 grep 得到的新行号，删除已迁移到 HookInstaller.swift 的 6 个函数。

- [ ] **Step 3: 验证 — 全量测试通过**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected:
  - Build complete
  - 无新增失败测试

- [ ] **Step 4: 质量门禁检查**

Run: `swift build 2>&1 && swift test 2>&1 | grep -E "Test Suite|passed|failed"`
Expected:
  - Build complete
  - 无新增失败

**手工检查：**
- [ ] HookInstaller.swift 中代码与原始代码完全一致
- [ ] ClaudeHookPreferences.swift 最终约 200 行（偏好属性 + URL 生成 + isHookInstalled + shell 扩展）
- [ ] SettingsView+ClaudeHookSection.swift 中的 `installHookToClaudeSettings()` 调用仍然有效

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/HookInstaller.swift Sources/Hook/ClaudeHookPreferences.swift && git commit -m "refactor(hook): extract HookInstaller from ClaudeHookPreferences"`

---

### Task 3: 提取 BindingVerifier — 从 SessionWindowRegistry 分离验证逻辑

**Depends on:** None（可与 Task 1/2 并行）
**Files:**
- Create: `Sources/Hook/BindingVerifier.swift`
- Modify: `Sources/Hook/SessionWindowRegistry.swift:194-263`（删除已迁移代码，保留调用入口）
- Test: `swift test`（全量回归）

**目标：** 将 SessionWindowRegistry 从 413 行降至 ~340 行，把绑定验证逻辑（~70 行）独立到 BindingVerifier.swift

- [ ] **Step 1: 创建 BindingVerifier.swift — 承载验证决策和逻辑**

文件: `Sources/Hook/BindingVerifier.swift`

从 `SessionWindowRegistry.swift` 中提取以下代码到新文件：

| 原始位置 | 内容 | 新位置 |
|----------|------|--------|
| Lines 196-216 | `BindingVerificationDecision` enum + `decideBindingVerification()` 纯函数 | BindingVerifier.swift |
| Lines 218-263 | `verifyBinding()` 方法 | BindingVerifier.swift |

**实现方式：**

1. 将 `BindingVerificationDecision` enum 和 `decideBindingVerification()` 静态函数提取为独立的 `BindingVerifier` struct（而非 extension），因为它们是纯决策逻辑，不依赖 SessionWindowRegistry 的内部状态
2. `verifyBinding()` 方法保留在 SessionWindowRegistry 内部（因为它访问 `binding()` 等 Registry 方法），但将其内部的核心判断逻辑委托给 `BindingVerifier.decideBindingVerification()`

**如果决定使用 extension 方式（更安全）：** 创建 `extension SessionWindowRegistry` 文件，把 Lines 194-263 原封不动复制过去，保持完全一致的调用路径。

- [ ] **Step 2: 删除 SessionWindowRegistry.swift 中已迁移的代码**

如果使用 extension 方式：删除 Lines 194-263，它们现在在 BindingVerifier.swift 中提供。

如果使用独立 struct 方式：将 `verifyBinding()` 改为调用 `BindingVerifier.decideBindingVerification()` 的结果。

- [ ] **Step 3: 验证 — 全量测试通过**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected:
  - Build complete
  - 无新增失败测试

- [ ] **Step 4: 质量门禁检查**

Run: `swift build 2>&1 && swift test 2>&1 | grep -E "Test Suite|passed|failed"`
Expected:
  - Build complete
  - 无新增失败

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/BindingVerifier.swift Sources/Hook/SessionWindowRegistry.swift && git commit -m "refactor(hook): extract BindingVerifier from SessionWindowRegistry"`

---

### Task 4: 集中管理硬编码常量

**Depends on:** None（可与 Task 1-3 并行）
**Files:**
- Create: `Sources/Support/VibeFocusConstants.swift`
- Modify: 多个文件（将硬编码值替换为常量引用）
- Test: `swift test`（全量回归）

**目标：** 创建集中的常量文件，消除散落在各处的 magic number 和硬编码路径

- [ ] **Step 1: 创建 VibeFocusConstants.swift — 定义所有常量**

文件: `Sources/Support/VibeFocusConstants.swift`

```swift
import Foundation

/// VibeFocus 全局常量集中管理
/// 所有硬编码值统一在此定义，禁止在业务代码中出现 magic number
enum VFConstants {

    // MARK: - 端口
    static let defaultHookServerPort: UInt16 = 39277
    static let minValidPort: UInt16 = 1024
    static let maxValidPort: UInt16 = 65535

    // MARK: - 文件路径
    static let configDirName = ".vibefocus"
    static let tempLogFilePath = "/tmp/vibefocus.log"
    static let crashSnapshotLogPath = "/tmp/vibefocus-crash-snapshot.log"
    static let claudeSettingsRelativePath = ".claude/settings.json"
    static let appLockFilePath = "/tmp/VibeFocus.lock"

    // MARK: - 文件权限
    static let filePermissionReadWrite: mode_t = 0o644
    static let filePermissionExecutable: mode_t = 0o755

    // MARK: - 时间常量（秒）
    static let completedRetentionSeconds: TimeInterval = 4 * 60 * 60   // 4小时
    static let activeRetentionSeconds: TimeInterval = 24 * 60 * 60     // 24小时
    static let bindingMaxAgeSeconds: TimeInterval = 1800               // 30分钟

    // MARK: - 缓冲区大小
    static let crashSnapshotBufferSize = 16384
    static let maxLogSizeBytes = 25 * 1024 * 1024                      // 25MB
    static let structuredLogLineLimit = 1200

    // MARK: - 通知名
    static let openSettingsNotification = "com.vibefocus.app.open-settings"
    static let hotKeyConfigDidChange = "HotKeyConfigurationDidChange"
    static let hookServerStateChanged = "ClaudeHookServerStateChanged"
}
```

- [ ] **Step 2: 替换 Hook 模块中的硬编码值**

逐文件替换（每替换一个文件后 build 验证）：

| 文件 | 替换内容 |
|------|---------|
| `ClaudeHookPreferences.swift` | `39277` → `VFConstants.defaultHookServerPort` |
| `ClaudeHookPreferences.swift` | `1024`/`65535` → `VFConstants.minValidPort`/`maxValidPort` |
| `ClaudeHookPreferences.swift` | `0o755` → `VFConstants.filePermissionExecutable` |
| `HookEventHandler+WindowMove.swift` | `1800` → `VFConstants.bindingMaxAgeSeconds` |
| `SessionWindowRegistry.swift` | `4 * 60 * 60` → `VFConstants.completedRetentionSeconds` |
| `SessionWindowRegistry.swift` | `24 * 60 * 60` → `VFConstants.activeRetentionSeconds` |

- [ ] **Step 3: 替换 Support 模块中的硬编码值**

| 文件 | 替换内容 |
|------|---------|
| `CrashContext.swift` | `"/tmp/vibefocus-crash-snapshot.log"` → `VFConstants.crashSnapshotLogPath` |
| `CrashContext.swift` | `16384` → `VFConstants.crashSnapshotBufferSize` |
| `CrashContext.swift` | `0o644` → `VFConstants.filePermissionReadWrite` |
| `CrashContextRecorder.swift` | `"/tmp/vibefocus.log"` → `VFConstants.tempLogFilePath` |
| `CrashContextRecorder.swift` | `1200` → `VFConstants.structuredLogLineLimit` |
| `Support.swift` | `25 * 1024 * 1024` → `VFConstants.maxLogSizeBytes` |

- [ ] **Step 4: 替换 App 模块中的硬编码值**

| 文件 | 替换内容 |
|------|---------|
| `AppDelegate.swift` | `"/tmp/VibeFocus.lock"` → `VFConstants.appLockFilePath` |
| `AppDelegate.swift` | `"com.vibefocus.app.open-settings"` → `VFConstants.openSettingsNotification` |

- [ ] **Step 5: 验证 — 全量测试通过**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected:
  - Build complete
  - 无新增失败测试

- [ ] **Step 6: 质量门禁检查**

Run: `swift build 2>&1 && swift test 2>&1 | grep -E "Test Suite|passed|failed"`
Expected:
  - Build complete
  - 无新增失败

**手工检查：**
- [ ] grep 验证旧值已被完全替换：`grep -rn "39277\|/tmp/VibeFocus.lock\|/tmp/vibefocus.log" Sources/` 应返回 0 结果（除常量文件本身）
- [ ] 无遗留硬编码 magic number

- [ ] **Step 7: 提交**
Run: `git add Sources/Support/VibeFocusConstants.swift && git add -u && git commit -m "refactor: centralize hardcoded constants into VibeFocusConstants"`

---

### Task 5: 修复高风险 Force Unwrap

**Depends on:** None（可与其他 Task 并行）
**Files:**
- Modify: `Sources/Space/SpaceController+Context.swift:117`
- Modify: `Sources/Window/WindowStateStore+Bindings.swift:106,121,136,176`
- Modify: `Sources/Window/WindowStateStore+ToggleRecord.swift:173,197`
- Test: `swift test`

**目标：** 消除剩余的高风险 force unwrap，提高运行时稳定性

- [ ] **Step 1: 修复 SpaceController+Context.swift 中的高风险 force unwrap**

文件: `Sources/Space/SpaceController+Context.swift`

查找 `String(result!)` 并替换为安全版本：

```swift
// 原始代码（大约在 line 117 附近）:
// fields: ["yabaiIndex": String(index), "nativeSpaceID": String(result!)]

// 替换为:
fields: ["yabaiIndex": String(index), "nativeSpaceID": String(result ?? "unknown")]
```

**如果行号偏移：** 用 `grep -n "result!" Sources/Space/SpaceController+Context.swift` 定位

- [ ] **Step 2: 修复 WindowStateStore+Bindings.swift 中的 SQLite force unwrap**

文件: `Sources/Window/WindowStateStore+Bindings.swift`

查找所有 `stmt!` 并替换为安全解包模式。这些出现在 `sqlite3_step(stmt) == SQLITE_ROW` 检查之后，理论上是安全的，但添加 guard 更清晰：

```swift
// 原始模式（出现在 lines 106, 121, 136, 176 附近）:
// if sqlite3_step(stmt) == SQLITE_ROW {
//     let value = sqlite3_column_text(stmt!, 0)
// }

// 替换为:
guard sqlite3_step(stmt) == SQLITE_ROW, let s = stmt else { return nil }
let value = sqlite3_column_text(s, 0)
```

对文件中所有 `stmt!` 出现的位置逐一替换。

- [ ] **Step 3: 修复 WindowStateStore+ToggleRecord.swift 中的 force unwrap**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift`

查找 `parseToggleRecord(stmt!)` 并替换：

```swift
// 原始模式（出现在 lines 173, 197 附近）:
// if sqlite3_step(stmt) == SQLITE_ROW {
//     return parseToggleRecord(stmt!)
// }

// 替换为:
guard sqlite3_step(stmt) == SQLITE_ROW, let s = stmt else { return nil }
return parseToggleRecord(s)
```

- [ ] **Step 4: 验证 — 全量测试通过**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected:
  - Build complete
  - 无新增失败测试

- [ ] **Step 5: 质量门禁检查**

Run: `swift build 2>&1 && swift test 2>&1 | grep -E "Test Suite|passed|failed"`
Expected:
  - Build complete
  - 无新增失败

**手工检查：**
- [ ] `grep -rn "stmt!" Sources/` 应返回 0 结果（或仅剩测试文件中的安全用法）
- [ ] `grep -rn "result!" Sources/Space/` 应返回 0 结果

- [ ] **Step 6: 提交**
Run: `git add Sources/Space/SpaceController+Context.swift Sources/Window/WindowStateStore+Bindings.swift Sources/Window/WindowStateStore+ToggleRecord.swift && git commit -m "fix: replace dangerous force unwraps with safe alternatives"`

---

### Task 6: 最终集成验证 — 确认重构无回归

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5
**Files:**
- 无代码变更
- 全量构建 + 全量测试 + 文件行数验证

- [ ] **Step 1: 全量构建和测试**

Run: `swift build 2>&1 && swift test 2>&1 | tail -10`
Expected:
  - Build complete
  - 测试套件完成
  - 失败数不超过重构前（已知 5 个 pre-existing 失败）

- [ ] **Step 2: 验证文件行数 — 确认拆分效果**

Run: `wc -l Sources/Hook/ClaudeHookPreferences.swift Sources/Hook/HookScriptGenerator.swift Sources/Hook/HookInstaller.swift Sources/Hook/BindingVerifier.swift Sources/Support/VibeFocusConstants.swift`
Expected:
  - ClaudeHookPreferences.swift: ~200 行（从 686 行降低）
  - HookScriptGenerator.swift: ~250 行
  - HookInstaller.swift: ~130 行
  - BindingVerifier.swift: ~70 行
  - VibeFocusConstants.swift: ~50 行

- [ ] **Step 3: 验证 Hook 模块整体文件结构**

Run: `ls -la Sources/Hook/ && echo "---" && wc -l Sources/Hook/*.swift | sort -n`
Expected:
  - 每个文件 < 300 行
  - 文件数量从 8 增加到 11（+3 新文件）

- [ ] **Step 4: 确认无 force unwrap 遗留**

Run: `grep -rn "stmt!\|result!" Sources/ --include="*.swift" | grep -v "Tests/" | grep -v "isEmpty"`
Expected:
  - 0 结果（或注释说明的安全用法）

- [ ] **Step 5: 生成重构报告**

输出重构前后对比表：

| 文件 | 重构前行数 | 重构后行数 | 变化 |
|------|-----------|-----------|------|
| ClaudeHookPreferences.swift | 686 | ~200 | -71% |
| HookEventHandler.swift | 536 | 536 | 不变（下期处理） |
| HookEventHandler+WindowMove.swift | 441 | 441 | 不变（下期处理） |
| SessionWindowRegistry.swift | 413 | ~340 | -18% |
| HookScriptGenerator.swift (新) | 0 | ~250 | +250 |
| HookInstaller.swift (新) | 0 | ~130 | +130 |
| BindingVerifier.swift (新) | 0 | ~70 | +70 |
| VibeFocusConstants.swift (新) | 0 | ~50 | +50 |

- [ ] **Step 6: 提交最终状态（如有遗漏修复）**

仅在有额外修改时提交。

---

## 执行顺序和并行策略

```
Task 1 (拆 ClaudeHookPreferences 脚本生成) ──┐
Task 2 (拆 ClaudeHookPreferences 安装逻辑) ──┤ 串行: 1 → 2
Task 3 (提取 BindingVerifier)                ──┤ 可并行
Task 4 (集中常量)                            ──┤ 可并行
Task 5 (修 force unwrap)                     ──┤ 可并行
Task 6 (最终验证)                            ──┘ 依赖全部完成
```

**推荐执行顺序：**
1. Task 4 + Task 5 并行（独立，低风险）
2. Task 1 → Task 2 串行（同一文件的连续拆分）
3. Task 3 独立执行
4. Task 6 最终验证

## 后续计划（本期不做）

以下是调研发现但**本期不处理**的重构方向，留给下一个 Plan：

1. **WindowManager God Object 拆分** — 将 45+ 方法的 God Object 拆为 AXWindowController、WindowFinder、WindowMover、ScreenPositionService、ToggleOrchestrator（影响 12 个文件，高风险）
2. **HookEventHandler 进一步拆分** — 将 handleSessionStart (150行) 拆为验证→解析→绑定→标题设置 子步骤
3. **Settings 业务逻辑提取** — 将 SettingsView+Helpers 中的文件操作和 HTTP 请求移出 UI 层
4. **Singleton 模式改造** — 用协议 + 依赖注入替换 `.shared` 全局访问（影响全局，最大风险）
5. **WindowStateStore 分层** — 将数据库连接、Schema 管理、CRUD 操作分离为 Repository 模式
