import AppKit
import ApplicationServices.HIServices
import Foundation

@MainActor
/// Service for programmatically setting terminal window titles via escape sequences.
class TitleEditorService {
    static let shared = TitleEditorService()

    private var terminalBundleIDs: Set<String> { TerminalRegistry.terminalBundleIDs }

    private var isEditing = false

    /// Tracks windows the user has manually renamed via Ctrl+T — autoSetTitle skips these
    private var userRenamedWindowIDs: Set<UInt32> = []

    // MARK: - Public API

    func editTitle() {
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

        log(
            "[TitleEditorService] editTitle: showing native alert",
            fields: [
                "bundleID": bundleID,
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "pid": String(pid)
            ]
        )

        isEditing = true

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Edit Terminal Title"
        alert.informativeText = "Enter the new title for the terminal window"
        alert.alertStyle = .informational

        let inputField = NSTextField(string: currentTitle)
        inputField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        inputField.cell?.sendsActionOnEndEditing = false
        inputField.font = NSFont.systemFont(ofSize: 13)
        alert.accessoryView = inputField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

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
                applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
            }
        }

        // Re-activate terminal after applyTitle (AppleScript/AX calls may steal focus)
        _ = frontApp.activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - Auto Title

    func autoSetTitle(cwd: String?, pid: pid_t, bundleID: String, window: AXUIElement) {
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

    private func applyTitle(_ newTitle: String, to window: AXUIElement, pid: pid_t, bundleID: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        let axSuccess = applyViaAX(trimmed, to: window)
        let scriptSuccess = applyViaAppleScript(trimmed, bundleID: bundleID)

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
                "bundleID": bundleID
            ]
        )
    }

    private func applyViaAppleScript(_ title: String, bundleID: String) -> Bool {
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            let escaped = title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
                tell application "Terminal"
                    set custom title of selected tab of front window to "\(escaped)"
                    tell current settings of front window
                        set title displays custom title to true
                        set title displays device name to false
                        set title displays shell path to false
                        set title displays window size to false
                        set title displays settings name to false
                    end tell
                end tell
                """
        case "com.googlecode.iterm2":
            let escaped = title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
        default:
            return false
        }

        log(
            "[TitleEditorService] applyViaAppleScript: setting title",
            fields: ["bundleID": bundleID, "title": truncateForLog(title, limit: 60)]
        )

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[TitleEditorService] applyViaAppleScript: FAILED",
                level: .warn,
                fields: ["errorMsg": errorMsg, "errorNum": String(errorNum)]
            )
            if errorNum == -1743 {
                showAutomationPermissionAlert(bundleID: bundleID)
            }
            return false
        }

        log("[TitleEditorService] applyViaAppleScript: success")

        // Diagnostic: read back Terminal.app title state after setting
        if bundleID == "com.apple.Terminal" {
            let diagScript = """
                tell application "Terminal"
                    set ct to custom title of selected tab of front window
                    set s to current settings of front window
                    set ws to title displays window size of s
                    set dvc to title displays device name of s
                    set c to title displays custom title of s
                    return ct & "|" & ws & "|" & dvc & "|" & c
                end tell
                """
            let diagAS = NSAppleScript(source: diagScript)
            var diagErr: NSDictionary?
            if let result = diagAS?.executeAndReturnError(&diagErr), let desc = result.stringValue {
                let parts = desc.components(separatedBy: "|")
                log(
                    "[TitleEditorService] applyViaAppleScript: diagnostic readback",
                    fields: [
                        "customTitle": parts.count > 0 ? parts[0] : "?",
                        "windowSizeEnabled": parts.count > 1 ? parts[1] : "?",
                        "deviceNameEnabled": parts.count > 2 ? parts[2] : "?",
                        "customTitleEnabled": parts.count > 3 ? parts[3] : "?"
                    ]
                )
            }
        }

        return true
    }

    private func applyViaAX(_ title: String, to window: AXUIElement) -> Bool {
        guard WindowManager.shared.isAttributeSettable(window, attribute: kAXTitleAttribute as String) else {
            log(
                "[TitleEditorService] applyViaAX: kAXTitleAttribute not settable",
                level: .debug
            )
            return false
        }

        let result = AXUIElementSetAttributeValue(window, kAXTitleAttribute as CFString, title as CFTypeRef)
        let success = result == .success
        if !success {
            log(
                "[TitleEditorService] applyViaAX: AXUIElementSetAttributeValue failed",
                level: .warn,
                fields: ["axStatus": String(result.rawValue)]
            )
        }
        return success
    }

    private func showAutomationPermissionAlert(bundleID: String) {
        let terminalName: String
        switch bundleID {
        case "com.googlecode.iterm2": terminalName = "iTerm2"
        case "com.apple.Terminal": terminalName = "Terminal"
        default: terminalName = "terminal"
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要 Automation 权限"
            alert.informativeText = "VibeFocus 需要授权才能修改 \(terminalName) 的窗口标题。\n\n请前往：系统设置 → 隐私与安全性 → Automation → 勾选 VibeFocus 对 \(terminalName) 的控制权限。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            alert.window.level = .floating

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
