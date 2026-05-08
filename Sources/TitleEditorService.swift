import AppKit
import ApplicationServices.HIServices
import Darwin
import Foundation

// MARK: - Title Editor Service
// Allows users to edit terminal window titles via AX API and TTY OSC escape sequences
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

    private var activePanel: TitleEditorPanel?

    // MARK: - Public API

    /// Presents a title editor for the frontmost terminal window.
    /// If the frontmost app is not a recognized terminal, this is a no-op.
    func editTitle() {
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
        let windowFrame = WindowManager.shared.frame(of: window)

        log(
            "[TitleEditorService] editTitle: showing editor",
            fields: [
                "bundleID": bundleID,
                "currentTitle": truncateForLog(currentTitle, limit: 60),
                "pid": String(pid)
            ]
        )

        // Dismiss any previously active panel
        activePanel?.close()

        let panel = TitleEditorPanel(
            currentTitle: currentTitle,
            windowFrame: windowFrame,
            onSubmit: { [weak self] newTitle in
                self?.applyTitle(newTitle, to: window, pid: pid, bundleID: bundleID)
                self?.activePanel = nil
            },
            onCancel: { [weak self] in
                self?.activePanel = nil
            }
        )

        activePanel = panel
        panel.show()
    }

    // MARK: - Title Application

    private func applyTitle(_ newTitle: String, to window: AXUIElement, pid: pid_t, bundleID: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log("[TitleEditorService] applyTitle: empty title, skipping")
            return
        }

        // Path A: AX API
        let axSuccess = applyViaAX(trimmed, to: window)

        // Path B: TTY OSC escape sequence
        let ttySuccess = applyViaTTY(trimmed, pid: pid)

        log(
            "[TitleEditorService] applyTitle result",
            fields: [
                "title": truncateForLog(trimmed, limit: 60),
                "axSuccess": String(axSuccess),
                "ttySuccess": String(ttySuccess),
                "bundleID": bundleID
            ]
        )
    }

    /// Path A: Set title via AX API if the kAXTitleAttribute is settable
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

    /// Path B: Write OSC escape sequence to the terminal's TTY device
    private func applyViaTTY(_ title: String, pid: pid_t) -> Bool {
        guard let ttyPath = resolveTTYPath(for: pid) else {
            log(
                "[TitleEditorService] applyViaTTY: could not resolve TTY",
                level: .debug,
                fields: ["pid": String(pid)]
            )
            return false
        }

        let sequence = "\u{1B}]0;\(title)\u{07}"
        return writeTTYSequence(sequence, to: ttyPath)
    }

    // MARK: - TTY Resolution

    private func resolveTTYPath(for pid: pid_t) -> String? {
        let output = WindowManager.shared.runShellCommand("/bin/ps", args: ["-o", "tty=", "-p", String(pid)])
        let tty = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if tty.isEmpty || tty == "??" || tty == "?" {
            return nil
        }

        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    // MARK: - OSC Sequence Writing

    private func writeTTYSequence(_ sequence: String, to ttyPath: String) -> Bool {
        guard let data = sequence.data(using: .utf8) else { return false }

        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            log(
                "[TitleEditorService] writeTTYSequence: open() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
            return false
        }
        defer { close(fd) }

        let written = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, ptr.count)
        }

        let success = written >= 0
        if !success {
            log(
                "[TitleEditorService] writeTTYSequence: write() failed",
                level: .warn,
                fields: ["ttyPath": ttyPath, "errno": String(errno)]
            )
        }
        return success
    }
}
