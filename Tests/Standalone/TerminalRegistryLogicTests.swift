// Tests/Standalone/TerminalRegistryLogicTests.swift
// Verification: isTerminalOrIDEApp, isTerminalBundleID, allTerminalAndIDEBundleIDs/AppNames
// Mirrors: Sources/Support/TerminalRegistry.swift:1-94
// Run: swift Tests/Standalone/TerminalRegistryLogicTests.swift

import Foundation

// MARK: - Mirrored data (TerminalRegistry.swift:9-45)

let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "com.electron.hyper",
    "org.tabby",
]

let terminalAppNames: Set<String> = [
    "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
    "WezTerm", "Hyper", "Tabby",
]

let ideBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.todesktop.230313mzl4w4u92",
]

let ideAppNames: Set<String> = [
    "Cursor", "Code", "Visual Studio Code",
]

let allTerminalAndIDEBundleIDs = terminalBundleIDs.union(ideBundleIDs)
let allTerminalAndIDEAppNames = terminalAppNames.union(ideAppNames)

// Mirrors TerminalRegistry.swift:62-66
func isTerminalOrIDEApp(appName: String?, bundleIdentifier: String?) -> Bool {
    if let appName, terminalAppNames.contains(appName) || ideAppNames.contains(appName) { return true }
    if let bundleIdentifier, terminalBundleIDs.contains(bundleIdentifier) || ideBundleIDs.contains(bundleIdentifier) { return true }
    return false
}

// Mirrors TerminalRegistry.swift:68-70
func isTerminalBundleID(_ bundleID: String) -> Bool {
    return terminalBundleIDs.contains(bundleID)
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - isTerminalBundleID

print("1. isTerminalBundleID — known terminal bundle IDs")
do {
    check("Terminal", isTerminalBundleID("com.apple.Terminal"))
    check("iTerm2", isTerminalBundleID("com.googlecode.iterm2"))
    check("Warp", isTerminalBundleID("dev.warp.Warp-Stable"))
    check("Ghostty", isTerminalBundleID("com.mitchellh.ghostty"))
    check("Alacritty", isTerminalBundleID("io.alacritty"))
    check("kitty", isTerminalBundleID("net.kovidgoyal.kitty"))
    check("WezTerm", isTerminalBundleID("com.github.wez.wezterm"))
    check("Hyper", isTerminalBundleID("com.electron.hyper"))
    check("Tabby", isTerminalBundleID("org.tabby"))
}

print("\n2. isTerminalBundleID — non-terminal bundle IDs")
do {
    check("VSCode is NOT terminal", !isTerminalBundleID("com.microsoft.VSCode"))
    check("Cursor is NOT terminal", !isTerminalBundleID("com.todesktop.230313mzl4w4u92"))
    check("Safari is NOT terminal", !isTerminalBundleID("com.apple.Safari"))
    check("random string is NOT terminal", !isTerminalBundleID("com.example.app"))
    check("empty string is NOT terminal", !isTerminalBundleID(""))
}

// MARK: - isTerminalOrIDEApp

print("\n3. isTerminalOrIDEApp — terminal by appName")
do {
    check("Terminal by name", isTerminalOrIDEApp(appName: "Terminal", bundleIdentifier: nil))
    check("iTerm2 by name", isTerminalOrIDEApp(appName: "iTerm2", bundleIdentifier: nil))
    check("Warp by name", isTerminalOrIDEApp(appName: "Warp", bundleIdentifier: nil))
    check("Ghostty by name", isTerminalOrIDEApp(appName: "Ghostty", bundleIdentifier: nil))
}

print("\n4. isTerminalOrIDEApp — terminal by bundleID")
do {
    check("Terminal by bundleID", isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.apple.Terminal"))
    check("iTerm2 by bundleID", isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.googlecode.iterm2"))
    check("kitty by bundleID", isTerminalOrIDEApp(appName: nil, bundleIdentifier: "net.kovidgoyal.kitty"))
}

print("\n5. isTerminalOrIDEApp — IDE by appName")
do {
    check("Cursor by name", isTerminalOrIDEApp(appName: "Cursor", bundleIdentifier: nil))
    check("Code by name", isTerminalOrIDEApp(appName: "Code", bundleIdentifier: nil))
    check("Visual Studio Code by name", isTerminalOrIDEApp(appName: "Visual Studio Code", bundleIdentifier: nil))
}

print("\n6. isTerminalOrIDEApp — IDE by bundleID")
do {
    check("VSCode by bundleID", isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.microsoft.VSCode"))
    check("Cursor by bundleID", isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
}

print("\n7. isTerminalOrIDEApp — neither terminal nor IDE")
do {
    check("Safari is neither", !isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: nil))
    check("Chrome is neither", !isTerminalOrIDEApp(appName: "Google Chrome", bundleIdentifier: nil))
    check("both nil → false", !isTerminalOrIDEApp(appName: nil, bundleIdentifier: nil))
    check("unknown bundleID", !isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.example.app"))
}

print("\n8. isTerminalOrIDEApp — mixed: name is terminal, bundleID is IDE")
do {
    // If appName matches terminal, should return true regardless of bundleID
    check("Terminal name + VSCode bundleID", isTerminalOrIDEApp(appName: "Terminal", bundleIdentifier: "com.microsoft.VSCode"))
    // If bundleID matches terminal, should return true regardless of appName
    check("Safari name + Terminal bundleID", isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Terminal"))
}

// MARK: - Combined sets

print("\n9. Combined sets — allTerminalAndIDEBundleIDs")
do {
    check("contains Terminal bundleID", allTerminalAndIDEBundleIDs.contains("com.apple.Terminal"))
    check("contains VSCode bundleID", allTerminalAndIDEBundleIDs.contains("com.microsoft.VSCode"))
    check("contains Cursor bundleID", allTerminalAndIDEBundleIDs.contains("com.todesktop.230313mzl4w4u92"))
    check("does NOT contain Safari", !allTerminalAndIDEBundleIDs.contains("com.apple.Safari"))
}

print("\n10. Combined sets — allTerminalAndIDEAppNames")
do {
    check("contains Terminal name", allTerminalAndIDEAppNames.contains("Terminal"))
    check("contains Cursor name", allTerminalAndIDEAppNames.contains("Cursor"))
    check("contains Code name", allTerminalAndIDEAppNames.contains("Code"))
    check("does NOT contain Safari", !allTerminalAndIDEAppNames.contains("Safari"))
}

// MARK: - Set size sanity

print("\n11. Set sizes match expected")
do {
    check("terminalBundleIDs count >= 9", terminalBundleIDs.count >= 9)
    check("terminalAppNames count >= 9", terminalAppNames.count >= 9)
    check("ideBundleIDs count >= 2", ideBundleIDs.count >= 2)
    check("ideAppNames count >= 3", ideAppNames.count >= 3)
    check("combined bundleIDs >= 11", allTerminalAndIDEBundleIDs.count >= 11)
    check("combined appNames >= 12", allTerminalAndIDEAppNames.count >= 12)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
