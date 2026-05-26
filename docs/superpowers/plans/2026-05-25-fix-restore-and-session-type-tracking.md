# Fix: Restore 路径 ToggleRecord 丢失 + Session 类型追踪

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 用户报告"从主屏幕回退又有点问题了"。日志显示窗口被 `moveWindowToMainScreen` 成功移动到主屏（`saveToggleRecord saved`），但随后 Ctrl+Q toggle 时 `shouldRestoreCurrentWindow` 报 `no toggle record` → 窗口被当作 "stuck" 推回副屏。

**Root Cause:** `moveWindowToMainScreen`（WindowManager+MoveWindow.swift:124-145）只在 `sourceSpaceIndex != nil` 时才调用 `ToggleEngine.shared.save()`。当 yabai 无法查询到窗口的 space 信息（远程 session 窗口、窗口被 yabai 忽略、yabai 未运行等），`captureSpaceContext` 返回 `sourceSpaceIndex: nil`，整个 `saveToggleRecord` 逻辑被跳过。日志却仍显示 `saveToggleRecord saved`，因为 **那行日志来自上一条 UPDATE 操作的成功返回**——但 UPDATE 的 WHERE 条件匹配了之前 `moveWindowToMainScreenAndRespond` 通过 HookEventHandler 路径创建的绑定行，而不是当前窗口。

**Impact:** 所有通过 UserPromptSubmit fallback（无 ToggleRecord 的远程 session）触发的 `moveWindowToMainScreen` 都不会保存 ToggleRecord → 后续 Ctrl+Q 无法 restore → 窗口被推回副屏。

**Architecture:** 当 `captureSpaceContext` 返回 `sourceSpaceIndex == nil` 时，仍然保存 ToggleRecord，但将 `sourceSpace` 设为 0（标记为"无 space 信息"）。Restore 逻辑遇到 `sourceSpace == 0` 时跳过 yabai space move，仅做 AX frame 恢复。在 `SessionWindowRegistry.bind()` 中添加 `bindingType` 字段（`.local` / `.remote`），用于日志和调试区分。

**Tech Stack:** Swift 5.9+, swift-testing framework, SQLite3

**Scope:** Small
**Risk:** Medium — 修改 `moveWindowToMainScreen` 的 save 路径和 `ToggleEngine.restore` 的 space move 路径

**Risks:**
- 修改 restore 路径可能影响本地 session → 缓解：`sourceSpace == 0` 仅在 yabai 不可用时触发，本地 session 有 yabai 信息不受影响
- `sourceSpace=0` 曾经导致 bug（切换到错误 space）→ 缓解：新逻辑遇到 0 时**跳过 space move**，不做无效切换
- `bindingType` 字段新增到 WindowState → 缓解：SQLite 表无需改动，bindingType 仅在内存中使用

**Autonomy Level:** Full

---

### Task 1: 修复 moveWindowToMainScreen — sourceSpaceIndex 为 nil 时仍保存 ToggleRecord

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:99-145`

- [ ] **Step 1: 修改 moveWindowToMainScreen 的 ToggleRecord save 逻辑 — 移除 sourceSpaceIndex 非空守卫**

文件: `Sources/Window/WindowManager+MoveWindow.swift:122-145`（替换从 `// Save toggle record` 开始的区块）

当前代码在 `if let sourceSpaceIndex = spaceContext.sourceSpaceIndex` 内保存 ToggleRecord，当 yabai 无法查询窗口 space 信息时整个 save 被跳过。改为始终保存，`sourceSpaceIndex` 为 nil 时用 `.yabai(0)` 作为占位值。

```swift
        // Save toggle record — always save, even when yabai can't determine space
        // (sourceSpace=0 signals "no space info, skip yabai space move on restore")
        let actualTargetFrame = frame(of: windowAX) ?? targetFrame
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
        if postMoveWindowID != effectiveWindowID {
            SessionWindowRegistry.shared.remapWindowID(oldWindowID: effectiveWindowID, newWindowID: postMoveWindowID)
        }
        ToggleEngine.shared.save(
            windowID: postMoveWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: teSourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 质量门禁**
Run: `swift build 2>&1 | grep -c "error:" && swift test 2>&1 | grep -c "failed"`
Expected:
  - Exit code: 0
  - Output: `0` (zero errors) then `0` (zero failures)

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+MoveWindow.swift && git commit -m "fix(restore): save ToggleRecord even when yabai space info unavailable"`

---

