# Toggle Engine 重写 — 单一事实来源 + 确定性恢复

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 重写 toggle/restore 引擎，用单一数据结构 + 单一存储位置 + 确定性查找替代当前的 12 个状态位置 / 11 种标识符 / 17 个静默跳过条件。

**Architecture:** Ctrl+Q 按下时，ToggleEngine 原子性地保存 (windowID, 原始 frame, sourceSpace, sourceDisplay, sourceYabaiDisp, sourceDispSpace) 到 SQLite `windows` 表。UserPromptSubmit 到达时，ToggleEngine 直接用 windowID 查 SQLite 获取完整恢复信息（不需要 PID/TTY/PPID 猜测），执行 restore（frame + space 切换）。去掉了所有内存缓存、fallback 链、多层验证。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite3 (C API), yabai CLI, AX/CG macOS APIs

**Risks:**
- Task 3 是核心改动，改了 SessionWindowRegistry 的接口 → 缓解：保持旧接口签名，内部重写
- Task 5 改 HookEventHandler 恢复链路 → 缓解：新路径先作为并行逻辑，旧路径保留直到验证通过
- Space 切换依赖 yabai，yabai 不可用时 restore 仍然执行 frame 恢复，只是不切 space

---

### Task 1: 定义 ToggleRecord 数据模型 — 替代散落的 5 个状态结构

**Depends on:** None
**Files:**
- Modify: `Sources/ClaudeHookModels.swift:42-133`

- [ ] **Step 1: 在 ClaudeHookModels.swift 中添加 ToggleRecord 结构体**

在 `WindowState` 结构体之后（约 line 133）添加：

```swift
/// Toggle 操作的完整快照 — 单一事实来源
/// Ctrl+Q 按下时原子性保存，Restore 时直接读取，不需要任何猜测
struct ToggleRecord: Codable, Equatable {
    // MARK: - 窗口身份（恢复时用于查找窗口）
    let windowID: UInt32          // CGWindowNumber
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String?

    // MARK: - 原始位置（恢复目标）
    let origFrame: CGRect         // 窗口原始 frame（坐标相对于 sourceDisplay）
    let sourceSpace: Int          // yabai 全局 space index（如 2, 3, 4, 5）
    let sourceDisplay: Int        // NSScreen index（1=main, 2/3=secondary）
    let sourceYabaiDisp: Int      // yabai display index（与 yabai query --displays 对应）
    let sourceDispSpace: Int      // display-local space index（该 display 上的第几个 space）

    // MARK: - 目标位置（用于验证窗口确实被 toggle 了）
    let targetFrame: CGRect       // 主屏上的 frame
    let targetDisplay: Int        // 主屏的 display index

    // MARK: - 元数据
    let toggledAt: Date
    let sessionID: String?

    // MARK: - 便捷方法

    /// toggle state 是否有效（origFrame 不在主屏上，targetFrame 在主屏上）
    func isValid(mainScreenFrame: CGRect) -> Bool {
        let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
        let tgtCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        // 原始位置不在主屏，目标位置在主屏 → 合法
        return !mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }

    /// 窗口当前位置是否在 targetFrame 附近（容差 150px）
    func isNearTarget(currentFrame: CGRect, tolerance: CGFloat = 150) -> Bool {
        abs(currentFrame.origin.x - targetFrame.origin.x) <= tolerance &&
        abs(currentFrame.origin.y - targetFrame.origin.y) <= tolerance
    }
}
```

- [ ] **Step 2: 给 CGRect 添加 Codable 支持（如果还没有）**

在 `ToggleRecord` 之后添加 extension：

```swift
extension CGRect: @retroactive Codable {
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try c.decode(CGFloat.self, forKey: .x),
            y: try c.decode(CGFloat.self, forKey: .y),
            width: try c.decode(CGFloat.self, forKey: .width),
            height: try c.decode(CGFloat.self, forKey: .height)
        )
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin.x, forKey: .x)
        try c.encode(origin.y, forKey: .y)
        try c.encode(size.width, forKey: .width)
        try c.encode(size.height, forKey: .height)
    }
}
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**
Run: `git add Sources/ClaudeHookModels.swift && git commit -m "refactor(models): add ToggleRecord as single source of truth for toggle state"`

---

### Task 2: 给 WindowStateStore 添加 ToggleRecord 读写方法

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowStateStore.swift`

- [ ] **Step 1: 在 WindowStateStore 中添加 saveToggleRecord 方法**

在 WindowStateStore 类的 `saveWindowState` 方法之后添加：

