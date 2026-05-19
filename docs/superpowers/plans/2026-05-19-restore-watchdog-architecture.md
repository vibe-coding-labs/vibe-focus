# Restore Watchdog Architecture — 彻底消除 yabai 异步干扰

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在 restore 完成后建立持续监控机制（watchdog），当 yabai 异步撤销 restore 操作时自动重新应用，从根本上消除 37 天 31 次修复的循环。

**Architecture:**

```
restore() 完成后
  ↓
启动 RestoreWatchdog（GCD timer，间隔 200ms）
  ↓
每次 tick：
  1. 查询 yabai 窗口状态（display/space/float/frame）
  2. 与 restore 目标比较
  3. 不匹配 → 重新 setWindowFloat + apply(frame)
  4. 连续 5 次 tick 都匹配 → 确认稳定，停止 watchdog
  5. 超时 3 秒未稳定 → 记录警告并停止
```

数据流：`ToggleEngine.restore()` 完成后 → 调用 `RestoreWatchdog.startMonitoring()` → watchdog 持续查询 yabai → 发现偏移自动修正 → 3-5 次确认后自动停止

关键组件：
- `RestoreWatchdog`（新文件）— 轻量监控器，GCD timer 驱动，职责单一
- `ToggleEngine.restore()` — 末尾启动 watchdog（修改约 5 行代码）
- 不修改 SpaceController、NativeSpaceBridge 等低层模块

**Tech Stack:** Swift 5.9, GCD DispatchSourceTimer, yabai CLI query, AX API

**Risks:**
- yabai query 有延迟（~5-10ms/次），watchdog 200ms 间隔不会有性能问题
- 如果 yabai 持续反复撤销（极端情况），watchdog 最多运行 3 秒后放弃
- 跨线程安全：watchdog 在 MainActor 上运行，与 UI 线程一致

**Autonomy Level:** Full

---

## Type Detection

**Plan Type:** Bug Fix
**Scope:** Medium
**Risk:** Medium
**Detection Reason:** 这是修复一个反复出现的 restore bug，根本原因是 yabai 异步干扰。方案是添加 post-restore 持续监控。

---

## Pre-Planning Analysis

**Feature:** RestoreWatchdog — post-restore 持续监控 + 自动修正
**Scope:** 单一子系统（ToggleEngine restore 后处理）
**Files Create:**
- `Sources/Toggle/RestoreWatchdog.swift`

**Files Modify:**
- `Sources/Toggle/ToggleEngine.swift:417-433`（restore 方法末尾，启动 watchdog）
- `Sources/Toggle/ToggleEngine.swift:1-10`（import 如果需要）

**Tasks:** 2 tasks
**Order:** Task 1（创建 watchdog）→ Task 2（集成到 restore）
**Risks:** Task 2 集成点只有 5 行代码，风险极低

---

## Task 1: 创建 RestoreWatchdog — post-restore 持续监控器

**Depends on:** None
**Files:**
- Create: `Sources/Toggle/RestoreWatchdog.swift`

- [ ] **Step 1: 创建 RestoreWatchdog.swift — restore 后持续监控窗口状态并自动修正**

