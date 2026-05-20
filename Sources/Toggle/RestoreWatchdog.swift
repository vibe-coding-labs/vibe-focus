import Foundation

/// restore 后的持续监控器
/// 解决核心问题：yabai 异步 tiling 引擎可能在 restore 完成后撤销操作
/// watchdog 持续检查窗口状态，发现偏移自动重新应用
@MainActor
final class RestoreWatchdog {

    struct MonitorTarget {
        let windowID: UInt32
        let pid: pid_t
        let targetDisplay: Int
        let targetSpace: Int
        let targetFrame: CGRect
        let traceID: String
    }

    static let shared = RestoreWatchdog()

    private var timer: DispatchSourceTimer?
    private var target: MonitorTarget?
    private var stableCount = 0
    private var totalTicks = 0
    private var correctionsApplied = 0

    private let tickIntervalMs: UInt64 = 200
    private let maxStableTicks = 5
    private let maxTotalTicks = 15
    private let maxCorrections = 5

    private init() {}

    func startMonitoring(target: MonitorTarget) {
        stopMonitoring(reason: "replaced_by_new_target")

        self.target = target
        self.stableCount = 0
        self.totalTicks = 0
        self.correctionsApplied = 0

        let spaceController = SpaceController.shared
        let windowSpace = spaceController.windowSpaceIndex(windowID: target.windowID)
        log("[RestoreWatchdog] started", fields: [
            "traceID": target.traceID,
            "windowID": String(target.windowID),
            "targetDisplay": String(target.targetDisplay),
            "targetSpace": String(target.targetSpace),
            "windowActualSpace": String(describing: windowSpace),
            "targetFrame": "\(Int(target.targetFrame.origin.x)),\(Int(target.targetFrame.origin.y)) \(Int(target.targetFrame.width))x\(Int(target.targetFrame.height))"
        ])

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + .milliseconds(Int(tickIntervalMs)), repeating: .milliseconds(Int(tickIntervalMs)))
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        t.resume()
        self.timer = t
    }

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

    private func checkStable() -> Bool {
        guard let t = target else { return true }

        let spaceController = SpaceController.shared
        let windowInfo = spaceController.queryWindow(windowID: t.windowID)

        if windowInfo == nil {
            log("[RestoreWatchdog] checkStable: queryWindow returned nil", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID)
            ])
        }

        if let info = windowInfo {
            if !info.isFloating {
                log("[RestoreWatchdog] window not floating", level: .warn, fields: [
                    "traceID": t.traceID, "windowID": String(t.windowID)
                ])
                return false
            }
            if let display = info.display, display != t.targetDisplay {
                log("[RestoreWatchdog] window on wrong display", level: .warn, fields: [
                    "traceID": t.traceID,
                    "currentDisplay": String(display),
                    "targetDisplay": String(t.targetDisplay)
                ])
                return false
            }
            if let space = info.space, space != t.targetSpace {
                log("[RestoreWatchdog] window on wrong space", level: .warn, fields: [
                    "traceID": t.traceID,
                    "currentSpace": String(space),
                    "targetSpace": String(t.targetSpace)
                ])
                return false
            }
        }

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

    private func applyCorrection() {
        guard let t = target else { return }
        guard correctionsApplied < maxCorrections else {
            log("[RestoreWatchdog] max corrections reached, stopping", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID),
                "maxCorrections": String(maxCorrections)
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

        // 1. 先确保窗口是浮动状态
        spaceController.setWindowFloat(t.windowID, operationID: "watchdog_\(t.traceID)")

        // 2. 检查并修正 space 位置（必须在 AX apply 之前）
        if let info = spaceController.queryWindow(windowID: t.windowID) {
            if let space = info.space, space != t.targetSpace {
                log("[RestoreWatchdog] space mismatch, moving window to target space", level: .warn, fields: [
                    "traceID": t.traceID,
                    "currentSpace": String(space),
                    "targetSpace": String(t.targetSpace),
                    "correction": String(correctionsApplied)
                ])
                let moved = spaceController.moveWindow(
                    t.windowID,
                    toSpaceIndex: t.targetSpace,
                    focus: false,
                    operationID: "watchdog_\(t.traceID)"
                )
                log("[RestoreWatchdog] space move result", level: .debug, fields: [
                    "traceID": t.traceID,
                    "moved": String(moved),
                    "correction": String(correctionsApplied)
                ])
                if moved {
                    usleep(100_000)
                }
            }
        }

        // 3. AX frame apply
        if let windowAX = wm.findWindowByPID(t.pid, windowID: t.windowID) {
            let applyResult = wm.apply(frame: t.targetFrame, to: windowAX, operationID: "watchdog_\(t.traceID)", stage: "watchdog_correction")
            log("[RestoreWatchdog] correction #\(correctionsApplied) AX apply result", level: .debug, fields: [
                "traceID": t.traceID,
                "success": String(applyResult)
            ])
        } else {
            log("[RestoreWatchdog] correction #\(correctionsApplied): window AX not found", level: .warn, fields: [
                "traceID": t.traceID,
                "windowID": String(t.windowID)
            ])
        }

        // 4. AX apply 后再设一次 float（yabai 可能在 AX apply 后重新 tile 窗口）
        spaceController.setWindowFloat(t.windowID, operationID: "watchdog_\(t.traceID)")
    }

    private func tick() {
        guard target != nil else {
            stopMonitoring(reason: "no_target")
            return
        }

        totalTicks += 1

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
            log("[RestoreWatchdog] tick \(totalTicks): stable (\(stableCount)/\(maxStableTicks))", level: .debug, fields: [
                "traceID": target?.traceID ?? "nil",
                "correctionsApplied": String(correctionsApplied)
            ])
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
            log("[RestoreWatchdog] tick \(totalTicks): UNSTABLE, applying correction", level: .debug, fields: [
                "traceID": target?.traceID ?? "nil",
                "correctionsApplied": String(correctionsApplied),
                "maxCorrections": String(maxCorrections)
            ])
            applyCorrection()
        }
    }
}
