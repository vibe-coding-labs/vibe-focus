import AppKit
import Foundation

@MainActor
extension SpaceController {

    func switchDisplayToSpace(targetSpace: SpaceIdentifier, operationID: String?) -> Bool {
        let op = operationID ?? "none"
        guard let targetSpaceIndex = targetSpace.yabaiIndex else {
            log("[SpaceController] switchDisplayToSpace: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log("[SpaceController] switchDisplayToSpace: not enabled", level: .warn, fields: ["op": op])
            return false
        }

        // Strategy 1: yabai -m space --focus (需要 SA)
        let yabaiResult = runYabai(
            arguments: ["-m", "space", "--focus", String(targetSpaceIndex)],
            operation: "switchDisplayToSpace_yabai",
            operationID: op
        )
        if let result = yabaiResult, result.exitCode == 0 {
            return true
        }

        // 检测 Mission Control 阻塞 — 如果 MC 活跃则先关闭再重试
        let stderr = yabaiResult?.stderr ?? ""
        let isMCBlocking = stderr.contains("mission-control")
        if isMCBlocking {
            log("[SpaceController] switchDisplayToSpace: Mission Control blocking, dismissing", level: .info, fields: ["op": op])
            NativeSpaceBridge.dismissMissionControl(operationID: op)
            // 重试 yabai
            let retryResult = runYabai(
                arguments: ["-m", "space", "--focus", String(targetSpaceIndex)],
                operation: "switchDisplayToSpace_yabai_after_mc_dismiss",
                operationID: op
            )
            if let result = retryResult, result.exitCode == 0 {
                return true
            }
        }

        log("[SpaceController] switchDisplayToSpace: yabai failed", level: .warn, fields: [
            "op": op, "targetSpace": String(targetSpaceIndex)
        ])
        return false
    }

    func focusSpace(_ space: SpaceIdentifier, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] focusSpace: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot focus another space because cross-space control is unavailable", operationID: op)
            return false
        }

        let variants = [["-m", "space", "--focus", "\(spaceIndex)"]]
        let result = runYabaiVariants(variants: variants, operation: "focusSpace(\(spaceIndex))", operationID: op)
        if result.success {
            return true
        }

        markOperationError(from: result.failure, fallback: "Failed to focus space \(spaceIndex)", operationID: op)
        return false
    }

    /// 聚焦指定 space 上的任意可管理窗口，把键盘焦点/用户视角带回该 space 所在 display。
    ///
    /// ## 场景（2026-09-01 视角守卫重构）
    /// - restore 把窗口 frame 直写回源屏后，macOS 会把键盘焦点/视角跟随到目标 display
    ///   （实测 preSpace=1 → postSpace=5），用户被拖离原屏。
    /// - 原 CGEvent 方向键法（ctrl+←×N）在 separate-Spaces 下**无法跨 display**（方向键只在
    ///   焦点 display 的 space 序列内切换），切回必失败。
    /// - yabai `space --focus` 依赖 scripting-addition（SA 失效时报
    ///   "error with the scripting-addition"），也不可用。
    /// - 可靠路径：窗口级 focus（AX/CG 通道，不依赖 SA），实测聚焦目标 space 任一窗口即把
    ///   焦点与视角一并带回。
    /// - Returns: 是否成功聚焦了目标 space 上的窗口。
    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID excluded: UInt32? = nil, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let result = runYabai(arguments: ["-m", "query", "--windows"], operation: "refocusWindowOnSpace.query", operationID: op),
              result.exitCode == 0,
              let windows = decodeArray(YabaiWindowInfo.self, from: result.stdout) else {
            log("[SpaceController] refocusWindowOnSpace: window query failed", level: .warn, fields: [
                "op": op, "spaceIndex": String(spaceIndex)
            ])
            return false
        }

        guard let candidate = windows.first(where: { w in
            guard w.space == spaceIndex,
                  w.isManageableByYabai,
                  w.id.map({ UInt32($0) }) != excluded else { return false }
            return true
        }), let candidateID = candidate.id.map({ UInt32($0) }) else {
            log("[SpaceController] refocusWindowOnSpace: no focusable window on target space", level: .debug, fields: [
                "op": op, "spaceIndex": String(spaceIndex)
            ])
            return false
        }

        let focusResult = runYabai(
            arguments: ["-m", "window", "\(candidateID)", "--focus"],
            operation: "refocusWindowOnSpace.focus(windowID=\(candidateID))",
            operationID: op
        )
        let ok = focusResult?.exitCode == 0
        log("[SpaceController] refocusWindowOnSpace result", level: ok ? .debug : .warn, fields: [
            "op": op, "spaceIndex": String(spaceIndex),
            "focusedWindowID": String(candidateID),
            "success": String(ok)
        ])
        return ok
    }

}

