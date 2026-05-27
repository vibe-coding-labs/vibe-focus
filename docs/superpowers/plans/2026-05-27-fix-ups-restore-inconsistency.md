# Bug Fix: UserPromptSubmit auto-restore 对大多数远程 iTerm2 窗口无效

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 部分 iTerm2 窗口 UserPromptSubmit 能 restore、大部分不能。日志显示 83%（419/506）的 UPS 请求返回 `restore_skipped_window_not_on_main`

**Root Cause:** `validateRestoreEligibility` 要求窗口必须在主屏上才执行 restore。但远程 session 的窗口 208 在 Stop 事件移动它之前不在主屏上（已经在原始 space），导致 UPS 无法 restore。同时 `resolveWindow` 的 fallback 逻辑可能解析到错误的 iTerm2 窗口

**Impact:** 所有远程 SSH session（共享 window 208）的 UPS auto-restore 都受影响。本地 session（独占窗口）不受影响

**Scope:** Small
**Risk:** Medium — 修改 restore 决策逻辑，需要确保不会恢复已在正确位置的窗口

---

### Task 1: 移除 validateRestoreEligibility 的 onMainScreen 前置条件 — 让 UPS 能 restore 不在主屏的窗口

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/HookEventHandler.swift:448-515`（validateRestoreEligibility 方法）
- Modify: `Sources/Hook/HookEventHandler.swift:254-277`（handleUserPromptSubmit 中的 reason 计算）

- [ ] **Step 1: 修改 validateRestoreEligibility 移除 onMainScreen guard**

文件: `Sources/Hook/HookEventHandler.swift:460-472`（删除 onMainScreen 检查）

将 `validateRestoreEligibility` 中的 onMainScreen 检查移除。当前逻辑：

```swift
// 窗口必须在主屏上
let onMainScreen = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
guard onMainScreen else {
    log(...)
    return nil
}
```

修改后：删除这段 guard。restore 操作本身会检查窗口当前位置并正确处理。如果窗口不在主屏上但有一个有效的 ToggleRecord（说明窗口曾经在主屏上被 toggle 过），应该允许 restore 把它放回原始位置。

```swift
private func validateRestoreEligibility(
    identity: WindowIdentity,
    traceID: String
) -> RestoreValidation? {
    // 防止与手动热键 toggle 冲突
    if HotKeyManager.shared.isToggleInFlight {
        log(
            "[HookEventHandler] validateRestoreEligibility: toggle in flight, skipping",
            level: .debug,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID)
            ]
        )
        return nil
    }

    // 必须有有效的 toggle record
    let engine = ToggleEngine.shared
    guard let record = engine.load(windowID: identity.windowID) else {
        log(
            "[HookEventHandler] validateRestoreEligibility: no toggle record found",
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )
        return nil
    }

    // record 必须通过验证
    guard let mainScreen = WindowManager.shared.getMainScreen(),
          record.isValid(mainScreenFrame: mainScreen.frame) else {
        log(
            "[HookEventHandler] validateRestoreEligibility: toggle record failed validation",
            level: .warn,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "sourceSpace": String(record.sourceSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
            ]
        )
        return nil
    }

    log(
        "[HookEventHandler] validateRestoreEligibility: eligible for restore",
        fields: [
            "traceID": traceID,
            "windowID": String(identity.windowID),
            "sourceSpace": String(record.sourceSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ]
    )

    // mainScreen 用于 RestoreValidation（即使窗口不在主屏上也需要 mainScreen frame）
    guard let mainScreen = WindowManager.shared.getMainScreen() else {
        log(
            "[HookEventHandler] validateRestoreEligibility: cannot get main screen",
            level: .error,
            fields: ["traceID": traceID]
        )
        return nil
    }

    return RestoreValidation(record: record, mainScreen: mainScreen)
}
```

注意：上面的代码有两个 `guard let mainScreen` — 需要合并。正确的完整方法如下：

```swift
private func validateRestoreEligibility(
    identity: WindowIdentity,
    traceID: String
) -> RestoreValidation? {
    // 防止与手动热键 toggle 冲突
    if HotKeyManager.shared.isToggleInFlight {
        log(
            "[HookEventHandler] validateRestoreEligibility: toggle in flight, skipping",
            level: .debug,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID)
            ]
        )
        return nil
    }

    // 必须有有效的 toggle record
    let engine = ToggleEngine.shared
    guard let record = engine.load(windowID: identity.windowID) else {
        log(
            "[HookEventHandler] validateRestoreEligibility: no toggle record found",
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )
        return nil
    }

    // record 必须通过验证
    guard let mainScreen = WindowManager.shared.getMainScreen(),
          record.isValid(mainScreenFrame: mainScreen.frame) else {
        log(
            "[HookEventHandler] validateRestoreEligibility: toggle record failed validation",
            level: .warn,
            fields: [
                "traceID": traceID,
                "windowID": String(identity.windowID),
                "sourceSpace": String(record.sourceSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
            ]
        )
        return nil
    }

    log(
        "[HookEventHandler] validateRestoreEligibility: eligible for restore",
        fields: [
            "traceID": traceID,
            "windowID": String(identity.windowID),
            "sourceSpace": String(record.sourceSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ]
    )

    return RestoreValidation(record: record, mainScreen: mainScreen)
}
```

- [ ] **Step 2: 更新 decideRestoreEligibility 纯函数 — 移除 isWindowOnMainScreen 参数**

文件: `Sources/Hook/HookEventHandler.swift:428-441`（decideRestoreEligibility 方法）

移除 `isWindowOnMainScreen` 参数和对应的检查：

```swift
/// Pure decision logic for validateRestoreEligibility.
static func decideRestoreEligibility(
    isToggleInFlight: Bool,
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
```

同时更新 `RestoreEligibility` 枚举，移除 `windowNotOnMainScreen` case：

```swift
enum RestoreEligibility {
    case eligible(record: ToggleRecord, mainScreenFrame: CGRect)
    case toggleInFlight
    case noRecord
    case recordInvalid(windowID: UInt32)
}
```

- [ ] **Step 3: 更新 handleUserPromptSubmit 中的 reason 计算**

文件: `Sources/Hook/HookEventHandler.swift:254-277`（validateRestoreEligibility 返回 nil 时的 reason 计算）

当前代码使用 `onMainScreen` 判断 reason：

```swift
guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
    let onMainScreen = WindowManager.shared.isWindowOnMainScreen(windowID: identity.windowID)
    let reason = onMainScreen ? "no_toggle_record" : "window_not_on_main"
    ...
}
```

修改为：移除 `onMainScreen` 查询，统一使用 `no_toggle_record` 作为 reason：

```swift
guard let validation = validateRestoreEligibility(identity: identity, traceID: traceID) else {
    log(
        "[HookEventHandler] UserPromptSubmit: not eligible for auto-restore, skipping",
        fields: [
            "traceID": traceID,
            "windowID": String(identity.windowID),
            "app": identity.appName ?? "unknown",
            "sessionID": payload.sessionID,
            "reason": "no_toggle_record"
        ]
    )
    return (
        200,
        ClaudeHookResponse(
            ok: true, code: "restore_skipped_no_toggle_record",
            message: "Window not eligible for auto-restore (no_toggle_record)",
            sessionID: payload.sessionID, handled: false
        )
    )
}
```

- [ ] **Step 4: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 部署并验证**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Contains "构建成功" or similar success indicator

然后验证 UPS restore 不再被 onMainScreen 阻止：
Run: `kill $(pgrep -f "VibeFocus.app/Contents/MacOS/VibeFocus") 2>/dev/null; sleep 1; open /Applications/VibeFocus.app; sleep 2 && curl -s -X POST "http://127.0.0.1:39277/claude/hook?token=1d9df73f1b8c43aeb465a937c0c51981" -H "Content-Type: application/json" -H "X-VibeFocus-Token: 1d9df73f1b8c43aeb465a937c0c51981" -d '{"hook_event_name":"UserPromptSubmit","session_id":"ups-restore-test","cwd":"/home/test","terminal_ctx":{"machine_label":"local-server-002"}}' | python3 -m json.tool`
Expected:
  - Response code is NOT "restore_skipped_window_not_on_main"
  - Response code is one of: "restored", "restore_skipped_no_toggle_record", "cooldown_active"

- [ ] **Step 6: 提交**
Run: `git add Sources/Hook/HookEventHandler.swift && git commit -m "fix(hook): remove onMainScreen guard from UPS auto-restore — restore windows regardless of current screen position"`

---

### Task 2: 更新 decideRestoreEligibility 测试 — 移除 isWindowOnMainScreen 参数

**Depends on:** Task 1
**Files:**
- Modify: `Tests/XCTest/StopDebounceAndCooldownTests.swift`（如有相关测试）
- Modify: `Tests/XCTest/WindowMoveDecisionTests.swift`（如有相关测试）

- [ ] **Step 1: 检查并更新所有调用 decideRestoreEligibility 的测试**

Run: `grep -rn "decideRestoreEligibility" Tests/`

Expected: 找到所有测试文件中的调用，确保 `isWindowOnMainScreen` 参数已移除

如果有测试使用了 `isWindowOnMainScreen` 参数，更新为新的签名。

- [ ] **Step 2: 检查 RestoreEligibility 的 windowNotOnMainScreen case 是否有测试引用**

Run: `grep -rn "windowNotOnMainScreen" Tests/`

Expected: 0 results（该 case 已被移除）

- [ ] **Step 3: 运行全量测试**
Run: `swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - All tests pass

- [ ] **Step 4: 提交**
Run: `git add Tests/ && git commit -m "test: update decideRestoreEligibility tests for removed onMainScreen parameter"`
