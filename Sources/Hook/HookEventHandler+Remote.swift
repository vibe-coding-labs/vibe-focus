import Foundation

// MARK: - Remote Binding Resolution
@MainActor
extension HookEventHandler {

    /// 通过 machine_label 查找映射表中的窗口
    func resolveRemoteBinding(label: String, sessionID: String) -> WindowIdentity? {
        // P-INST-54: resolveRemoteBinding 耗时（远程 session 自愈入口；LANHookPreferences 字典查 + findWindowByCGWindowID CG 查找；hook 路径 P-INST-31/32/33 已覆盖调用方总耗时，此埋点补远程自愈各 outcome 归因）。
        let rrbStart = Date()
        var rrbOutcome = "unknown"
        defer {
            log("[HookEventHandler] resolveRemoteBinding finished", level: .debug, fields: [
                "label": label, "sessionID": sessionID,
                "outcome": rrbOutcome,
                "durationMs": String(elapsedMilliseconds(since: rrbStart))
            ])
        }
        let bindings = LANHookPreferences.activeRemoteBindings
        log(
            "[HookEventHandler] resolveRemoteBinding: looking up machine_label",
            fields: [
                "label": label,
                "sessionID": sessionID,
                "availableLabels": bindings.keys.sorted().joined(separator: ","),
                "totalRemoteBindings": String(bindings.count)
            ]
        )

        guard let boundWindowID = bindings[label] else {
            rrbOutcome = "label_not_found"
            log(
                "[HookEventHandler] resolveRemoteBinding: label not found in remote bindings",
                level: .warn,
                fields: [
                    "label": label,
                    "availableLabels": bindings.keys.sorted().joined(separator: ","),
                    "sessionID": sessionID
                ]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 远程：label '\(label)' 未映射到窗口")
            return nil
        }

        // 直接使用绑定的 windowID
        if let identity = WindowManager.shared.findWindowByCGWindowID(boundWindowID) {
            rrbOutcome = "resolved"
            log(
                "[HookEventHandler] resolveRemoteBinding: resolved via bound windowID",
                fields: [
                    "label": label,
                    "windowID": String(boundWindowID),
                    "title": identity.title ?? "nil",
                    "sessionID": sessionID
                ]
            )
            return identity
        }

        rrbOutcome = "window_gone"
        log(
            "[HookEventHandler] resolveRemoteBinding: bound windowID no longer exists",
            level: .warn,
            fields: [
                "label": label,
                "windowID": String(boundWindowID),
                "sessionID": sessionID
            ]
        )
        return nil
    }
}
