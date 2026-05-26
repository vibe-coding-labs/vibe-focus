import Testing
import Foundation
@testable import VibeFocusKit

@Suite("TerminalRegistry Matching Logic")
struct TerminalRegistryLogicTests {

    // MARK: - isTerminalOrIDEApp

    @Test("isTerminalOrIDEApp: recognizes Terminal.app by name")
    func terminalAppName() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Terminal", bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: recognizes iTerm2 by bundle ID")
    func itermBundleID() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.googlecode.iterm2"))
    }

    @Test("isTerminalOrIDEApp: recognizes VS Code by name")
    func vsCodeName() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Code", bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: recognizes Cursor by name")
    func cursorName() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Cursor", bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: recognizes Cursor by bundle ID")
    func cursorBundleID() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
    }

    @Test("isTerminalOrIDEApp: recognizes Warp by name")
    func warpName() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Warp", bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: recognizes Ghostty by bundle ID")
    func ghosttyBundleID() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.mitchellh.ghostty"))
    }

    @Test("isTerminalOrIDEApp: rejects Safari")
    func rejectsSafari() {
        #expect(!TerminalRegistry.isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Safari"))
    }

    @Test("isTerminalOrIDEApp: rejects nil both")
    func rejectsNilBoth() {
        #expect(!TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: rejects empty strings")
    func rejectsEmptyStrings() {
        #expect(!TerminalRegistry.isTerminalOrIDEApp(appName: "", bundleIdentifier: ""))
    }

    @Test("isTerminalOrIDEApp: name match with non-matching bundleID still true")
    func nameMatchOverridesBundle() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "iTerm2", bundleIdentifier: "com.example.other"))
    }

    // MARK: - isTerminalBundleID

    @Test("isTerminalBundleID: recognizes com.apple.Terminal")
    func terminalBundleID() {
        #expect(TerminalRegistry.isTerminalBundleID("com.apple.Terminal"))
    }

    @Test("isTerminalBundleID: rejects VS Code (it's IDE, not terminal)")
    func rejectsIDE() {
        #expect(!TerminalRegistry.isTerminalBundleID("com.microsoft.VSCode"))
    }

    @Test("isTerminalBundleID: rejects unknown bundle ID")
    func rejectsUnknown() {
        #expect(!TerminalRegistry.isTerminalBundleID("com.example.app"))
    }

    // MARK: - allTerminalAndIDEBundleIDs / allTerminalAndIDEAppNames

    @Test("allTerminalAndIDEBundleIDs: contains both terminal and IDE bundle IDs")
    func combinedBundleIDs() {
        let all = TerminalRegistry.allTerminalAndIDEBundleIDs
        #expect(all.contains("com.apple.Terminal"))
        #expect(all.contains("com.microsoft.VSCode"))
        #expect(all.contains("com.googlecode.iterm2"))
    }

    @Test("allTerminalAndIDEAppNames: contains both terminal and IDE app names")
    func combinedAppNames() {
        let all = TerminalRegistry.allTerminalAndIDEAppNames
        #expect(all.contains("Terminal"))
        #expect(all.contains("Cursor"))
        #expect(all.contains("iTerm2"))
    }

    @Test("allTerminalAndIDEBundleIDs: does not contain random bundle ID")
    func excludesRandom() {
        #expect(!TerminalRegistry.allTerminalAndIDEBundleIDs.contains("com.apple.Safari"))
    }

    // MARK: - isTerminalPID edge cases

    @Test("isTerminalPID: returns false for pid 0")
    func pidZero() {
        #expect(!TerminalRegistry.isTerminalPID(0))
    }

    @Test("isTerminalPID: returns false for negative pid")
    func pidNegative() {
        #expect(!TerminalRegistry.isTerminalPID(-1))
    }
}
