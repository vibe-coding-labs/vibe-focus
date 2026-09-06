import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - 终端标题编辑服务（编排层）
// 文件分层（2026-08-31 拆分，行为不变）：
//   TitleEditorService.swift（本文件）      — editTitle 手动编辑（NSAlert 弹窗）、
//                                            autoSetTitle（SessionStart hook）、
//                                            applyTitle 三路写编排
//   TitleEditorService+Channels.swift       — 写入通道：AX / AppleScript（Terminal/iTerm2）/ 权限弹窗
//   TitleEditorService+TTYWriter.swift      — TTY OSC 序列写入通道

@MainActor
/// Service for programmatically setting terminal window titles via escape sequences.
final class TitleEditorService {
    static let shared = TitleEditorService()

    private var terminalBundleIDs: Set<String> { TerminalRegistry.terminalBundleIDs }

    private var isEditing = false

    /// Automation 权限引导弹窗（-1743）每次进程生命周期只弹一次，避免连续改名时重复打扰
    /// （跨文件 extension 的 showAutomationPermissionAlert 访问，需 internal 可见性）
    var hasShownAutomationPermissionAlert = false

    /// Tracks windows the user has manually renamed via Ctrl+T — autoSetTitle skips these
    private var userRenamedWindowIDs: Set<UInt32> = []

    // MARK: - Public API

