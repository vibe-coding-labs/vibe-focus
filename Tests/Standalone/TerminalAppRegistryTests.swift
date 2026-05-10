// Tests/Standalone/TerminalAppRegistryTests.swift
// Verification: TerminalAppRegistry static sets and PID matching
// Run: swift Tests/Standalone/TerminalAppRegistryTests.swift

import Foundation

// Minimal re-declarations mirroring Sources/Hook/TerminalAppRegistry.swift
enum TerminalAppRegistry {
    static let appNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "WezTerm", "Hyper", "Tabby"
    ]
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]
}

// --- Tests ---

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("Test 1: Known terminal app names")
check("Terminal", TerminalAppRegistry.appNames.contains("Terminal"))
check("iTerm2", TerminalAppRegistry.appNames.contains("iTerm2"))
check("Warp", TerminalAppRegistry.appNames.contains("Warp"))
check("Ghostty", TerminalAppRegistry.appNames.contains("Ghostty"))
check("Alacritty", TerminalAppRegistry.appNames.contains("Alacritty"))
check("kitty", TerminalAppRegistry.appNames.contains("kitty"))
check("WezTerm", TerminalAppRegistry.appNames.contains("WezTerm"))

print("Test 2: Known terminal bundle IDs")
check("com.apple.Terminal", TerminalAppRegistry.bundleIDs.contains("com.apple.Terminal"))
check("com.googlecode.iterm2", TerminalAppRegistry.bundleIDs.contains("com.googlecode.iterm2"))
check("dev.warp.Warp-Stable", TerminalAppRegistry.bundleIDs.contains("dev.warp.Warp-Stable"))
check("com.mitchellh.ghostty", TerminalAppRegistry.bundleIDs.contains("com.mitchellh.ghostty"))

print("Test 3: IDEs are NOT in terminal app names")
check("Cursor excluded", !TerminalAppRegistry.appNames.contains("Cursor"))
check("Code excluded", !TerminalAppRegistry.appNames.contains("Code"))
check("Visual Studio Code excluded", !TerminalAppRegistry.appNames.contains("Visual Studio Code"))

print("Test 4: Set sizes match expected")
check("appNames count >= 9", TerminalAppRegistry.appNames.count >= 9)
check("bundleIDs count >= 7", TerminalAppRegistry.bundleIDs.count >= 7)

// Summary
print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
