import Foundation

// MARK: - Remote Binding Resolution
@MainActor
extension HookEventHandler {

    /// 远程会话 → 本机窗口解析（两级）：
    /// ① 动态通道（B125）：terminal_ctx 带 SSH_CLIENT 端口 → SSH 连接指纹反查
    ///    会话真正所在的窗（一台服务器多开 ssh 窗/多并发会话下唯一正确的通道）；
    /// ② 静态 label→窗 映射兜底（tmux 等拿不到 SSH_CLIENT 的场景；多窗并发下
    ///    它必然张冠李戴，仅作兜底不再作为主通道）。
    func resolveRemoteBinding(label: String, sessionID: String, terminalCtx: TerminalContext?) -> WindowIdentity? {
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
        // ① 动态通道：SSH 连接指纹（client_port 是 Mac 侧 ssh 进程的本地 TCP 端口）
        if let ctx = terminalCtx, let clientPort = ctx.sshClientPort, !clientPort.isEmpty {
            let clientIP = ctx.sshClientIP ?? ""
            let serverIP = ctx.sshServerIP ?? ""
            if let dynamic = WindowManager.shared.resolveWindowBySSHLink(
                clientIP: clientIP, clientPort: clientPort, serverIP: serverIP) {
                rrbOutcome = "resolved_ssh_link"
                log(
                    "[HookEventHandler] resolveRemoteBinding: resolved via ssh link",
                    fields: [
                        "label": label,
                        "windowID": String(dynamic.windowID),
                        "title": dynamic.title ?? "nil",
                        "sessionID": sessionID
                    ]
                )
                return dynamic
            }
            log(
                "[HookEventHandler] resolveRemoteBinding: ssh link unresolved, falling back to static label map",
                level: .debug,
                fields: ["label": label, "sessionID": sessionID,
                         "clientPort": clientPort, "serverIP": serverIP]
            )
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
