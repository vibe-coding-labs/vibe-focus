# Refactor: 大文件拆分 Phase 2 — 提升 Hook/Space/Window 模块可读性

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 4 个超过 380 行的文件拆分为 200 行以内的职责单一文件，延续 Phase 1 的 extension 模式，零 caller 改动。

**Architecture:** 使用 Swift `extension` 同名类型拆分 — 原类型名不变，所有 caller 无需修改。每个新文件承载一个内聚职责。每个 Task 独立可验证：创建新文件 → 从原文件删除对应代码 → 编译 → 测试 → 提交。

**Before/After:**
- Before: 4 个 380-536 行的"胖文件"，职责混杂
- After: 每个文件 < 200 行，每个文件一个清晰职责

**Safety Net:** 992 个现有测试（990 pass + 2 pre-existing fail），每步验证编译+测试通过。

**Scope:** Medium
**Risk:** Low
**Autonomy Level:** Full

**Risks:**
- `private` 方法移到 extension 文件后需改为 `internal`（去掉 `private`）— 跟 Phase 1 一致
- 行号在执行时可能偏移 → 用函数名 grep 定位作为 fallback
- `HookEventHandler` 中 `RestoreEligibility` 和 `decideRestoreEligibility` 标记为 deprecated 但仍被测试引用 — 必须一起迁移

---

### Task 1: 拆分 HookEventHandler — 提取 SessionStart 处理

**Depends on:** None
**Files:**
- Create: `Sources/Hook/HookEventHandler+SessionStart.swift`
- Modify: `Sources/Hook/HookEventHandler.swift`（删除 lines 48-201）

- [ ] **Step 1: 创建 HookEventHandler+SessionStart.swift — 承载 handleSessionStart 方法**

```swift
// HookEventHandler+SessionStart.swift
// VibeFocus — SessionStart 事件处理
// 从 HookEventHandler.swift 中提取

import Foundation
import Cocoa

@MainActor
extension HookEventHandler {

    // MARK: - Session Start

    func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[handleSessionStart] called",
            level: .debug,
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil",
                "hasTerminalCtx": String(payload.terminalCtx != nil),
                "terminalCtxUseful": String(payload.terminalCtx?.hasUsefulContext ?? false),
                "isRemote": String(payload.terminalCtx?.isRemote ?? false),
                "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
            ]
        )

        guard let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext else {
            log(
                "[handleSessionStart] no terminal context, cannot bind",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：无终端上下文")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "no_terminal_context",
                    message: "No terminal context available for precise binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 区分本地绑定和远程映射
        let identity: WindowIdentity
        if terminalCtx.isRemote, let label = terminalCtx.machineLabel {
            log(
                "[handleSessionStart] remote session detected, resolving via machine_label",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil"
                ]
            )
            guard let resolved = resolveRemoteBinding(label: label, sessionID: payload.sessionID) else {
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "remote_binding_failed",
                        message: "Remote machine label '\(label)' not mapped to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = resolved
        } else {
            log(
                "[handleSessionStart] local session, resolving via TTY/PPID",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil",
                    "termSessionID": terminalCtx.termSessionID ?? "nil"
                ]
            )
            guard let localIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
                log(
                    "[handleSessionStart] terminal context match failed",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "tty": terminalCtx.tty ?? "nil",
                        "ppid": terminalCtx.ppid ?? "nil"
                    ]
                )
                SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：终端上下文无法匹配窗口")
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "terminal_context_match_failed",
                        message: "Terminal context could not be resolved to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = localIdentity
        }

        log(
            "[HookEventHandler] SessionStart matched",
            fields: [
                "sessionID": payload.sessionID,
                "isRemote": String(terminalCtx.isRemote),
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
        let resolvedBindingType: WindowState.BindingType = terminalCtx.isRemote ? .remote : .local
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model,
            bindingType: resolvedBindingType
        )
        AuditLogger.shared.record(
            eventType: "session_bind",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: payload.sessionID,
            details: [
                "app": identity.appName ?? "unknown",
                "isRemote": String(terminalCtx.isRemote),
                "bindingType": String(describing: resolvedBindingType),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        // Auto-set terminal title to project name
        if let axWindow = WindowManager.shared.resolveWindow(identity: identity) {
            TitleEditorService.shared.autoSetTitle(
                cwd: payload.cwd,
                pid: identity.pid,
                bundleID: identity.bundleIdentifier ?? "",
                window: axWindow
            )
        } else {
            log(
                "[HookEventHandler] SessionStart autoSetTitle skipped: could not resolve AX window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via \(terminalCtx.isRemote ? "remote_label" : "TTY/PPID")",
                sessionID: payload.sessionID, handled: true
            )
        )
    }
}
```

