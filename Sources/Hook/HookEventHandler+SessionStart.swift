// HookEventHandler+SessionStart.swift
// VibeFocus — SessionStart 事件处理
// 从 HookEventHandler.swift 中提取

import Cocoa
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Session Start

    func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        log(
            "[handleSessionStart] called",
            level: .debug,
            fields: [
                "sessionID": payload.sessionID,
                "cwd": payload.cwd ?? "nil",
                "hasTerminalCtx": String(payload.terminalCtx != nil),
                "terminalCtxUseful": String(payload.terminalCtx?.hasUsefulContext ?? false),
                "isRemote": String(payload.terminalCtx?.isRemote ?? false),
                "machineLabel": payload.terminalCtx?.machineLabel ?? "nil"
            ]
        )

        guard let terminalCtx = payload.terminalCtx, terminalCtx.hasUsefulContext else {
            log(
                "[handleSessionStart] no terminal context, cannot bind",
                level: .warn,
                fields: ["sessionID": payload.sessionID]
            )
            SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：无终端上下文")
            return (
                409,
                ClaudeHookResponse(
                    ok: false, code: "no_terminal_context",
                    message: "No terminal context available for precise binding",
                    sessionID: payload.sessionID, handled: false
                )
            )
        }

        // 区分本地绑定和远程映射
        let identity: WindowIdentity
        if terminalCtx.isRemote, let label = terminalCtx.machineLabel {
            log(
                "[handleSessionStart] remote session detected, resolving via machine_label",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "machineLabel": label,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil"
                ]
            )
            // 远程机器：通过 machine_label 查映射表
            guard let resolved = resolveRemoteBinding(label: label, sessionID: payload.sessionID) else {
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "remote_binding_failed",
                        message: "Remote machine label '\(label)' not mapped to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = resolved
        } else {
            // 本地机器：用 PPID/TTY 进程树匹配
            log(
                "[handleSessionStart] local session, resolving via TTY/PPID",
                level: .debug,
                fields: [
                    "sessionID": payload.sessionID,
                    "tty": terminalCtx.tty ?? "nil",
                    "ppid": terminalCtx.ppid ?? "nil",
                    "termSessionID": terminalCtx.termSessionID ?? "nil"
                ]
            )
            guard let localIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx) else {
                log(
                    "[handleSessionStart] terminal context match failed",
                    level: .warn,
                    fields: [
                        "sessionID": payload.sessionID,
                        "tty": terminalCtx.tty ?? "nil",
                        "ppid": terminalCtx.ppid ?? "nil"
                    ]
                )
                SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：终端上下文无法匹配窗口")
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false, code: "terminal_context_match_failed",
                        message: "Terminal context could not be resolved to a window",
                        sessionID: payload.sessionID, handled: false
                    )
                )
            }
            identity = localIdentity
        }

        log(
            "[HookEventHandler] SessionStart matched",
            fields: [
                "sessionID": payload.sessionID,
                "isRemote": String(terminalCtx.isRemote),
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
        let resolvedBindingType: WindowState.BindingType = terminalCtx.isRemote ? .remote : .local
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model,
            bindingType: resolvedBindingType
        )
        AuditLogger.shared.record(
            eventType: "session_bind",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: payload.sessionID,
            details: [
                "app": identity.appName ?? "unknown",
                "isRemote": String(terminalCtx.isRemote),
                "bindingType": String(describing: resolvedBindingType),
                "cwd": payload.cwd ?? "nil"
            ]
        )

        // Auto-set terminal title to project name
        if let axWindow = WindowManager.shared.resolveWindow(identity: identity) {
            TitleEditorService.shared.autoSetTitle(
                cwd: payload.cwd,
                pid: identity.pid,
                bundleID: identity.bundleIdentifier ?? "",
                window: axWindow
            )
        } else {
            log(
                "[HookEventHandler] SessionStart autoSetTitle skipped: could not resolve AX window",
                level: .debug,
                fields: ["windowID": String(identity.windowID)]
            )
        }

        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "session_bound",
                message: "Session bound to terminal window via \(terminalCtx.isRemote ? "remote_label" : "TTY/PPID")",
                sessionID: payload.sessionID, handled: true
            )
        )
    }
}
