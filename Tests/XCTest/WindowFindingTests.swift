import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Window Finding Strategy")
@MainActor
struct WindowFindingTests {

    /// Helper: create a WindowCandidate
    func candidate(
        windowID: UInt32 = 1,
        pid: pid_t = 100,
        appName: String = "Terminal",
        bundleIdentifier: String? = "com.apple.Terminal",
        title: String = "bash",
        isOnMainScreen: Bool = false
    ) -> WindowManager.WindowCandidate {
        WindowManager.WindowCandidate(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            isOnMainScreen: isOnMainScreen
        )
    }

    /// Matches terminal and IDE apps via TerminalRegistry
    let isHostApp: (WindowManager.WindowCandidate) -> Bool = { c in
        TerminalRegistry.isTerminalOrIDEApp(appName: c.appName, bundleIdentifier: c.bundleIdentifier)
    }

    // MARK: - Strategy 1: Host app + cwd project name

    @Test("findBestCandidate: strategy 1 — host app with project name in title")
    func strategy1HostAppCwd() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "vim — vibe-focus"),
            candidate(windowID: 2, appName: "Safari", title: "vibe-focus — Google"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/projects/vibe-focus",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: strategy 1 — project name match is case-insensitive")
    func strategy1CaseInsensitive() {
        let candidates = [
            candidate(windowID: 1, appName: "iTerm2", title: "VIBE-FOCUS — zsh"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/vibe-focus",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: strategy 1 — non-host app with project name is skipped")
    func strategy1SkipsNonHost() {
        let candidates = [
            candidate(windowID: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari", title: "vibe-focus — docs"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/vibe-focus",
            isHostApp: isHostApp
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: strategy 1 — empty cwd skips to strategy 2")
    func strategy1EmptyCwd() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "vim — myproject"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: isHostApp
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: strategy 1 — cwd with trailing slash extracts project name")
    func strategy1TrailingSlash() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "node — my-app"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/projects/my-app/",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: strategy 1 — root path has empty project name")
    func strategy1RootPath() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "bash"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/",
            isHostApp: isHostApp
        )
        // project name is empty after trimming /, so strategy 1 is skipped
        #expect(result == nil)
    }

    // MARK: - Strategy 2: Host app + "Claude Code"

    @Test("findBestCandidate: strategy 2 — host app with 'Claude Code' in title")
    func strategy2ClaudeCode() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "Claude Code — opus"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: strategy 2 — 'claude code' is case-insensitive")
    func strategy2CaseInsensitive() {
        let candidates = [
            candidate(windowID: 1, appName: "iTerm2", title: "CLAUDE CODE session"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: strategy 2 — non-host app with 'Claude Code' is skipped")
    func strategy2SkipsNonHost() {
        let candidates = [
            candidate(windowID: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari", title: "Claude Code docs"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: isHostApp
        )
        #expect(result == nil)
    }

    // MARK: - Strategy priority

    @Test("findBestCandidate: strategy 1 takes priority over strategy 2")
    func strategy1OverStrategy2() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "Claude Code — general"),
            candidate(windowID: 2, appName: "Terminal", title: "vim — vibe-focus"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/vibe-focus",
            isHostApp: isHostApp
        )
        // Strategy 1 matches candidate 2 (hostApp + cwd)
        #expect(result?.windowID == 2)
    }

    @Test("findBestCandidate: no candidates returns nil")
    func noCandidates() {
        let result = WindowManager.findBestCandidate(
            candidates: [],
            cwd: "/Users/dev/my-project",
            isHostApp: isHostApp
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: no matching candidates returns nil")
    func noMatchingCandidates() {
        let candidates = [
            candidate(windowID: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari", title: "web page"),
            candidate(windowID: 2, appName: "Finder", bundleIdentifier: "com.apple.finder", title: "Documents"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/my-project",
            isHostApp: isHostApp
        )
        #expect(result == nil)
    }

    // MARK: - Multi-candidate selection

    @Test("findBestCandidate: returns first match when multiple candidates qualify")
    func firstMatchWins() {
        let candidates = [
            candidate(windowID: 1, appName: "Terminal", title: "vim — myproject"),
            candidate(windowID: 2, appName: "iTerm2", title: "zsh — myproject"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/myproject",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: Cursor IDE detected as host app")
    func cursorIsHostApp() {
        let candidates = [
            candidate(windowID: 1, appName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", title: "main.ts — my-app"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/my-app",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: VS Code detected as host app")
    func vscodeIsHostApp() {
        let candidates = [
            candidate(windowID: 1, appName: "Code", bundleIdentifier: "com.microsoft.VSCode", title: "index.js — cool-project"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/cool-project",
            isHostApp: isHostApp
        )
        #expect(result?.windowID == 1)
    }
}
