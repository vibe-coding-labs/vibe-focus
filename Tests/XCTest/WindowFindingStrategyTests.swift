import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Window Finding Strategy")
@MainActor
struct WindowFindingStrategyTests {

    private func makeCandidate(
        windowID: UInt32 = 1,
        pid: Int32 = 100,
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

    // MARK: - Strategy 1: hostApp + cwd project name in title

    @Test("findBestCandidate: host app + cwd project name match")
    func hostAppCwdMatch() {
        let candidates = [
            makeCandidate(windowID: 1, title: "vim — zsh"),
            makeCandidate(windowID: 2, title: "~/projects/myapp — bash"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/projects/myapp",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 2)
    }

    @Test("findBestCandidate: cwd match is case-insensitive")
    func cwdCaseInsensitive() {
        let candidates = [
            makeCandidate(windowID: 1, title: "MyApp — zsh"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/dev/myapp",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: ignores non-host app even with cwd match")
    func nonHostAppSkipped() {
        let candidates = [
            makeCandidate(windowID: 1, appName: "Safari", title: "myapp — Safari"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/dev/myapp",
            isHostApp: { $0.appName != "Safari" }
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: nil cwd skips strategy 1, tries strategy 2")
    func nilCwdFallsToStrategy2() {
        let candidates = [
            makeCandidate(windowID: 1, title: "Claude Code — zsh"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: empty cwd skips strategy 1")
    func emptyCwdFallsToStrategy2() {
        let candidates = [
            makeCandidate(windowID: 1, title: "Claude Code — zsh"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: cwd with trailing slash extracts last component")
    func cwdTrailingSlash() {
        let candidates = [
            makeCandidate(windowID: 1, title: "myproject — bash"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/Users/dev/myproject/",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 1)
    }

    // MARK: - Strategy 2: hostApp + "Claude Code" in title

    @Test("findBestCandidate: 'claude code' in title matches (case insensitive)")
    func claudeCodeMatch() {
        let candidates = [
            makeCandidate(windowID: 1, title: "CLAUDE CODE session"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/some/other/project",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 1)
    }

    @Test("findBestCandidate: 'claude code' match requires host app")
    func claudeCodeRequiresHostApp() {
        let candidates = [
            makeCandidate(windowID: 1, appName: "Chrome", bundleIdentifier: "com.google.Chrome", title: "Claude Code"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: { $0.appName != "Chrome" }
        )
        #expect(result == nil)
    }

    // MARK: - No match

    @Test("findBestCandidate: no candidates returns nil")
    func noCandidates() {
        let result = WindowManager.findBestCandidate(
            candidates: [],
            cwd: "/dev/project",
            isHostApp: { _ in true }
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: no host app candidates returns nil")
    func noHostAppCandidates() {
        let candidates = [
            makeCandidate(windowID: 1, appName: "Safari", title: "Safari"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: nil,
            isHostApp: { $0.appName != "Safari" }
        )
        #expect(result == nil)
    }

    @Test("findBestCandidate: strategy 1 takes priority over strategy 2")
    func strategy1Priority() {
        let candidates = [
            makeCandidate(windowID: 1, title: "Claude Code"),
            makeCandidate(windowID: 2, title: "myproject — bash"),
        ]
        let result = WindowManager.findBestCandidate(
            candidates: candidates,
            cwd: "/dev/myproject",
            isHostApp: { _ in true }
        )
        #expect(result?.windowID == 2)
    }
}