```swift
// MARK: - ToggleRecord Persistence (Single Source of Truth)

/// 原子性保存 toggle record 到 windows 表
/// 覆盖 orig/target frame + space/display 信息，其他字段保持不变
func saveToggleRecord(_ record: ToggleRecord) {
    let now = Date().timeIntervalSince1970
    var stmt: OpaquePointer?

    // 先尝试 UPDATE
    let updateSQL = """
        UPDATE windows SET
            orig_x = ?, orig_y = ?, orig_w = ?, orig_h = ?,
            target_x = ?, target_y = ?, target_w = ?, target_h = ?,
            source_space = ?, source_display = ?,
            source_yabai_disp = ?, source_disp_space = ?,
            target_display = ?,
            toggle_reason = 'manual_hotkey',
            toggled_at = ?,
            session_id = ?,
            updated_at = ?
        WHERE window_id = ?
    """

    guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
        log("saveToggleRecord prepare failed", level: .error, fields: [
            "error": String(cString: sqlite3_errmsg(db))
        ])
        return
    }

    sqlite3_bind_double(stmt, 1, Double(record.origFrame.origin.x))
    sqlite3_bind_double(stmt, 2, Double(record.origFrame.origin.y))
    sqlite3_bind_double(stmt, 3, Double(record.origFrame.size.width))
    sqlite3_bind_double(stmt, 4, Double(record.origFrame.size.height))
    sqlite3_bind_double(stmt, 5, Double(record.targetFrame.origin.x))
    sqlite3_bind_double(stmt, 6, Double(record.targetFrame.origin.y))
    sqlite3_bind_double(stmt, 7, Double(record.targetFrame.size.width))
    sqlite3_bind_double(stmt, 8, Double(record.targetFrame.size.height))
    sqlite3_bind_int(stmt, 9, Int32(record.sourceSpace))
    sqlite3_bind_int(stmt, 10, Int32(record.sourceDisplay))
    sqlite3_bind_int(stmt, 11, Int32(record.sourceYabaiDisp))
    sqlite3_bind_int(stmt, 12, Int32(record.sourceDispSpace))
    sqlite3_bind_int(stmt, 13, Int32(record.targetDisplay))
    sqlite3_bind_double(stmt, 14, record.toggledAt.timeIntervalSince1970)
    if let sid = record.sessionID, !sid.isEmpty {
        sqlite3_bind_text(stmt, 15, sid, -1, nil)
    } else {
        sqlite3_bind_null(stmt, 15)
    }
    sqlite3_bind_double(stmt, 16, now)
    sqlite3_bind_int64(stmt, 17, Int64(record.windowID))

    let result = sqlite3_step(stmt)
    sqlite3_finalize(stmt)

    if result != SQLITE_DONE {
        log("saveToggleRecord update failed", level: .error, fields: [
            "error": String(cString: sqlite3_errmsg(db)),
            "windowID": String(record.windowID)
        ])
    }

    log("saveToggleRecord saved", level: .info, fields: [
        "windowID": String(record.windowID),
        "sourceSpace": String(record.sourceSpace),
        "sourceDisplay": String(record.sourceDisplay),
        "sourceYabaiDisp": String(record.sourceYabaiDisp),
        "sourceDispSpace": String(record.sourceDispSpace),
        "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
        "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
    ])
}

/// 按 windowID 读取 toggle record
/// 返回 nil 如果不存在或没有 toggle state
func loadToggleRecord(windowID: UInt32) -> ToggleRecord? {
    var stmt: OpaquePointer?
    let sql = """
        SELECT window_id, pid, bundle_id, app_name,
               orig_x, orig_y, orig_w, orig_h,
               target_x, target_y, target_w, target_h,
               source_space, source_display, source_yabai_disp, source_disp_space,
               target_display, toggled_at, session_id
        FROM windows
        WHERE window_id = ? AND toggle_reason IS NOT NULL AND orig_x IS NOT NULL
    """

    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int64(stmt, 1, Int64(windowID))

    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

    let wID = UInt32(sqlite3_column_int64(stmt, 0))
    let pid = sqlite3_column_int(stmt, 1)
    let bundleID: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
    let appName: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

    let ox = CGFloat(sqlite3_column_double(stmt, 4))
    let oy = CGFloat(sqlite3_column_double(stmt, 5))
    let ow = CGFloat(sqlite3_column_double(stmt, 6))
    let oh = CGFloat(sqlite3_column_double(stmt, 7))
    let tx = CGFloat(sqlite3_column_double(stmt, 8))
    let ty = CGFloat(sqlite3_column_double(stmt, 9))
    let tw = CGFloat(sqlite3_column_double(stmt, 10))
    let th = CGFloat(sqlite3_column_double(stmt, 11))

    let sourceSpace = Int(sqlite3_column_int(stmt, 12))
    let sourceDisplay = Int(sqlite3_column_int(stmt, 13))
    let sourceYabaiDisp = Int(sqlite3_column_int(stmt, 14))
    let sourceDispSpace = Int(sqlite3_column_int(stmt, 15))
    let targetDisplay = Int(sqlite3_column_int(stmt, 16))
    let toggledAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
    let sessionID: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

    return ToggleRecord(
        windowID: wID,
        pid: pid,
        bundleIdentifier: bundleID,
        appName: appName,
        origFrame: CGRect(x: ox, y: oy, width: ow, height: oh),
        sourceSpace: sourceSpace,
        sourceDisplay: sourceDisplay,
        sourceYabaiDisp: sourceYabaiDisp,
        sourceDispSpace: sourceDispSpace,
        targetFrame: CGRect(x: tx, y: ty, width: tw, height: th),
        targetDisplay: targetDisplay,
        toggledAt: toggledAt,
        sessionID: sessionID
    )
}

/// 清除指定窗口的 toggle state
func clearToggleRecord(windowID: UInt32) {
    let sql = """
        UPDATE windows SET
            orig_x = NULL, orig_y = NULL, orig_w = NULL, orig_h = NULL,
            target_x = NULL, target_y = NULL, target_w = NULL, target_h = NULL,
            source_space = NULL, source_display = NULL,
            source_yabai_disp = NULL, source_disp_space = NULL,
            target_display = NULL,
            toggle_reason = NULL, toggled_at = NULL,
            updated_at = ?
        WHERE window_id = ?
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
    sqlite3_bind_int64(stmt, 2, Int64(windowID))
    sqlite3_step(stmt)

    log("clearToggleRecord cleared", fields: ["windowID": String(windowID)])
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowStateStore.swift && git commit -m "refactor(store): add ToggleRecord read/write/clear methods to WindowStateStore"`