- [ ] **Step 2: 从 HookEventHandler.swift 删除 handleSessionStart 方法**
文件: `Sources/Hook/HookEventHandler.swift:48-201`（`// MARK: - Session Start` 到其方法结尾 `}` 之后的空行）

删除 lines 48-201（`// MARK: - Session Start` 注释 + `handleSessionStart` 方法），替换为：
```swift
    // handleSessionStart 已移至 HookEventHandler+SessionStart.swift
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | grep -E "error:|Build complete!"`
Expected:
  - Output contains: "Build complete!"
  - Output does NOT contain: "error:"

- [ ] **Step 4: 质量门禁**
Run: `swift build 2>&1 | grep "error:" | head -5; swift test 2>&1 | grep -E "Test run with|issues"`
Expected:
  - Build: 0 errors
  - Tests: 992 tests, 2 issues (pre-existing)

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/HookEventHandler+SessionStart.swift Sources/Hook/HookEventHandler.swift && git commit -m "refactor(hook): extract handleSessionStart to dedicated file

HookEventHandler.swift reduced by ~153 lines.
Uses Swift extension pattern — zero caller changes needed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"`

---

### Task 2: 拆分 HookEventHandler — 提取窗口解析逻辑

**Depends on:** Task 1
**Files:**
- Create: `Sources/Hook/HookEventHandler+WindowResolution.swift`
- Modify: `Sources/Hook/HookEventHandler.swift`（删除 lines 375-514 的 WindowResolutionSource/resolveWindowIdentity/RestoreEligibility/decideRestoreEligibility）

- [ ] **Step 1: 创建 HookEventHandler+WindowResolution.swift — 承载窗口身份解析和 restore 决策**

