import AppKit
import Foundation

@MainActor
extension SpaceController {

    // MARK: 历史注（2026-09-01 清理）
    // moveWindow(toSpace:) 已删除：其 Strategy 1（yabai `window --space`）在 v7 float
    // 布局下静默失效（exit 0 但窗口不动，Tests/AXMoveValidation.swift T3 断言实测），
    // Strategy 2（SLS move）因权限不足从未真正可用。跨屏移动统一走
    // WindowManager.moveWindowToFrameViaYabai（float 脱管 → settle → frame 直写 + 读回验证）。

    /// setWindowFloat 的结局（调用方据此决定是否需要等重摆落定）。
    enum FloatToggleOutcome: Equatable {
        /// 真发生了 --toggle float：yabai 会默认重摆，调用方必须等
        /// WindowSettle.floatRelayoutSettleMicros 再写 frame。
        case toggled
        /// 未发生任何 yabai 写：窗口已 float / yabai 不可用 / 无法管理 / 查询失败。
        /// 此时没有重摆，后续 frame 写无需等待。
        case skippedNoOp

        var didToggle: Bool { self == .toggled }
    }

    /// float 脱管跳过/执行的纯决策（分支穷尽锁定于 Standalone FloatToggleDecisionTests）。
    /// info 用 @autoclosure 保持惰性：disabled 时不得发起 queryWindow fork（fork ~ms，
    /// 热键路径白耗时）。决策序与 2026-09-02 重构前行为一致：
    /// disabled → query_nil → already_floating → unmanaged → toggled。
    static func floatToggleDecision(
        isEnabled: Bool,
        info: @autoclosure () -> YabaiWindowInfo?
    ) -> (outcome: FloatToggleOutcome, skipReason: String) {
        guard isEnabled else { return (.skippedNoOp, "disabled") }
        guard let info = info() else { return (.skippedNoOp, "query_nil") }
        if info.isFloating {
            return (.skippedNoOp, "already_floating")
        }
        // yabai 无法管理此窗口时，float 切换无意义且必定失败
        if !info.isManageableByYabai {
            return (.skippedNoOp, "unmanaged")
        }
        return (.toggled, "-")
    }

    /// float 脱管（--toggle float）。返回结局供调用方决定 settle（2026-09-02 前
    /// 调用方无条件等 300ms，已 float 的窗口纯浪费——restore 常见路径恰是已 float）。
    @discardableResult
    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> FloatToggleOutcome {
        let op = operationID ?? "none"
        let startedAt = Date()
        var outcome: FloatToggleOutcome = .skippedNoOp
        // P-INST-13: yabai toggle float fork 耗时（runYabai logSuccess=false，fast<180ms 不记，此处补 forkMs）。
        var forkMs = 0
        var skipReason = "-"
        // defer 汇总：所有退出路径（含各 skip）都记录耗时，消除 setWindowFloat 耗时盲区。
        defer {
            log("[SpaceController] setWindowFloat", fields: [
                "op": op,
                "windowID": String(windowID),
                "outcome": outcome == .toggled ? "toggled" : "skipped_no_op",
                "skipReason": skipReason,
                "forkMs": String(forkMs),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }

        // 决策（纯函数；@autoclosure 保证 disabled 时不发起 queryWindow fork）
        let decision = Self.floatToggleDecision(
            isEnabled: isEnabled,
            info: knownWindowInfo ?? queryWindow(windowID: windowID)
        )
        outcome = decision.outcome
        skipReason = decision.skipReason
        guard outcome == .toggled else {
            if skipReason == "unmanaged" {
                log("setWindowFloat: skipping (no AX ref, yabai can't manage)", level: .info, fields: [
                    "op": op, "windowID": String(windowID)
                ])
            } else if skipReason == "query_nil" {
                log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
                    "op": op, "windowID": String(windowID)
                ])
            }
            return outcome
        }

        let floatForkStart = Date()
        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
        forkMs = elapsedMilliseconds(since: floatForkStart)
        return .toggled
    }

    func focusWindow(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) -> Bool {
        let op = operationID ?? "none"
        // P-INST-53: focusWindow 总耗时（queryWindow P-INST-6 + runYabaiVariants P-INST-27 + Carbon fallback；顶层归因，含各 abort/success 路径）。
        let fcStart = Date()
        var fcOutcome = "unknown"
        defer {
            log("[SpaceController] focusWindow finished", fields: [
                "op": op, "windowID": String(windowID),
                "outcome": fcOutcome,
                "durationMs": String(elapsedMilliseconds(since: fcStart))
            ])
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled else { fcOutcome = "disabled"; return false }

        // 使用传入的窗口信息或查询缓存
        let info = knownWindowInfo ?? queryWindow(windowID: windowID)
        guard let info else {
            fcOutcome = "no_window"
            log("[SpaceController] focusWindow aborted: window does not exist", level: .warn, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return false
        }

        // yabai 无法管理此窗口时，用 Carbon API 直接 focus
        if !info.isManageableByYabai {
            let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
            fcOutcome = carbonResult ? "carbon_ok" : "carbon_failed"
            log("[SpaceController] focusWindow via Carbon fallback", level: carbonResult ? .info : .warn, fields: [
                "op": op, "windowID": String(windowID), "result": String(carbonResult)
            ])
            return carbonResult
        }

        let result = runYabaiVariants(
            variants: [["-m", "window", "--focus", "\(windowID)"]],
            operation: "focusWindow(\(windowID))",
            operationID: op
        )
        if result.success { fcOutcome = "yabai_ok"; return true }
        // yabai focus 失败时也尝试 Carbon fallback
        let carbonResult = WindowManager.shared.focusWindowByCGWindowID(windowID)
        if carbonResult { fcOutcome = "carbon_fallback_ok"; return true }
        fcOutcome = "all_failed"
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }
}
