# Bug Fix: 远程 SSH 窗口 UserPromptSubmit 无 ToggleRecord 时自动恢复失败

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** SSH 到 local-server-002 启动 Claude Code，发送提示词时窗口不会自动从主屏幕回退到副屏幕。日志显示 `restore_skipped_no_toggle_record` 或 `restore_skipped_window_not_on_main`。

**Root Cause:** `HookEventHandler.swift:449-521` 的 `validateRestoreEligibility` 要求窗口在主屏上 AND 有有效 ToggleRecord 才执行 restore。但远程 SSH 窗口在以下场景没有 ToggleRecord：

1. **窗口已在主屏时 Stop 触发** — `WindowManager+MoveWindow.swift:79-91` 的 `moveWindowToMainScreen` 检测到窗口已在主屏后提前返回，不调用 `ToggleEngine.shared.save`，不生成 ToggleRecord
2. **首次使用** — 窗口从未被 VibeFocus 移动过，无历史记录
3. **restore 清除记录后 Stop 未重建** — 上次 UPS restore 成功后清除了 ToggleRecord，但如果新 session 的 Stop 窗口已在主屏，不会重建记录

当 UserPromptSubmit 发现窗口在主屏但无 ToggleRecord 时，直接 skip，不会尝试移动窗口到副屏。

**Impact:** 所有远程 SSH session，当窗口恰好在主屏上（未被 Stop 实际移动过）时，UPS 自动恢复完全失效。

**Scope:** Small
**Risk:** Medium

**Risks:**
- Task 1 修改了 handleUserPromptSubmit 的 restore 跳过逻辑 → 缓解：仅在 validateRestoreEligibility 返回 nil 且窗口在主屏时才触发 fallback，不影响本地 session 的正常流程
- Fallback 使用默认副屏位置而非精确历史位置 → 缓解：这是"无记录"场景下最合理的默认行为，用户可通过手动 Ctrl+Q 建立精确 ToggleRecord

**Architecture:** 数据流：UserPromptSubmit → resolveWindowIdentity → validateRestoreEligibility(nil) → 检测窗口在主屏 → 查找默认副屏 → 创建 "synthetic toggle record" → 执行 restore。关键决策点：当无 ToggleRecord 时，从 `NSScreen.screens` 选择第一个非主屏作为 restore 目标，使用该屏的 visibleFrame 作为 origFrame 生成 synthetic record。

**Tech Stack:** Swift 5, XCTest (swift-testing), macOS AppKit, NSScreen

**Autonomy Level:** Full

---

### Task 1: UserPromptSubmit 添加无 ToggleRecord 时的副屏 fallback

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:260-283` (handleUserPromptSubmit 中 validateRestoreEligibility 失败后的处理)
- Modify: `Sources/Hook/HookEventHandler.swift:419-421` (RestoreValidation 结构体不需要改)
- Modify: `Sources/Toggle/ToggleEngine.swift` (添加 createSyntheticToggleRecord 方法)

- [ ] **Step 1: 给 ToggleEngine 添加 createSyntheticToggleRecord 方法 — 无历史记录时生成默认 restore 目标**

文件: `Sources/Toggle/ToggleEngine.swift`（在 `clear` 方法之后、class 结束花括号之前添加新方法）

```swift
    /// 为没有 ToggleRecord 的窗口创建合成记录 — 使用第一个非主屏作为 restore 目标
    /// 用于 UserPromptSubmit fallback：窗口在主屏但无历史位置记录时，将窗口移到副屏
    func createSyntheticToggleRecord(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?
    ) -> ToggleRecord? {
        // 找到第一个非主屏
        guard let secondaryScreen = NSScreen.screens.first(where: { $0.frame.origin != .zero }) else {
            log("[ToggleEngine] createSyntheticToggleRecord: no secondary screen found", level: .warn, fields: [
                "windowID": String(windowID),
                "screenCount": String(NSScreen.screens.count)
            ])
            return nil
        }

        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        let targetFrame = mainScreen.map { axFrame(forVisibleFrameOf: $0) }
        let origFrame = axFrame(forVisibleFrameOf: secondaryScreen)

        guard let targetFrame else { return nil }

        // origFrame 在副屏（ Quartz 坐标系），targetFrame 在主屏
        // isValid 要求 origFrame 不在主屏 && targetFrame 在主屏
        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: 0,
            sourceDisplay: 0,
            sourceYabaiDisp: .yabai(0),
            sourceDispSpace: 0,
            targetFrame: targetFrame,
            targetDisplay: 0,
            toggledAt: Date(),
            sessionID: nil
        )

        // 验证 synthetic record 的有效性
        guard let mainScreenFrame = mainScreen?.frame,
              record.isValid(mainScreenFrame: mainScreenFrame) else {
            log("[ToggleEngine] createSyntheticToggleRecord: synthetic record failed validation", level: .warn, fields: [
                "windowID": String(windowID),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
                "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y))"
            ])
            return nil
        }

        store.saveToggleRecord(record)

        log("[ToggleEngine] createSyntheticToggleRecord: saved", level: .info, fields: [
            "windowID": String(windowID),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])

        return record
    }

    private func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        // NSScreen.visibleFrame 是 Cocoa 坐标（原点左下角）
        // ToggleRecord 使用 Quartz 坐标（原点左上角），但 store 内部会处理转换
        // 这里保持与 moveWindowToMainScreen 一致的坐标系统
        return visible
    }
```

- [ ] **Step 2: 修改 handleUserPromptSubmit — 无 ToggleRecord 时创建 synthetic record 并 restore**

文件: `Sources/Hook/HookEventHandler.swift:260-283`（替换整个 `// 3. 验证是否应该 restore` guard 块）