---

### Task 3: 创建 ToggleEngine — 替代 SessionWindowRegistry 的 toggle 逻辑

**Depends on:** Task 2
**Files:**
- Create: `Sources/ToggleEngine.swift`

- [ ] **Step 1: 创建 ToggleEngine.swift — 核心 toggle/restore 引擎**

```swift
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

/// Toggle Engine — 窗口 toggle/restore 的单一入口
///
/// 设计原则：
/// 1. 单一事实来源：所有 toggle state 只存 SQLite `windows` 表，不缓存到内存
/// 2. 确定性查找：用 windowID 直接查 SQLite，不走 PID/TTY/PPID 猜测链
/// 3. 原子操作：save 是一次 SQLite UPDATE，read 是一次 SELECT
@MainActor
final class ToggleEngine {

    static let shared = ToggleEngine()
    private init() {}

    private var store: WindowStateStore { WindowStateStore.shared }

    // MARK: - Save (Ctrl+Q 触发)

    /// 保存 toggle 快照
    /// 在 moveWindowToMainScreen 成功后调用，保存完整的原始位置信息
    func save(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: Int,
        sourceDisplay: Int,
        sourceYabaiDisp: Int,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        sessionID: String?
    ) {
        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace,
            sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )

        store.saveToggleRecord(record)

        log("ToggleEngine.save", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(sourceSpace),
            "sourceDisplay": String(sourceDisplay),
            "sourceYabaiDisp": String(sourceYabaiDisp),
            "sourceDispSpace": String(sourceDispSpace),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])
    }

    // MARK: - Load (UserPromptSubmit 触发)

    /// 按 windowID 读取 toggle record
    /// 返回 nil 如果不存在或已被清除
    func load(windowID: UInt32) -> ToggleRecord? {
        return store.loadToggleRecord(windowID: windowID)
    }

    // MARK: - Clear (Restore 后或窗口关闭时)

    /// 清除 toggle state
    func clear(windowID: UInt32) {
        store.clearToggleRecord(windowID: windowID)
        log("ToggleEngine.clear", fields: ["windowID": String(windowID)])
    }

    // MARK: - Restore 执行

    /// 执行恢复：移动窗口回原始位置 + 切换到原始 space
    /// 返回 true 表示恢复成功
    @discardableResult
    func restore(windowID: UInt32, triggerSource: String) -> Bool {
        guard let record = load(windowID: windowID) else {
            log("ToggleEngine.restore: no toggle record found", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            return false
        }

        log("ToggleEngine.restore: starting", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(record.sourceSpace),
            "sourceDisplay": String(record.sourceDisplay),
            "triggerSource": triggerSource
        ])

        let wm = WindowManager.shared

        // 1. 找到窗口 AX element
        guard let windowAX = wm.findWindowAXElement(
            pid: record.pid,
            windowID: record.windowID,
            bundleIdentifier: record.bundleIdentifier,
            appName: record.appName
        ) else {
            log("ToggleEngine.restore: window AX element not found", level: .warn, fields: [
                "windowID": String(windowID),
                "pid": String(record.pid)
            ])
            clear(windowID: windowID)
            return false
        }

        // 2. 获取当前 frame（验证用）
        guard let currentFrame = wm.frame(of: windowAX) else {
            log("ToggleEngine.restore: cannot get current frame", level: .warn)
            clear(windowID: windowID)
            return false
        }

        // 3. 验证窗口确实在 target 位置附近（说明确实被 toggle 过）
        if !record.isNearTarget(currentFrame: currentFrame) {
            log("ToggleEngine.restore: window moved from target, clearing stale state", level: .warn, fields: [
                "windowID": String(windowID),
                "currentX": String(Int(currentFrame.origin.x)),
                "currentY": String(Int(currentFrame.origin.y)),
                "targetX": String(Int(record.targetFrame.origin.x)),
                "targetY": String(Int(record.targetFrame.origin.y))
            ])
            clear(windowID: windowID)
            return false
        }

        // 4. 设置恢复 frame
        let restored = wm.apply(frame: record.origFrame, to: windowAX)
        if !restored {
            log("ToggleEngine.restore: frame apply failed", level: .error)
            clear(windowID: windowID)
            return false
        }

        // 5. 切换到原始 space（如果需要）
        switchToOriginalSpace(record: record, windowAX: windowAX, triggerSource: triggerSource)

        // 6. 清除 toggle state（一次性操作）
        clear(windowID: windowID)

        log("ToggleEngine.restore: success", level: .info, fields: [
            "windowID": String(windowID),
            "restoredTo": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
        ])
        return true
    }

    // MARK: - Space Switching

    /// 切换到窗口的原始 space
    private func switchToOriginalSpace(record: ToggleRecord, windowAX: AXUIElement, triggerSource: String) {
        let spaceController = SpaceController.shared

        // 获取窗口当前所在的 space
        guard let currentSpace = spaceController.queryWindowSpace(windowID: record.windowID) else {
            log("ToggleEngine.switchToOriginalSpace: cannot query current space", level: .debug)
            return
        }

        let targetSpace = record.sourceSpace
        guard currentSpace != targetSpace else {
            log("ToggleEngine.switchToOriginalSpace: already on target space", level: .debug, fields: [
                "space": String(targetSpace)
            ])
            return
        }

        log("ToggleEngine.switchToOriginalSpace: switching", fields: [
            "from": String(currentSpace),
            "to": String(targetSpace),
            "method": "NativeSpaceBridge"
        ])

        // 使用 NativeSpaceBridge 移动窗口到目标 space
        let moved = NativeSpaceBridge.moveWindow(
            record.windowID,
            toSpace: Int64(targetSpace)
        )

        if !moved {
            // Fallback: 用 yabai
            log("ToggleEngine.switchToOriginalSpace: NativeSpaceBridge failed, trying yabai", level: .warn)
            spaceController.moveWindowToSpace(
                windowID: record.windowID,
                targetSpace: targetSpace,
                yabaiDisplay: record.sourceYabaiDisp,
                displayLocalSpace: record.sourceDispSpace
            )
        }

        // 等待 space 切换动画完成
        usleep(150_000)

        // 如果是 hotkey 触发，也把用户视角切到目标 space
        if triggerSource == "carbon_hotkey" {
            let steps = targetSpace - currentSpace
            if steps != 0 {
                _ = NativeSpaceBridge.focusSpace(steps: steps)
                usleep(400_000)
            }
        }

        // Space 切换后重新应用 frame（防止 space 切换导致位置偏移）
        let wm = WindowManager.shared
        _ = wm.apply(frame: record.origFrame, to: windowAX)
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"
  - 注意：可能需要调整 `findWindowAXElement` 和 `apply(frame:to:)` 的调用方式，因为它们可能是 private 的。如果编译失败，需要将这两个方法改为 internal 或添加 wrapper。

- [ ] **Step 3: 提交**
Run: `git add Sources/ToggleEngine.swift && git commit -m "feat(engine): create ToggleEngine as single entry point for toggle/restore"`

---

### Task 4: 在 HookEventHandler 中集成 ToggleEngine 的 restore 路径

**Depends on:** Task 3
**Files:**
- Modify: `Sources/HookEventHandler.swift:97-342`

- [ ] **Step 1: 修改 handleUserPromptSubmit — 使用 ToggleEngine.restore 替代旧的 restore 链路**

文件: `Sources/HookEventHandler.swift`（替换 handleUserPromptSubmit 中 lines 219-249 的 toggle state 查找和恢复逻辑）

找到这段代码（约 line 219-249）：
```swift
        // 按 windowID 直接查找 toggle state
        if let toggleState = SessionWindowRegistry.shared.findState(windowID: identity.windowID) {
            if toggleState.hasToggleState {
                guard let mainScreen = wm.getMainScreen() else {
                    return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
                }
                if !toggleState.isCorrupted(mainScreenFrame: mainScreen.frame) {
                    return performRestoreFromState(
                        payload: payload, toggleState: toggleState
                    )
                } else {
                    SessionWindowRegistry.shared.clearToggleState(windowID: identity.windowID)
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no toggle state found",
```

替换为：

```swift
        // 新路径：直接用 ToggleEngine 查 SQLite，不走内存缓存
        let engine = ToggleEngine.shared
        if let record = engine.load(windowID: identity.windowID) {
            guard let mainScreen = wm.getMainScreen() else {
                return (200, ClaudeHookResponse(ok: true, code: "no_main_screen", message: "No main screen", sessionID: payload.sessionID, handled: false))
            }

            if record.isValid(mainScreenFrame: mainScreen.frame) {
                let success = engine.restore(
                    windowID: identity.windowID,
                    triggerSource: "user_prompt_submit"
                )
                if success {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restored",
                            message: "Window restored to original position",
                            sessionID: payload.sessionID,
                            handled: true
                        )
                    )
                } else {
                    return (
                        200,
                        ClaudeHookResponse(
                            ok: true,
                            code: "restore_failed",
                            message: "Restore attempt failed",
                            sessionID: payload.sessionID,
                            handled: false
                        )
                    )
                }
            } else {
                // corrupted state（两个 frame 都在主屏），清除
                engine.clear(windowID: identity.windowID)
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no toggle state found",
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/HookEventHandler.swift && git commit -m "feat(hook): integrate ToggleEngine restore path in handleUserPromptSubmit"`

---

### Task 5: 在 moveWindowToMainScreen 中集成 ToggleEngine 的 save 路径

**Depends on:** Task 3
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift`

- [ ] **Step 1: 在 moveWindowToMainScreen 成功后添加 ToggleEngine.save 调用**

文件: `Sources/WindowManager+MoveWindow.swift`（在 moveWindowToMainScreen 方法中，找到 session window state 保存位置，约 line 360-411 附近，在现有 `updateToggleState` 调用之后添加）

找到 `SessionWindowRegistry.shared.updateToggleState(` 调用位置（约 line 382-411），在其后添加：

```swift
        // 新路径：同时保存到 ToggleEngine（单一事实来源）
        ToggleEngine.shared.save(
            windowID: currentWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: currentFrame,
            sourceSpace: spaceContext.sourceSpaceIndex ?? 0,
            sourceDisplay: sourceContext.index,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? 0,
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex,
            sessionID: sessionID
        )
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowManager+MoveWindow.swift && git commit -m "feat(move): integrate ToggleEngine save in moveWindowToMainScreen"`

---

### Task 6: 构建、部署和端到端验证

**Depends on:** Task 4, Task 5
**Files:**
- None (验证 only)

- [ ] **Step 1: 完整构建并部署**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete" or "signed" or "copied"

- [ ] **Step 2: 重启 VibeFocus 并验证 hook server 监听**
Run: `killall VibeFocus 2>/dev/null; sleep 2; open /Applications/VibeFocus.app && sleep 3 && lsof -i :39277 -P 2>/dev/null | grep LISTEN`
Expected:
  - Output contains: "VibeFocus" and "LISTEN"

- [ ] **Step 3: 手动触发 Ctrl+Q toggle 并检查 SQLite 数据**
Run: `echo "Press Ctrl+Q on a terminal window, then run:" && echo "sqlite3 ~/.vibefocus/vibefocus.db \"SELECT window_id, source_space, source_display, source_yabai_disp, source_disp_space, target_display, orig_x, orig_y FROM windows WHERE toggle_reason IS NOT NULL ORDER BY updated_at DESC LIMIT 5;\""`
Expected:
  - source_space, source_display, source_yabai_disp, source_disp_space 全部有值（不再是 NULL）
  - orig_x, orig_y 是副屏坐标

- [ ] **Step 4: 提交所有剩余改动**
Run: `git add -A && git commit -m "feat(toggle): ToggleEngine rewrite complete — single source of truth, deterministic restore"`
