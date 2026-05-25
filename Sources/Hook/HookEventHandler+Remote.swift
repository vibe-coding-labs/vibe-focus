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

        guard let windowID = bindings[label] else {
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

        guard let identity = WindowManager.shared.findWindowByCGWindowID(windowID) else {
            log(
                "[HookEventHandler] resolveRemoteBinding: windowID no longer exists in CGWindowList",
                level: .warn,
                fields: [
                    "label": label,
                    "windowID": String(windowID),
                    "sessionID": sessionID
                ]
            )
            return nil
        }

        log(
            "[HookEventHandler] resolveRemoteBinding: resolved successfully",
            fields: [
                "label": label,
                "windowID": String(windowID),
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "pid": String(identity.pid),
                "sessionID": sessionID
            ]
        )
        return identity
    }
}
