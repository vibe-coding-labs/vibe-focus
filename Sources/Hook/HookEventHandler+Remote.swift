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

        // 尝试绑定窗口，验证标题是否匹配 SSH 模式
        if let identity = WindowManager.shared.findWindowByCGWindowID(boundWindowID) {
            if titleMatchesSSHPattern(title: identity.title, label: label) {
                log(
                    "[HookEventHandler] resolveRemoteBinding: bound window title matches SSH pattern",
                    fields: [
                        "label": label,
                        "windowID": String(boundWindowID),
                        "title": identity.title ?? "nil",
                        "sessionID": sessionID
                    ]
                )
                return identity
            }

            // 绑定窗口标题不匹配 → 搜索正确的窗口
            log(
                "[HookEventHandler] resolveRemoteBinding: bound window title does not match SSH pattern, scanning for correct window",
                level: .info,
                fields: [
                    "label": label,
                    "boundWindowID": String(boundWindowID),
                    "boundTitle": identity.title ?? "nil",
                    "sessionID": sessionID
                ]
            )
        }

        // 绑定窗口不存在或标题不匹配 → 按 SSH 标题模式搜索所有终端窗口
        let sshPattern = "@" + label + ":"
        let windows = cgWindowListAll()
        let terminalWindows = windows.filter { TerminalRegistry.isTerminalPID($0.ownerPID) }
        let matched = terminalWindows.filter { entry in
            guard let title = entry.name, !title.isEmpty else { return false }
            return title.contains(sshPattern)
        }

        guard let best = matched.first, let bestIdentity = WindowManager.shared.findWindowByCGWindowID(best.windowID) else {
            // 没找到匹配的 SSH 窗口 → 回退到绑定的 windowID（如果还存在）
            if let fallback = WindowManager.shared.findWindowByCGWindowID(boundWindowID) {
                log(
                    "[HookEventHandler] resolveRemoteBinding: no SSH title match found, falling back to bound windowID",
                    level: .info,
                    fields: [
                        "label": label,
                        "windowID": String(boundWindowID),
                        "sessionID": sessionID
                    ]
                )
                return fallback
            }
            log(
                "[HookEventHandler] resolveRemoteBinding: windowID no longer exists in CGWindowList",
                level: .warn,
                fields: [
                    "label": label,
                    "windowID": String(boundWindowID),
                    "sessionID": sessionID
                ]
            )
            return nil
        }

        // 自动更新 LAN binding 到正确的窗口
        log(
            "[HookEventHandler] resolveRemoteBinding: auto-updating binding to matched window",
            level: .info,
            fields: [
                "label": label,
                "oldWindowID": String(boundWindowID),
                "newWindowID": String(best.windowID),
                "matchedTitle": best.name ?? "nil",
                "sessionID": sessionID
            ]
        )
        var updated = LANHookPreferences.remoteBindings
        updated[label] = best.windowID
        LANHookPreferences.remoteBindings = updated

        return bestIdentity
    }

    /// 检查窗口标题是否匹配 SSH 模式（user@machine_label:path）
    private func titleMatchesSSHPattern(title: String?, label: String) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return title.contains("@" + label + ":")
    }
}
