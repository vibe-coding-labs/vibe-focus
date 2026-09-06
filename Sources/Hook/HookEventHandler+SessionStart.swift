// HookEventHandler+SessionStart.swift
// VibeFocus — SessionStart 事件处理
// 从 HookEventHandler.swift 中提取

import Cocoa
import Foundation

@MainActor
extension HookEventHandler {

    // MARK: - Session Start

    /// Handle SessionStart hook event — bind a terminal window to a Claude Code session.
    ///
    /// When a new Claude Code session starts, this handler:
    /// 1. Resolves the terminal window from the hook payload's terminal context
    /// 2. Registers the session-window binding in SessionWindowRegistry
    /// 3. Optionally sets the terminal window title to include the project name
    ///
    /// - Parameter payload: The hook event payload containing session and terminal context
    /// - Returns: HTTP-style status code and hook response
    func handleSessionStart(
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
        // P-INST-33: handleSessionStart 总耗时（SessionStart hook 同步响应延迟；含 findWindowByTerminalContext 窗口匹配 + autoSetTitle AX write）。
        #if PERF_INSTRUMENT
        let ssStart = Date()
        defer {
            log("[handleSessionStart] finished", fields: [
                "sessionID": payload.sessionID,
                "durationMs": String(elapsedMilliseconds(since: ssStart))
            ])
        }
        #endif
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

        // 区分本地绑定和远程映射；双通道解析结果由 decideSessionBind 纯判定裁决
        //（Batch 19，决策与响应映射 Runner 直测穷尽锁定）。
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
            let remoteResolved = resolveRemoteBinding(label: label, sessionID: payload.sessionID)
            switch Self.decideSessionBind(isRemote: true, machineLabel: label, localResolved: nil, remoteResolved: remoteResolved) {
            case .bind(let identity, let bindingType):
                return finishSessionBind(
                    identity: identity, bindingType: bindingType,
                    terminalCtx: terminalCtx, payload: payload
                )
            case .remoteBindingFailed(let failedLabel):
                return (409, ClaudeHookResponse(
                    ok: false, code: "remote_binding_failed",
                    message: "Remote machine label '\(failedLabel)' not mapped to a window",
                    sessionID: payload.sessionID, handled: false))
            case .terminalContextMatchFailed:
                fatalError("remote 通道不可能产生本地失败决策（决策表契约）")
            }
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
            let localIdentity = WindowManager.shared.findWindowByTerminalContext(terminalCtx)
            switch Self.decideSessionBind(isRemote: false, machineLabel: nil, localResolved: localIdentity, remoteResolved: nil) {
            case .bind(let identity, let bindingType):
                return finishSessionBind(
                    identity: identity, bindingType: bindingType,
                    terminalCtx: terminalCtx, payload: payload
                )
            case .terminalContextMatchFailed:
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
                return (409, ClaudeHookResponse(
                    ok: false, code: "terminal_context_match_failed",
                    message: "Terminal context could not be resolved to a window",
                    sessionID: payload.sessionID, handled: false))
            case .remoteBindingFailed:
                fatalError("local 通道不可能产生远程失败决策（决策表契约）")
            }
        }
    }
}

// MARK: - 绑定成功共享尾（Batch 19：remote/local 双通道收敛的完成副作用）
extension HookEventHandler {

    /// 绑定成功终态：注册绑定 + 审计 + 可选项目名改名 + 成功响应。
    /// 由 handleSessionStart 的 remote/local 两通道在决策为 .bind 后委托调用。
    func finishSessionBind(
        identity: WindowIdentity,
        bindingType: WindowState.BindingType,
        terminalCtx: TerminalContext,
        payload: ClaudeHookPayload
    ) -> (statusCode: Int, response: ClaudeHookResponse) {
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
        SessionWindowRegistry.shared.bind(
            sessionID: payload.sessionID,
            windowIdentity: identity,
            terminalTTY: payload.terminalCtx?.tty,
            terminalSessionID: payload.terminalCtx?.termSessionID,
            itermSessionID: payload.terminalCtx?.itermSessionID,
            cwd: payload.cwd,
            model: payload.model,
            bindingType: bindingType
        )
        AuditLogger.shared.record(
            eventType: "session_bind",
            windowID: identity.windowID,
            pid: identity.pid,
            sessionID: payload.sessionID,
            details: [
                "app": identity.appName ?? "unknown",
                "isRemote": String(terminalCtx.isRemote),
                "bindingType": String(describing: bindingType),
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

