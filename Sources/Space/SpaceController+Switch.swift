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

}