    /// Manually edit the title of the focused terminal window (Ctrl+T)
    ///
    /// ## 场景
    /// - 全局热键 Ctrl+T 触发；模态 NSAlert 阻塞本方法直到用户 OK/Cancel；
    /// - isEditing 防重入（模态期间再次热键直接忽略）；
    /// - 前后台各 activate 一次终端：前置防设置窗口抢焦点，后置防 AppleScript/AX
    ///   调用偷焦点。
    ///
    /// ## 行为约束
    /// - 仅对 TerminalRegistry 认可的终端生效，其他前台 app 静默忽略；
    /// - 用户手动改名的窗口记入 userRenamedWindowIDs，此后 autoSetTitle 永久跳过该窗口
    ///   （用户命名优先于自动命名）。
    func editTitle() {
        // P-INST-218: 标题编辑入口端到端耗时（NSWorkspace.frontmostApplication + WindowManager.focusedWindow P-INST-52 + title AX + NSApp.activate；用户 Ctrl+T 手动触发，非 toggle 热路径）。
        #if PERF_INSTRUMENT
        let etStart = Date()
        defer {
            log("[TitleEditorService] editTitle finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: etStart))])
        }
        #endif
        guard !isEditing else {
            log("[TitleEditorService] editTitle: already editing, ignoring")
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[TitleEditorService] editTitle: no frontmost application")
            return
        }

        let bundleID = frontApp.bundleIdentifier ?? ""
        guard terminalBundleIDs.contains(bundleID) else {
            log(
                "[TitleEditorService] editTitle: frontmost app is not a recognized terminal",
                level: .debug,
                fields: ["bundleID": bundleID]
            )
            return
        }

        let pid = frontApp.processIdentifier
        guard let window = WindowManager.shared.focusedWindow(for: pid) else {
            log(
                "[TitleEditorService] editTitle: could not get focused window",
                level: .warn,
                fields: ["pid": String(pid), "bundleID": bundleID]
            )
            return
        }

        let currentTitle = WindowManager.shared.title(of: window) ?? ""
        let capturedWindowID = WindowManager.shared.windowHandle(for: window)

        // 弹框前捕获「可寻址目标身份」（2026-09-07 定向修复 v2）。此刻终端仍在前台持焦，
        // iTerm2 的 current window / Terminal 的 front window 语义与用户所见一致；弹框
        // （NSApp.activate + 模态）之后前台已被 VibeFocus 劫走，再按 current window 取
        // 就会盲射——用户实测「设置名字」applyViaAppleScript 报 success 却没落进任何
        // 窗口（窗口表全量核对无此标题）。两终端统一用会话 tty 寻址（唯一稳定身份，
        // AppleScript window id 与 CGWindowNumber 不同源、不可用，真机实测 5576 vs 5584）。
        var targetTTY: String?
        switch bundleID {
        case "com.googlecode.iterm2":
            targetTTY = Self.captureCurrentSessionTTY()
        case "com.apple.Terminal":
            targetTTY = Self.captureTerminalFrontTabTTY()
        default:
            break
        }

        log(
            "[TitleEditorService] editTitle: showing native alert",
            fields: [
                "bundleID": bundleID,
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "pid": String(pid),
                "capturedWindowID": capturedWindowID.map(String.init) ?? "nil",
                "targetTTY": targetTTY ?? "nil"
            ]
        )

        isEditing = true

        // 设置窗开着时，NSApp.activate 会把它顶到前台——用户看到的就是「按快捷键弹出
        // 设置界面、焦点全乱了」。模态期间临时隐藏，结束后原样恢复（恢复的只是可见性，
        // 焦点随后由终端 reactivation 抢回）。
        let settingsWindow = SettingsWindowController.shared.window
        let settingsWasVisible = settingsWindow?.isVisible ?? false
        if settingsWasVisible {
            settingsWindow?.orderOut(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Edit Terminal Title"
        alert.informativeText = "Enter the new title for the terminal window.\n\nNote: 若 shell 会自动设标题（如 macOS 默认 zsh 每次画提示符重设 user—host），回车后 shell 会把标题改回去。Claude 会话窗口不受影响。"
        alert.alertStyle = .informational

        let inputField = NSTextField(string: currentTitle)
        inputField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        inputField.cell?.sendsActionOnEndEditing = false
        inputField.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = inputField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        // 弹窗定位在屏幕视觉重心（黄金分割 0.618 高度处），避免遮挡终端内容
        alert.window.center()
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let goldenY = visibleFrame.origin.y + visibleFrame.height * 0.618
            var frame = alert.window.frame
            frame.origin.y = goldenY - frame.height / 2
            alert.window.setFrame(frame, display: true)
        }

        alert.window.level = .floating

        let response = alert.runModal()
        isEditing = false

        // Reactivate terminal app to prevent VibeFocus settings window from appearing
        _ = frontApp.activate(options: .activateIgnoringOtherApps)

        if response == .alertFirstButtonReturn {
            let newTitle = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTitle.isEmpty {
                if let windowID = WindowManager.shared.windowHandle(for: window) {
                    userRenamedWindowIDs.insert(windowID)
                    log("[TitleEditorService] marked window as user-renamed", fields: ["windowID": String(windowID)])
                }
                applyTitle(
                    newTitle,
                    to: window,
                    pid: pid,
                    bundleID: bundleID,
                    targetTTY: targetTTY
                )
            }
        }

        // Re-activate terminal after applyTitle (AppleScript/AX calls may steal focus)
        _ = frontApp.activate(options: .activateIgnoringOtherApps)

        // 恢复设置窗可见性放在最后：终端 reactivation 已把焦点还回去，设置窗回到
        // 「可见但不在前台」的原状态。
        if settingsWasVisible {
            settingsWindow?.orderFront(nil)
        }
    }

    // MARK: - Auto Title

    /// Auto-set terminal title based on CWD project name (SessionStart hook)
    ///
    /// ## 场景
    /// - ClaudeHookServer 的 SessionStart 分支调用；标题格式 `<项目名> — Claude Code`；
    /// - cwd 为空时项目名兜底 "Claude"。
    ///
    /// ## 行为约束
    /// - userRenamedWindowIDs 命中即跳过：用户手动命名（Ctrl+T）优先于自动命名，
    ///   且该标记进程内永久有效（不随 hook 事件清除）。
    func autoSetTitle(cwd: String?, pid: pid_t, bundleID: String, window: AXUIElement) {
        // P-INST-250: autoSetTitle 编排耗时（windowHandle AX 查询 + userRenamedWindowIDs 检查 + applyTitle P-INST-40 三路 AX/AppleScript/TTY 写；SessionStart hook 路径调用，归因 title 阶段延迟；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let astStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: astStart)
            if durMs >= 50 { log("[TitleEditorService] autoSetTitle slow", level: .warn, fields: ["pid": String(pid), "bundleID": bundleID, "durationMs": String(durMs)]) }
        }
        #endif
        if let windowID = WindowManager.shared.windowHandle(for: window),
           userRenamedWindowIDs.contains(windowID) {
            log("[TitleEditorService] autoSetTitle: skipping, user has manually renamed this window", fields: ["windowID": String(windowID)])
            return
        }

        let projectName: String
        if let cwd = cwd, !cwd.isEmpty {
            projectName = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            projectName = "Claude"
        }
        let title = "\(projectName) — Claude Code"

        log(
            "[TitleEditorService] autoSetTitle",
            fields: [
                "title": title,
                "cwd": cwd ?? "nil",
                "pid": String(pid),
                "bundleID": bundleID
            ]
        )

        applyTitle(title, to: window, pid: pid, bundleID: bundleID)
    }

    // MARK: - Title Application

    /// 三路写编排：AX + AppleScript + TTY（TTY 通道见 +TTYWriter.swift）。
    ///
    /// ## 顺序/跳过约束（必读）
    /// - iTerm2 特例：AppleScript 设的是 session 级名称，会覆盖 OSC 序列——此时跳过 TTY
    ///   写，避免 OSC 先落屏、session name 后到造成的标题闪烁；
    /// - 其他终端 TTY 是主（或唯一）通道，正常执行；
    /// - 三路独立成功/失败，全量结果落一行日志便于归因哪一路失效。
    /// - 定向写入（2026-09-07 v2）：targetTTY（弹框前捕获的会话 tty）为两终端统一寻址键；
    ///   nil 时回退 front window 旧语义（capture 失败的保守路径，日志可见）。
    private func applyTitle(
        _ newTitle: String,
        to window: AXUIElement,
        pid: pid_t,
        bundleID: String,
        targetTTY: String? = nil
    ) {
        // P-INST-40: applyTitle 耗时（AX write + AppleScript fork + TTY fork 三路写；SessionStart autoSetTitle 隐含阻塞，归因 handleSessionStart 的 title 阶段）。
        let applyTitleStart = Date()
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        let axSuccess = applyViaAX(trimmed, to: window)
        let scriptSuccess = applyViaAppleScript(trimmed, bundleID: bundleID, targetTTY: targetTTY)

        // For iTerm2, AppleScript sets session-level name which overrides OSC sequences —
        // skip TTY to avoid a brief flash where OSC overwrites before iTerm2 applies the session name.
        // For other terminals, TTY is the primary (or only) mechanism.
        let ttySuccess: Bool
        if scriptSuccess && bundleID == "com.googlecode.iterm2" {
            ttySuccess = false
            log(
                "[TitleEditorService] applyTitle: skipping TTY for iTerm2 (AppleScript session name overrides OSC)",
                level: .debug
            )
        } else {
            ttySuccess = applyViaTTY(trimmed, pid: pid)
        }

        log(
            "[TitleEditorService] applyTitle result",
            fields: [
                "title": truncateForLog(trimmed, limit: 60),
                "axSuccess": String(axSuccess),
                "ttySuccess": String(ttySuccess),
                "scriptSuccess": String(scriptSuccess),
                "bundleID": bundleID,
                "durationMs": String(elapsedMilliseconds(since: applyTitleStart))
            ]
        )
    }
}