```swift
import Foundation

/// restore 后的持续监控器
/// 解决核心问题：yabai 异步 tiling 引擎可能在 restore 完成后撤销操作
/// watchdog 持续检查窗口状态，发现偏移自动重新应用
@MainActor
final class RestoreWatchdog {

    struct MonitorTarget {
        let windowID: UInt32
        let pid: Int32
        let targetDisplay: Int      // yabai display index
        let targetSpace: Int        // yabai space index
        let targetFrame: CGRect     // Quartz coordinates
        let traceID: String
    }

    static let shared = RestoreWatchdog()

    private var timer: DispatchSourceTimer?
    private var target: MonitorTarget?
    private var stableCount = 0
    private var totalTicks = 0

    private let tickIntervalMs: UInt64 = 200        // 200ms per tick
    private let maxStableTicks = 5                   // 5 consecutive stable ticks → done
    private let maxTotalTicks = 15                   // 15 * 200ms = 3s max lifetime
    private let maxRetries = 3                       // max correction attempts

    private var correctionsApplied = 0

    private init() {}

    /// 在 restore 完成后启动监控
    func startMonitoring(target: MonitorTarget) {
        // 如果已有监控在运行，先停止
        stopMonitoring(reason: "replaced_by_new_target")

        self.target = target
        self.stableCount = 0
        self.totalTicks = 0
        self.correctionsApplied = 0

        log("[RestoreWatchdog] started", fields: [
            "traceID": target.traceID,
            "windowID": String(target.windowID),
            "targetDisplay": String(target.targetDisplay),
            "targetSpace": String(target.targetSpace),
            "targetFrame": "\(Int(target.targetFrame.origin.x)),\(Int(target.targetFrame.origin.y)) \(Int(target.targetFrame.width))x\(Int(target.targetFrame.height))"
        ])

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .milliseconds(Int(tickIntervalMs)), repeating: .milliseconds(Int(tickIntervalMs)))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// 停止监控
    func stopMonitoring(reason: String) {
        guard let t = target else { return }
        timer?.cancel()
        timer = nil

        log("[RestoreWatchdog] stopped", fields: [
            "traceID": t.traceID,
            "windowID": String(t.windowID),
            "reason": reason,
            "totalTicks": String(totalTicks),
            "correctionsApplied": String(correctionsApplied),
            "stableCount": String(stableCount)
        ])
        target = nil
    }

    /// 检查当前窗口状态是否匹配目标
    private func checkStable() -> Bool {
        guard let t = target else { return true }

        let spaceController = SpaceController.shared

        // 1. 检查 float 状态
        let windowInfo = spaceController.queryWindow(windowID: t.windowID)
        if let info = windowInfo, !info.isFloating {
            log("[RestoreWatchdog] window not floating", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID),
                "isFloating": String(info.isFloating)
            ])
            return false
        }

        // 2. 检查 display
        if let info = windowInfo, let display = info.display, display != t.targetDisplay {
            log("[RestoreWatchdog] window on wrong display", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID),
                "currentDisplay": String(display),
                "targetDisplay": String(t.targetDisplay)
            ])
            return false
        }

        // 3. 检查 space
        if let info = windowInfo, let space = info.space, space != t.targetSpace {
            log("[RestoreWatchdog] window on wrong space", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID),
                "currentSpace": String(space),
                "targetSpace": String(t.targetSpace)
            ])
            return false
        }

        // 4. 检查 frame（容差 50px）
        let wm = WindowManager.shared
        if let windowAX = wm.findWindowByPID(t.pid, windowID: t.windowID),
           let currentFrame = wm.frame(of: windowAX) {
            let posDiff = abs(currentFrame.origin.x - t.targetFrame.origin.x) +
                         abs(currentFrame.origin.y - t.targetFrame.origin.y)
            let sizeDiff = abs(currentFrame.width - t.targetFrame.width) +
                          abs(currentFrame.height - t.targetFrame.height)
            if posDiff > 50 || sizeDiff > 50 {
                log("[RestoreWatchdog] window frame drifted", level: .warn, fields: [
                    "traceID": t.traceID,
                    "windowID": String(t.windowID),
                    "currentFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.width))x\(Int(currentFrame.height))",
                    "targetFrame": "\(Int(t.targetFrame.origin.x)),\(Int(t.targetFrame.origin.y)) \(Int(t.targetFrame.width))x\(Int(t.targetFrame.height))",
                    "posDiff": String(Int(posDiff)),
                    "sizeDiff": String(Int(sizeDiff))
                ])
                return false
            }
        }

        return true
    }

    /// 执行修正操作
    private func applyCorrection() {
        guard let t = target else { return }
        guard correctionsApplied < maxRetries else {
            log("[RestoreWatchdog] max corrections reached, stopping", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID)
            ])
            stopMonitoring(reason: "max_corrections_reached")
            return
        }

        correctionsApplied += 1
        log("[RestoreWatchdog] applying correction #\(correctionsApplied)", fields: [
            "traceID": t.traceID,
            "windowID": String(t.windowID)
        ])

        let spaceController = SpaceController.shared
        let wm = WindowManager.shared

        // 1. 重新设置 float
        spaceController.setWindowFloat(t.windowID, operationID: "watchdog_\(t.traceID)")

        // 2. 重新 apply frame
        if let windowAX = wm.findWindowByPID(t.pid, windowID: t.windowID) {
            _ = wm.apply(frame: t.targetFrame, to: windowAX, operationID: "watchdog_\(t.traceID)", stage: "watchdog_correction")
        }

        // 3. 如果 display/space 错误，尝试修正
        if let info = spaceController.queryWindow(windowID: t.windowID) {
            if let display = info.display, display != t.targetDisplay {
                log("[RestoreWatchdog] window still on wrong display after correction", level: .warn, fields: [
                    "traceID": t.traceID,
                    "display": String(display),
                    "targetDisplay": String(t.targetDisplay)
                ])
            }
            if let space = info.space, space != t.targetSpace {
                log("[RestoreWatchdog] attempting space move correction", fields: [
                    "traceID": t.traceID,
                    "currentSpace": String(space),
                    "targetSpace": String(t.targetSpace)
                ])
                _ = spaceController.moveWindow(
                    t.windowID,
                    toSpaceIndex: t.targetSpace,
                    focus: false,
                    operationID: "watchdog_\(t.traceID)"
                )
            }
        }

        log("[RestoreWatchdog] correction #\(correctionsApplied) applied", fields: [
            "traceID": t.traceID,
            "windowID": String(t.windowID)
        ])
    }

    /// 每次 tick 的主逻辑
    private func tick() {
        guard target != nil else {
            stopMonitoring(reason: "no_target")
            return
        }

        totalTicks += 1

        // 超时检查
        if totalTicks > maxTotalTicks {
            log("[RestoreWatchdog] timeout after \(totalTicks) ticks", level: .warn, fields: [
                "traceID": target?.traceID ?? "nil",
                "windowID": target.map { String($0.windowID) } ?? "nil"
            ])
            stopMonitoring(reason: "timeout")
            return
        }

        let stable = checkStable()

        if stable {
            stableCount += 1
            if stableCount >= maxStableTicks {
                log("[RestoreWatchdog] restore confirmed stable after \(totalTicks) ticks", fields: [
                    "traceID": target?.traceID ?? "nil",
                    "windowID": target.map { String($0.windowID) } ?? "nil",
                    "correctionsApplied": String(correctionsApplied)
                ])
                stopMonitoring(reason: "stable")
            }
        } else {
            stableCount = 0
            applyCorrection()
        }
    }
}
```

