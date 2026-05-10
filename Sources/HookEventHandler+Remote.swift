import Foundation

// MARK: - Remote Binding Resolution
@MainActor
extension HookEventHandler {

    /// 通过 machine_label 查找映射表中的窗口
    func resolveRemoteBinding(label: String, sessionID: String) -> WindowIdentity? {
        let bindings = LANHookPreferences.activeRemoteBindings
        guard let windowID = bindings[label] else {
            log(
                "[HookEventHandler] remote binding not found for label",
                level: .warn,
                fields: ["label": label, "availableLabels": bindings.keys.joined(separator: ",")]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 远程：label '\(label)' 未映射到窗口")
            return nil
        }

        guard let identity = WindowManager.shared.findWindowByCGWindowID(windowID) else {
            log(
                "[HookEventHandler] remote binding window no longer exists",
                level: .warn,
                fields: ["label": label, "windowID": String(windowID)]
            )
            return nil
        }

        log(
            "[HookEventHandler] remote binding resolved",
            fields: [
                "label": label,
                "windowID": String(windowID),
                "app": identity.appName ?? "unknown"
            ]
        )
        return identity
    }
}