```swift
// HookEventHandler+WindowResolution.swift
// VibeFocus — 窗口身份解析与 restore 决策
// 从 HookEventHandler.swift 中提取

import Foundation
import Cocoa

@MainActor
extension HookEventHandler {

    // MARK: - Window Identity Resolution

    /// Window identity resolution decision — extracted for testability.
    enum WindowResolutionSource {
        case binding(WindowIdentity)
    }

    /// Pure decision logic for resolveWindowIdentity.
    static func decideWindowResolution(
        hasBinding: Bool,
        bindingVerified: Bool,
        bindingIdentity: WindowIdentity?
    ) -> WindowResolutionSource? {
        if hasBinding {
            if bindingVerified, let identity = bindingIdentity {
                return .binding(identity)
            }
            return nil
        }
        return nil
    }

    func resolveWindowIdentity(
        payload: ClaudeHookPayload,
        traceID: String,
        startedAt: Date
    ) -> WindowIdentity? {
        let state = SessionWindowRegistry.shared.binding(for: payload.sessionID)

        if let state {
            log(
                "[HookEventHandler] resolveWindowIdentity: found binding",
                level: .debug,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "windowID": String(state.windowID),
                    "bindingType": String(describing: state.bindingType),
                    "app": state.appName ?? "unknown"
                ]
            )
            if SessionWindowRegistry.shared.verifyBinding(state) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: binding verified",
                    level: .debug,
                    fields: [
                        "traceID": traceID,
                        "windowID": String(state.windowID),
                        "source": "binding"
                    ]
                )
                return WindowIdentity(from: state)
            }
            log(
                "[HookEventHandler] resolveWindowIdentity: binding verification failed",
                level: .warn,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "boundWindowID": String(state.windowID)
                ]
            )
            return nil
        }

        // 无绑定 — 尝试通过 machineLabel 自愈远程 binding
        if let label = payload.terminalCtx?.machineLabel, !label.isEmpty {
            log(
                "[HookEventHandler] resolveWindowIdentity: no binding, attempting remote self-heal",
                level: .info,
                fields: [
                    "traceID": traceID,
                    "sessionID": payload.sessionID,
                    "machineLabel": label
                ]
            )
            if let identity = resolveRemoteBinding(label: label, sessionID: payload.sessionID) {
                log(
                    "[HookEventHandler] resolveWindowIdentity: remote self-heal succeeded, registering binding",
                    level: .info,
                    fields: [
                        "traceID": traceID,
                        "sessionID": payload.sessionID,
                        "machineLabel": label,
                        "windowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown"
                    ]
                )
                SessionWindowRegistry.shared.bind(
                    sessionID: payload.sessionID,
                    windowIdentity: identity,
                    terminalTTY: payload.terminalCtx?.tty,
                    terminalSessionID: payload.terminalCtx?.termSessionID,
                    itermSessionID: payload.terminalCtx?.itermSessionID,
                    cwd: payload.cwd,
                    model: payload.model,
                    bindingType: .remote
                )
                return identity
            }
        }

        log(
            "[HookEventHandler] resolveWindowIdentity: no binding, cannot identify window",
            level: .warn,
            fields: [
                "traceID": traceID,
                "sessionID": payload.sessionID
            ]
        )
        return nil
    }

    // MARK: - Restore Eligibility (Deprecated — kept for test compatibility)

    /// Restore eligibility decision — extracted for testability.
    /// ⚠️ 注意：此 enum 及 decideRestoreEligibility 仅被测试引用，生产代码不再使用。
    /// UserPromptSubmit 现在直接使用 moveWindowToMainScreen（单向移动到主屏）。
    enum RestoreEligibility {
        case eligible(record: ToggleRecord, mainScreenFrame: CGRect)
        case toggleInFlight
        case windowNotOnMainScreen
        case noRecord
        case recordInvalid(windowID: UInt32)
    }

    /// Pure decision logic for validateRestoreEligibility.
    static func decideRestoreEligibility(
        isToggleInFlight: Bool,
        isWindowOnMainScreen: Bool,
        record: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreEligibility {
        if isToggleInFlight { return .toggleInFlight }
        guard let record else { return .noRecord }
        guard let mainScreenFrame, record.isValid(mainScreenFrame: mainScreenFrame) else {
            return .recordInvalid(windowID: record.windowID)
        }
        return .eligible(record: record, mainScreenFrame: mainScreenFrame)
    }
}
```

- [ ] **Step 2: 从 HookEventHandler.swift 删除窗口解析代码**
文件: `Sources/Hook/HookEventHandler.swift`（删除 `// MARK: - UserPromptSubmit Sub-steps` 到 `// MARK: - Stop` 之前的所有内容，即 `WindowResolutionSource` enum、`decideWindowResolution`、`resolveWindowIdentity`、`RestoreEligibility`、`decideRestoreEligibility`）

替换为：
```swift
    // 窗口解析逻辑已移至 HookEventHandler+WindowResolution.swift
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | grep -E "error:|Build complete!"`
Expected:
  - Output contains: "Build complete!"
  - Output does NOT contain: "error:"

- [ ] **Step 4: 质量门禁**
Run: `swift build 2>&1 | grep "error:" | head -5; swift test 2>&1 | grep -E "Test run with|issues"`
Expected:
  - Build: 0 errors
  - Tests: 992 tests, 2 issues (pre-existing)

- [ ] **Step 5: 提交**
Run: `git add Sources/Hook/HookEventHandler+WindowResolution.swift Sources/Hook/HookEventHandler.swift && git commit -m "refactor(hook): extract window resolution logic to dedicated file

Extract WindowResolutionSource, resolveWindowIdentity,
RestoreEligibility, decideRestoreEligibility.

HookEventHandler.swift reduced by ~140 lines.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"`

---

### Task 3: 拆分 SpaceController — 提取类型定义和 Yabai 执行层

**Depends on:** None
**Files:**
- Create: `Sources/Space/SpaceController+Types.swift`
- Create: `Sources/Space/SpaceController+Yabai.swift`
- Modify: `Sources/Space/SpaceController.swift`（删除对应行）

- [ ] **Step 1: 创建 SpaceController+Types.swift — 承载 enums/structs/typealiases**

