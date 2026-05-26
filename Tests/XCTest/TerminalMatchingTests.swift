import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("Terminal Context Matching Logic")
@MainActor
struct TerminalMatchingTests {

    // MARK: - filterWindowsByPID

    private func makeEntry(windowID: UInt32, ownerPID: pid_t, layer: Int = 0, name: String? = nil) -> CGWindowEntry? {
        var dict: [String: Any] = [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer
        ]
        if let name { dict["kCGWindowName"] = name }
        return CGWindowEntry(from: dict)
    }

    @Test("filterWindowsByPID: filters by PID and layer 0")
    func filterByPIDAndLayer() throws {
        let entries = [
            try #require(makeEntry(windowID: 1, ownerPID: 100, layer: 0)),
            try #require(makeEntry(windowID: 2, ownerPID: 100, layer: 0)),
            try #require(makeEntry(windowID: 3, ownerPID: 200, layer: 0)),
            try #require(makeEntry(windowID: 4, ownerPID: 100, layer: 25)),
        ]
        let result = WindowManager.filterWindowsByPID(
            entries: entries, targetPID: 100,
            appName: "Terminal", bundleID: "com.term"
        )
        #expect(result.count == 2)
        #expect(result[0].windowID == 1)
        #expect(result[1].windowID == 2)
        #expect(result[0].appName == "Terminal")
    }

    @Test("filterWindowsByPID: no matches returns empty")
    func filterNoMatches() throws {
        let entries = [
            try #require(makeEntry(windowID: 1, ownerPID: 100))
        ]
        let result = WindowManager.filterWindowsByPID(
            entries: entries, targetPID: 999,
            appName: nil, bundleID: nil
        )
        #expect(result.isEmpty)
    }

    @Test("filterWindowsByPID: empty entries returns empty")
    func filterEmpty() {
        let result = WindowManager.filterWindowsByPID(
            entries: [], targetPID: 100,
            appName: nil, bundleID: nil
        )
        #expect(result.isEmpty)
    }

    @Test("filterWindowsByPID: preserves title from entry name")
    func filterPreservesTitle() throws {
        let entries = [
            try #require(makeEntry(windowID: 1, ownerPID: 100, name: "vim — bash"))
        ]
        let result = WindowManager.filterWindowsByPID(
            entries: entries, targetPID: 100,
            appName: "Terminal", bundleID: "com.term"
        )
        #expect(result.first?.title == "vim — bash")
    }

    // MARK: - matchCommandToWindowTitle

    @Test("matchCommandToWindowTitle: matches '— vim' pattern")
    func matchVim() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "somefile.txt — vim"),
            WindowIdentity(windowID: 2, pid: 100, bundleIdentifier: nil, appName: nil, title: "bash"),
        ]
        let result = WindowManager.matchCommandToWindowTitle(commands: ["vim"], windows: windows)
        #expect(result?.windowID == 1)
    }

    @Test("matchCommandToWindowTitle: matches '— vim ◂' pattern")
    func matchVimArrow() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "file.py — python ◂"),
        ]
        let result = WindowManager.matchCommandToWindowTitle(commands: ["python"], windows: windows)
        #expect(result?.windowID == 1)
    }

    @Test("matchCommandToWindowTitle: reverses command order (last command first)")
    func matchCommandOrder() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "bash"),
            WindowIdentity(windowID: 2, pid: 100, bundleIdentifier: nil, appName: nil, title: "file.sh — bash"),
        ]
        // Both commands could match "bash" title. With ["zsh", "bash"],
        // "bash" is checked first (reversed order)
        let result = WindowManager.matchCommandToWindowTitle(commands: ["zsh", "bash"], windows: windows)
        #expect(result?.windowID == 2)
    }

    @Test("matchCommandToWindowTitle: case-insensitive matching")
    func matchCaseInsensitive() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "File — Python"),
        ]
        let result = WindowManager.matchCommandToWindowTitle(commands: ["python"], windows: windows)
        #expect(result?.windowID == 1)
    }

    @Test("matchCommandToWindowTitle: no match returns nil")
    func matchNoMatch() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "bash"),
        ]
        let result = WindowManager.matchCommandToWindowTitle(commands: ["vim"], windows: windows)
        #expect(result == nil)
    }

    @Test("matchCommandToWindowTitle: empty commands returns nil")
    func matchEmptyCommands() {
        let windows = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, title: "bash — vim"),
        ]
        let result = WindowManager.matchCommandToWindowTitle(commands: [], windows: windows)
        #expect(result == nil)
    }

    // MARK: - parseCommandBasename

    @Test("parseCommandBasename: single command")
    func parseSingle() {
        let result = WindowManager.parseCommandBasename(from: "/usr/bin/vim")
        #expect(result == ["vim"])
    }

    @Test("parseCommandBasename: multiple lines")
    func parseMultiple() {
        let result = WindowManager.parseCommandBasename(from: "/usr/bin/vim\n/usr/bin/python3\n-bash")
        #expect(result == ["vim", "python3", "-bash"])
    }

    @Test("parseCommandBasename: command with arguments")
    func parseWithArgs() {
        let result = WindowManager.parseCommandBasename(from: "/usr/bin/python3 script.py --flag")
        #expect(result == ["python3"])
    }

    @Test("parseCommandBasename: empty lines skipped")
    func parseEmptyLines() {
        let result = WindowManager.parseCommandBasename(from: "/usr/bin/vim\n\n\n/usr/bin/git")
        #expect(result == ["vim", "git"])
    }

    @Test("parseCommandBasename: whitespace trimmed")
    func parseWhitespace() {
        let result = WindowManager.parseCommandBasename(from: "  /usr/bin/vim  \n  /usr/bin/git  ")
        #expect(result == ["vim", "git"])
    }

    @Test("parseCommandBasename: empty string returns empty")
    func parseEmpty() {
        let result = WindowManager.parseCommandBasename(from: "")
        #expect(result.isEmpty)
    }

    @Test("parseCommandBasename: leading dash on login shell")
    func parseLoginShell() {
        let result = WindowManager.parseCommandBasename(from: "-zsh")
        // URL.lastPathComponent of "-zsh" is "-zsh", then basename = "-zsh"
        // Actually, "-zsh" as a path, lastPathComponent is "-zsh"
        #expect(result.count == 1)
    }
}