- [ ] **Step 2: 验证 RestoreWatchdog 编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | head -20`
Expected:
  - 代码中引用了 `SpaceController.queryWindow`、`WindowManager.findWindowByPID`、`WindowManager.apply` — 需要确认这些方法存在且可访问
  - 如果编译失败，根据错误信息调整

- [ ] **Step 3: 质量门禁**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

## Task 2: 将 RestoreWatchdog 集成到 ToggleEngine.restore()

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:417-433`（restore 方法末尾，return 之前）

- [ ] **Step 1: 在 restore 成功后启动 watchdog**

文件: `Sources/Toggle/ToggleEngine.swift:418-433`

在 `// 6. 检测并修复 CGEvent 意外切换其他 display` 之后、`log("ToggleEngine.restore: finished"` 之前插入 watchdog 启动代码：

```swift
        // 7. 启动 post-restore watchdog
        // yabai 异步 tiling 引擎可能在 restore 完成后撤销操作
        // watchdog 持续监控 3 秒，发现偏移自动修正
        if restored {
            RestoreWatchdog.shared.startMonitoring(target: RestoreWatchdog.MonitorTarget(
                windowID: windowID,
                pid: record.pid,
                targetDisplay: record.sourceYabaiDisp,
                targetSpace: record.sourceSpace,
                targetFrame: record.origFrame,
                traceID: trace
            ))
        }
```

这段代码插在现有的 `log("ToggleEngine.restore: finished"` 调用之前。

- [ ] **Step 2: 验证完整编译 + 构建**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 部署并测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Build succeeds
  - App signed and installed to /Applications/VibeFocus.app
  - App launched

测试场景：
1. 在副屏打开终端窗口
2. 用快捷键 toggle 到主屏
3. 用快捷键 toggle 回副屏
4. 检查日志确认 watchdog 启动并正常工作

Run: `grep -E "RestoreWatchdog" ~/Library/Logs/VibeFocus/vibefocus.log | tail -20`
Expected:
  - 看到 "RestoreWatchdog started" 日志
  - 看到 "restore confirmed stable" 或 "timeout" 日志
  - 如果 yabai 干扰，看到 "applying correction" 日志

- [ ] **Step 4: 提交**

Run: `git add Sources/Toggle/RestoreWatchdog.swift Sources/Toggle/ToggleEngine.swift && git commit -m "feat(restore): add post-restore watchdog to counter yabai async tiling interference"`