### Task 2: 修复 ToggleEngine.restore — sourceSpace=0 时跳过 yabai space move

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift:70-73`

- [ ] **Step 1: 修改 restore 方法 — sourceSpace == 0 时跳过 space move 仅做 AX frame 恢复**

文件: `Sources/Toggle/ToggleEngine+Restore.swift:70-78`（替换 yabai space move 区块）

当 `sourceSpace == 0`（yabai 无法确定窗口所在 space）时，跳过 yabai `window --space` 命令，因为 `--space 0` 是无效操作。直接进入 float + AX frame 恢复步骤。

```swift
        // 4. Move to original space via yabai (skip if sourceSpace=0 — no space info available)
        if record.sourceSpace > 0 {
            let moved = sc.moveWindow(
                axLookupID,
                toSpace: .yabai(record.sourceSpace),
                focus: triggerSource == "carbon_hotkey",
                operationID: trace
            )
            log("[ToggleEngine] restore: space move result", fields: [
                "traceID": trace, "moved": String(moved), "sourceSpace": String(record.sourceSpace)
            ])
        } else {
            log("[ToggleEngine] restore: sourceSpace=0, skipping yabai space move (no space info)", fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 质量门禁**
Run: `swift build 2>&1 | grep -c "error:" && swift test 2>&1 | grep -c "failed"`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine+Restore.swift && git commit -m "fix(restore): skip yabai space move when sourceSpace=0"`

---

### Task 3: 在 SessionWindowRegistry.bind 中添加 bindingType 字段区分本地/远程

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/SessionWindowRegistry.swift`
- Modify: `Sources/Hook/HookEventHandler.swift:112-121`

- [ ] **Step 1: 在 WindowState 中添加 bindingType 字段**

文件: `Sources/Hook/SessionWindowRegistry.swift` — 找到 `WindowState` struct 定义，添加：

```swift
    /// 绑定来源类型 — 区分本地终端和远程 SSH session
    let bindingType: BindingType

    enum BindingType: String, Equatable {
        case local       // 本地终端 (TTY/PPID 匹配)
        case remote      // 远程 SSH (machine_label 映射)
    }
```

同时需要更新所有创建 `WindowState` 的地方。搜索 `WindowState(` 构造器调用，确保每个都传入 `bindingType` 参数。

- [ ] **Step 2: 修改 handleSessionStart — 传入 bindingType**

文件: `Sources/Hook/HookEventHandler.swift:112-121`

在 `SessionWindowRegistry.shared.bind()` 调用之前，根据 `terminalCtx.isRemote` 确定 bindingType，传入 bind 方法。

在 bind 方法签名中添加 `bindingType` 参数。更新 `bind()` 实现以存储此值。

- [ ] **Step 3: 在日志中输出 bindingType**

修改 `SessionWindowRegistry.shared.bind()` 内部和 HookEventHandler 的 session_bind 审计日志，加入 `bindingType` 字段。

- [ ] **Step 4: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 5: 质量门禁**
Run: `swift build 2>&1 | grep -c "error:" && swift test 2>&1 | grep -c "failed"`
Expected:
  - Exit code: 0

- [ ] **Step 6: 提交**
Run: `git add Sources/Hook/SessionWindowRegistry.swift Sources/Hook/HookEventHandler.swift && git commit -m "feat(session): add bindingType to distinguish local vs remote sessions"`

---

### Task 4: 补充测试 + 全量回归验证

**Depends on:** Task 1, Task 2, Task 3
**Files:**
- Modify: `Tests/XCTest/IntegrationMockTests.swift`

- [ ] **Step 1: 添加 sourceSpace=0 的 restore 决策测试**

文件: `Tests/XCTest/IntegrationMockTests.swift`（在现有测试之后追加）

```swift
    @Test("decideSystemEventsRestore: sourceSpace=0 → invalidSourceSpaceClearWindowID")
    func systemEventsInvalidSourceSpace() {
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: -1000, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            sourceSpace: 0
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let decision = WindowManager.decideSystemEventsRestore(
            windowID: 42, record: record, mainScreenFrame: mainScreen
        )
        if case .invalidSourceSpaceClearWindowID(let windowID) = decision {
            #expect(windowID == 42)
        } else {
            #expect(Bool(false), "Expected .invalidSourceSpaceClearWindowID, got \(decision)")
        }
    }
```

- [ ] **Step 2: 全量测试**
Run: `swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0

- [ ] **Step 3: 独立测试脚本也通过**
Run: `bash Tests/run_all_tests.sh 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Tests/XCTest/IntegrationMockTests.swift && git commit -m "test: add sourceSpace=0 restore decision test"`
