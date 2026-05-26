import Foundation

// MARK: - Remote Binding Resolution
@MainActor
extension HookEventHandler {

    /// 通过 machine_label 查找映射表中的窗口
    func resolveRemoteBinding(label: String, sessionID: String) -> WindowIdentity? {
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
