import AppKit
import ApplicationServices.HIServices
import Foundation

@MainActor
class TitleEditorService {
    static let shared = TitleEditorService()

    private let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.electron.hyper",
        "org.tabby"
    ]

    private var isEditing = false

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
                applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
            }
        }
    }

    // MARK: - Title Application

    private func applyTitle(_ newTitle: String, to window: AXUIElement, pid: pid_t, bundleID: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        let axSuccess = applyViaAX(trimmed, to: window)
        // AppleScript first: configures Terminal.app title display settings
        // then TTY overrides with full title via OSC escape sequence
        let scriptSuccess = applyViaAppleScript(trimmed, bundleID: bundleID)
        let ttySuccess = applyViaTTY(trimmed, pid: pid)

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
            return false
        }

        log("[TitleEditorService] applyViaAppleScript: success")
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
}