提取 SpaceController.swift 中的：
- `SpaceAvailability` enum (lines 5-10)
- `SpaceRestoreStrategy` enum (lines 12-15)
- `SpacePreferences` struct (lines 17-44)
- `SpaceContext` struct (lines 46-51)
- `ShellResult` typealias (line 368)
- `YabaiSpaceInfo` struct (lines 370-386)
- `YabaiWindowInfo` struct (lines 388-425)
- `YabaiDisplayInfo` struct (lines 427-437)

创建文件 `Sources/Space/SpaceController+Types.swift`，包含以上所有类型定义（原样复制，不改任何代码）。

- [ ] **Step 2: 创建 SpaceController+Yabai.swift — 承载 Yabai 命令执行**

提取 SpaceController.swift 中的：
- `isScriptingAdditionError` (lines 156-159)
- `runYabai` (lines 161-217)
- `runYabaiVariants` (lines 219-285)
- `markOperationError` 两个重载 (lines 289-323)
- `runProcess` (lines 325-327)
- `decodeSingleOrFirst` / `decodeArray` / `staticDecodeSingleOrFirst` (lines 329-352)
- `formatErrorMessage` (lines 354-364)

作为 `extension SpaceController` 写入 `Sources/Space/SpaceController+Yabai.swift`。

- [ ] **Step 3: 从 SpaceController.swift 删除已提取的代码**

删除 SpaceController.swift 中的：
1. Lines 5-51（类型定义：SpaceAvailability/SpaceRestoreStrategy/SpacePreferences/SpaceContext）
2. Lines 156-365（Yabai 执行：isScriptingAdditionError/runYabai/runYabaiVariants/markOperationError/runProcess/decode*/formatErrorMessage）
3. Lines 368-437（ShellResult typealias + YabaiSpaceInfo/YabaiWindowInfo/YabaiDisplayInfo）

保留：
- class 定义 + properties + init + updateEnabledState + refreshAvailability (lines 53-153)
- query cache 逻辑 (lines 68-87)
- `refreshAvailability` 中的辅助调用 `locateYabai` / `checkScriptingAdditionLoaded` / `attemptSilentSARecovery`（这些在其他 extension 文件中）

在删除位置添加注释：
```swift
// 类型定义已移至 SpaceController+Types.swift
// Yabai 执行逻辑已移至 SpaceController+Yabai.swift
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | grep -E "error:|Build complete!"`
Expected:
  - Output contains: "Build complete!"
  - Output does NOT contain: "error:"

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep "error:" | head -5; swift test 2>&1 | grep -E "Test run with|issues"`
Expected:
  - Build: 0 errors
  - Tests: 992 tests, 2 issues (pre-existing)

- [ ] **Step 6: 提交**
Run: `git add Sources/Space/SpaceController+Types.swift Sources/Space/SpaceController+Yabai.swift Sources/Space/SpaceController.swift && git commit -m "refactor(space): extract types and yabai execution from SpaceController

SpaceController.swift reduced from 437 to ~100 lines.
- SpaceController+Types.swift: enums, structs, typealiases
- SpaceController+Yabai.swift: yabai command execution, decoding, error handling

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"`

---

### Task 4: 拆分 WindowManager+TerminalContext — 提取 iTerm2 和 TTY 匹配

**Depends on:** None
**Files:**
- Create: `Sources/Window/WindowManager+TerminalContext+Helpers.swift`
- Create: `Sources/Window/WindowManager+TerminalContext+iTerm2.swift`
- Modify: `Sources/Window/WindowManager+TerminalContext.swift`

- [ ] **Step 1: 创建 WindowManager+TerminalContext+Helpers.swift — 承载纯函数工具**

提取：
- `normalizeTTY` (lines 15-18)
- `filterWindowsByPID` (lines 178-193)
- `matchCommandToWindowTitle` (lines 196-209)
- `parseCommandBasename` (lines 212-221)
- `findWindowsForPID` (lines 224-231) — 注意：`private` 需去掉
- `parseItermSessionUUID` (lines 234-242) — 注意：`static` 已经不是 private

作为 `extension WindowManager` 写入。

- [ ] **Step 2: 创建 WindowManager+TerminalContext+iTerm2.swift — 承载 iTerm2 AppleScript 匹配**

