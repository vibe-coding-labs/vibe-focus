import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

/// Tests for HookEventHandler decision logic — real static methods.
@Suite("HookEventHandler Decision Logic")
@MainActor
struct DirectActorTests {

    @Test("isTerminalOrIDEApp: detects Terminal.app")
    func isTerminalApp() {
        #expect(HookEventHandler.isTerminalOrIDEApp(appName: "Terminal", bundleIdentifier: "com.apple.Terminal"))
    }

    @Test("isTerminalOrIDEApp: detects iTerm2")
    func isITerm() {
        #expect(HookEventHandler.isTerminalOrIDEApp(appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"))
    }

    @Test("isTerminalOrIDEApp: detects Cursor")
    func isCursor() {
        #expect(HookEventHandler.isTerminalOrIDEApp(appName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
    }

    @Test("isTerminalOrIDEApp: detects VS Code")
    func isVSCode() {
        #expect(HookEventHandler.isTerminalOrIDEApp(appName: "Code", bundleIdentifier: "com.microsoft.VSCode"))
    }

    @Test("isTerminalOrIDEApp: rejects non-terminal")
    func isNotTerminal() {
        #expect(!HookEventHandler.isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Safari"))
        #expect(!HookEventHandler.isTerminalOrIDEApp(appName: "Finder", bundleIdentifier: "com.apple.finder"))
    }

    @Test("isTerminalOrIDEApp: nil inputs")
    func isTerminalNil() {
        #expect(!HookEventHandler.isTerminalOrIDEApp(appName: nil, bundleIdentifier: nil))
        #expect(!HookEventHandler.isTerminalOrIDEApp(appName: "", bundleIdentifier: ""))
    }
}
