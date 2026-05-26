import Testing
import Foundation
@testable import VibeFocusKit

@Suite("TerminalRegistry")
struct TerminalRegistryTests {

    @Test("terminalBundleIDs contains known terminals")
    func terminalBundleIDs() {
        let known = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
            "io.alacritty",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
        ]
        for id in known {
            #expect(TerminalRegistry.terminalBundleIDs.contains(id), "Missing terminal bundleID: \(id)")
        }
    }

    @Test("ideBundleIDs contains known IDEs")
    func ideBundleIDs() {
        #expect(TerminalRegistry.ideBundleIDs.contains("com.microsoft.VSCode"))
        #expect(TerminalRegistry.ideBundleIDs.contains("com.todesktop.230313mzl4w4u92"))
    }

    @Test("terminalAppNames contains known names")
    func terminalAppNames() {
        let known = ["Terminal", "iTerm2", "Warp", "Ghostty", "kitty", "WezTerm"]
        for name in known {
            #expect(TerminalRegistry.terminalAppNames.contains(name), "Missing terminal name: \(name)")
        }
    }

    @Test("ideAppNames contains known names")
    func ideAppNames() {
        let known = ["Cursor", "Code", "Visual Studio Code"]
        for name in known {
            #expect(TerminalRegistry.ideAppNames.contains(name), "Missing IDE name: \(name)")
        }
    }

    @Test("isTerminalBundleID: returns true for terminal bundleIDs")
    func isTerminalBundleIDTrue() {
        #expect(TerminalRegistry.isTerminalBundleID("com.apple.Terminal"))
        #expect(TerminalRegistry.isTerminalBundleID("com.googlecode.iterm2"))
    }

    @Test("isTerminalBundleID: returns false for IDE bundleIDs")
    func isTerminalBundleIDFalseForIDE() {
        #expect(!TerminalRegistry.isTerminalBundleID("com.microsoft.VSCode"))
        #expect(!TerminalRegistry.isTerminalBundleID("com.todesktop.230313mzl4w4u92"))
    }

    @Test("isTerminalBundleID: returns false for unknown bundleIDs")
    func isTerminalBundleIDFalseForUnknown() {
        #expect(!TerminalRegistry.isTerminalBundleID("com.apple.Safari"))
        #expect(!TerminalRegistry.isTerminalBundleID("com.apple.finder"))
    }

    @Test("allTerminalAndIDEBundleIDs is union of terminal + IDE")
    func allBundleIDsIsUnion() {
        let combined = TerminalRegistry.allTerminalAndIDEBundleIDs
        #expect(combined.isSuperset(of: TerminalRegistry.terminalBundleIDs))
        #expect(combined.isSuperset(of: TerminalRegistry.ideBundleIDs))
        #expect(combined.count == TerminalRegistry.terminalBundleIDs.count + TerminalRegistry.ideBundleIDs.count)
    }

    @Test("allTerminalAndIDEAppNames is union of terminal + IDE")
    func allAppNamesIsUnion() {
        let combined = TerminalRegistry.allTerminalAndIDEAppNames
        #expect(combined.isSuperset(of: TerminalRegistry.terminalAppNames))
        #expect(combined.isSuperset(of: TerminalRegistry.ideAppNames))
        #expect(combined.count == TerminalRegistry.terminalAppNames.count + TerminalRegistry.ideAppNames.count)
    }

    @Test("isTerminalOrIDEApp: detects by appName only")
    func detectsByAppName() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Terminal", bundleIdentifier: nil))
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: "Cursor", bundleIdentifier: nil))
    }

    @Test("isTerminalOrIDEApp: detects by bundleID only")
    func detectsByBundleID() {
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.apple.Terminal"))
        #expect(TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.microsoft.VSCode"))
    }

    @Test("isTerminalOrIDEApp: rejects unknown app")
    func rejectsUnknown() {
        #expect(!TerminalRegistry.isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Safari"))
    }

    @Test("isTerminalOrIDEApp: nil inputs return false")
    func nilInputsReturnFalse() {
        #expect(!TerminalRegistry.isTerminalOrIDEApp(appName: nil, bundleIdentifier: nil))
    }
}