提取：
- `matchiTerm2WindowBySessionID` (lines 247-297) — 去掉 `private`
- `matchTerminalWindowByAppleScript` (lines 302-352) — 去掉 `private`
- `matchWindowByTTYProcess` (lines 355-381) — 去掉 `private`
- `resolveTTY` (lines 386-409) — 去掉 `private`

作为 `extension WindowManager` 写入。

- [ ] **Step 3: 从 WindowManager+TerminalContext.swift 删除已提取代码**

保留：`findWindowByTerminalContext` 主入口方法 (lines 24-175) — 这是调用以上所有 helper 的编排逻辑。

删除 lines 177-409（所有 helper/private 方法），替换为：
```swift
    // 纯函数工具已移至 WindowManager+TerminalContext+Helpers.swift
    // iTerm2/TTY/AppleScript 匹配已移至 WindowManager+TerminalContext+iTerm2.swift
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | grep -E "error:|Build complete!"`
Expected:
  - Output contains: "Build complete!"

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep "error:" | head -5; swift test 2>&1 | grep -E "Test run with|issues"`
Expected:
  - Build: 0 errors
  - Tests: 992 tests, 2 issues (pre-existing)

- [ ] **Step 6: 提交**
Run: `git add Sources/Window/WindowManager+TerminalContext+Helpers.swift Sources/Window/WindowManager+TerminalContext+iTerm2.swift Sources/Window/WindowManager+TerminalContext.swift && git commit -m "refactor(window): extract terminal context helpers and iTerm2 matching

WindowManager+TerminalContext.swift reduced from 410 to ~180 lines.
- Helpers: normalizeTTY, filterWindowsByPID, matchCommandToWindowTitle, parseCommandBasename
- iTerm2: AppleScript session matching, TTY process matching, resolveTTY

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"`

---

### Task 5: 拆分 WindowManager+Toggle — 提取 restore 决策

**Depends on:** None
**Files:**
- Create: `Sources/Window/WindowManager+Toggle+Decision.swift`
- Modify: `Sources/Window/WindowManager+Toggle.swift`

- [ ] **Step 1: 创建 WindowManager+Toggle+Decision.swift — 承载 restore 决策逻辑**

提取：
- `RestoreDecision` enum (lines 267-274)
- `decideRestore` static method (lines 276-299)
- `shouldRestoreCurrentWindow()` 无参版本 (lines 301-303)
- `shouldRestoreCurrentWindow(store:)` 带注入版本 (lines 306-381)

作为 `extension WindowManager` 写入。

- [ ] **Step 2: 从 WindowManager+Toggle.swift 删除已提取代码**

保留：`toggle` 主方法 (lines 7-151)、`moveStuckWindowToSecondaryScreen` (lines 153-197)、`moveToMainScreen` (lines 199-264)。

删除 lines 266-382（RestoreDecision enum + decideRestore + shouldRestoreCurrentWindow），替换为：
```swift
    // restore 决策逻辑已移至 WindowManager+Toggle+Decision.swift
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | grep -E "error:|Build complete!"`
Expected:
  - Output contains: "Build complete!"

- [ ] **Step 4: 质量门禁**
Run: `swift build 2>&1 | grep "error:" | head -5; swift test 2>&1 | grep -E "Test run with|issues"`
Expected:
  - Build: 0 errors
  - Tests: 992 tests, 2 issues (pre-existing)

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+Toggle+Decision.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "refactor(window): extract toggle restore decision logic

WindowManager+Toggle.swift reduced from 382 to ~270 lines.
RestoreDecision enum and shouldRestoreCurrentWindow moved to dedicated file.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"`

---

### Task 6: 最终集成验证

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5

- [ ] **Step 1: 全量编译 + 测试**
Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected:
  - Build complete!
  - 992 tests, 2 issues (pre-existing)

- [ ] **Step 2: 生成重构报告**
Run: `wc -l Sources/Hook/HookEventHandler.swift Sources/Hook/HookEventHandler+*.swift Sources/Space/SpaceController.swift Sources/Space/SpaceController+*.swift Sources/Window/WindowManager+*.swift | sort -rn`

Expected: 所有主文件 < 250 行，每个新文件有明确职责。

- [ ] **Step 3: 提交报告**（如有必要）