当前代码：
```swift
        // 3. 验证是否应该 restore
        guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
            let onMainScreen = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
            let reason = onMainScreen ? "no_toggle_record" : "window_not_on_main"
            log(
                "[HookEventHandler] UserPromptSubmit: not eligible for auto-restore, skipping",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown",
                    "onMainScreen": String(onMainScreen),
                    "sessionID": payload.sessionID,
                    "reason": reason
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_skipped_\(reason)",
                    message: "Window not eligible for auto-restore (\(reason))",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

替换为：
```swift
        // 3. 验证是否应该 restore
        guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
            let onMainScreen = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)

            // Fallback: 窗口在主屏但无 ToggleRecord → 创建 synthetic record 并 restore 到副屏
            if onMainScreen {
                let engine = ToggleEngine.shared
                if let syntheticRecord = engine.createSyntheticToggleRecord(
                    windowID: identity.windowID,
                    pid: identity.pid,
                    bundleIdentifier: identity.bundleIdentifier,
                    appName: identity.appName
                ) {
                    log(
                        "[HookEventHandler] UserPromptSubmit: created synthetic toggle record, attempting restore",
                        level: .info,
                        fields: [
                            "traceID": traceID,
                            "windowID": String(identity.windowID),
                            "app": identity.appName ?? "unknown",
                            "sessionID": payload.sessionID
                        ]
                    )
                    guard let mainScreen = WindowManager.shared.getMainScreen() else {
                        return (
                            200,
                            ClaudeHookResponse(
                                ok: true, code: "restore_skipped_no_main_screen",
                                message: "Cannot determine main screen for synthetic restore",
                                sessionID: payload.sessionID, handled: false
                            )
                        )
                    }
                    let syntheticValidation = RestoreValidation(record: syntheticRecord, mainScreen: mainScreen)
                    let success = executeRestore(
                        identity: identity,
                        validation: syntheticValidation,
                        traceID: traceID,
                        startedAt: handleStartedAt,
                        sessionID: payload.sessionID
                    )
                    if success {
                        lastAutoRestoreByWindowID[identity.windowID] = Date()
                        SessionWindowRegistry.shared.reactivate(sessionID: payload.sessionID)
                    }
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: success ? "restored_synthetic" : "restore_failed",
                            message: success ? "Window restored to secondary screen (synthetic record)" : "Synthetic restore attempt failed",
                            sessionID: payload.sessionID,
                            handled: success
                        )
                    )
                }

                // 无法创建 synthetic record（无副屏或验证失败）
                log(
                    "[HookEventHandler] UserPromptSubmit: on main screen, no toggle record, synthetic record creation failed",
                    fields: [
                        "traceID": traceID,
                        "windowID": String(identity.windowID),
                        "app": identity.appName ?? "unknown",
                        "sessionID": payload.sessionID,
                        "reason": "no_toggle_record_no_secondary_screen"
                    ]
                )
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true, code: "restore_skipped_no_toggle_record",
                        message: "Window on main screen but no toggle record and no secondary screen available",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }

            // 窗口不在主屏 → 正常 skip（窗口已在副屏，无需 restore）
            log(
                "[HookEventHandler] UserPromptSubmit: not eligible for auto-restore, skipping",
                fields: [
                    "traceID": traceID,
                    "windowID": String(identity.windowID),
                    "app": identity.appName ?? "unknown",
                    "onMainScreen": String(onMainScreen),
                    "sessionID": payload.sessionID,
                    "reason": "window_not_on_main"
                ]
            )
            return (
                200,
                ClaudeHookResponse(
                    ok: true, code: "restore_skipped_window_not_on_main",
                    message: "Window not on main screen, no restore needed",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }
```

- [ ] **Step 3: 质量门禁 — 编译检查**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`

Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

---

### Task 2: 全量测试 + 验证 + 提交

**Depends on:** Task 1
**Files:** None (commands only)

- [ ] **Step 1: 全量回归测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | tail -30`

Expected:
  - Exit code: 0
  - Output contains: "Test Suite" and "passed"
  - Output does NOT contain: "failed"

- [ ] **Step 2: 构建并部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -20`

Expected:
  - Exit code: 0
  - VibeFocus.app 构建成功并启动

- [ ] **Step 3: 验证 — SSH 到 local-server-002 测试 UPS 自动恢复**

测试步骤：
1. SSH 到 local-server-002
2. 启动 Claude Code
3. 发送提示词
4. 观察终端窗口是否从主屏幕自动移动到副屏幕

检查日志确认 synthetic record 路径被触发：

Run: `grep -E "(createSyntheticToggleRecord|restored_synthetic|restore_skipped_no_toggle)" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10`

Expected:
  - 如果窗口在主屏无 ToggleRecord → 包含 `createSyntheticToggleRecord: saved` 和 `restored_synthetic`
  - 如果窗口有 ToggleRecord → 走正常 restore 路径（不包含 synthetic 相关日志）

- [ ] **Step 4: 质量门禁 — 代码整洁检查**

手工检查（AI 自行验证）：
- [ ] 无遗留 debug 语句（print/console.log）
- [ ] 无 TODO/FIXME
- [ ] 无被注释掉的代码
- [ ] 无未使用的 import

- [ ] **Step 5: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Hook/HookEventHandler.swift Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
fix(ups): add synthetic toggle record fallback for remote SSH windows

When UserPromptSubmit fires for a window on the main screen with no
ToggleRecord, create a synthetic record targeting the first secondary
screen and restore the window there. This fixes auto-restore for remote
SSH sessions where the Stop event didn't create a record (window already
on main screen, first use, or record cleared by previous restore).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
