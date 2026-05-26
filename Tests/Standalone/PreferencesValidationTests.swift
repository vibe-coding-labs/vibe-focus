// Tests/Standalone/PreferencesValidationTests.swift
// Verification: Port normalization and shell string escaping
// Mirrors: Sources/Hook/ClaudeHookPreferences.swift:179-181 (normalizePort)
//          Sources/Hook/ClaudeHookPreferences.swift:684-687 (sanitizedForShell)
// Run: swift Tests/Standalone/PreferencesValidationTests.swift

import Foundation

// MARK: - normalizePort (mirrors ClaudeHookPreferences.swift:179-181)

func normalizePort(_ value: Int) -> Int {
    min(max(value, 1024), 65535)
}

// MARK: - sanitizedForShell (mirrors ClaudeHookPreferences.swift:684-687)

extension String {
    func sanitizedForShell() -> String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual(_ name: String, _ a: String, _ b: String) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected '\(b)', got '\(a)'") }
}

func checkEqual(_ name: String, _ a: Int, _ b: Int) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - normalizePort

print("1. normalizePort — valid range")
do {
    checkEqual("port 8080", normalizePort(8080), 8080)
    checkEqual("port 39277", normalizePort(39277), 39277)
    checkEqual("port 1024 (min)", normalizePort(1024), 1024)
    checkEqual("port 65535 (max)", normalizePort(65535), 65535)
}

print("\n2. normalizePort — below minimum")
do {
    checkEqual("port 0 → 1024", normalizePort(0), 1024)
    checkEqual("port 80 → 1024", normalizePort(80), 1024)
    checkEqual("port 1023 → 1024", normalizePort(1023), 1024)
    checkEqual("port -1 → 1024", normalizePort(-1), 1024)
    checkEqual("port -9999 → 1024", normalizePort(-9999), 1024)
}

print("\n3. normalizePort — above maximum")
do {
    checkEqual("port 65536 → 65535", normalizePort(65536), 65535)
    checkEqual("port 99999 → 65535", normalizePort(99999), 65535)
    checkEqual("port 1000000 → 65535", normalizePort(1000000), 65535)
}

print("\n4. normalizePort — boundary values")
do {
    checkEqual("port 1025", normalizePort(1025), 1025)
    checkEqual("port 65534", normalizePort(65534), 65534)
}

// MARK: - sanitizedForShell

print("\n5. sanitizedForShell — no special chars")
do {
    checkEqual("simple string", "hello".sanitizedForShell(), "'hello'")
    checkEqual("empty string", "".sanitizedForShell(), "''")
    checkEqual("path", "/usr/local/bin".sanitizedForShell(), "'/usr/local/bin'")
}

print("\n6. sanitizedForShell — single quotes (the main escaping case)")
do {
    // The escaping replaces ' with '\'' which ends the current single-quoted
    // segment, adds an escaped single quote, and starts a new single-quoted segment
    checkEqual("one quote", "it's".sanitizedForShell(), "'it'\\''s'")
    checkEqual("leading quote", "'hello".sanitizedForShell(), "''\\''hello'")
    checkEqual("trailing quote", "hello'".sanitizedForShell(), "'hello'\\'''")
    checkEqual("two quotes", "a'b'c".sanitizedForShell(), "'a'\\''b'\\''c'")
}

print("\n7. sanitizedForShell — mixed special chars")
do {
    // Only single quotes are escaped; other chars pass through
    checkEqual("double quotes", "say \"hi\"".sanitizedForShell(), "'say \"hi\"'")
    checkEqual("backslash", "path\\to\\file".sanitizedForShell(), "'path\\to\\file'")
    checkEqual("dollar sign", "$HOME".sanitizedForShell(), "'$HOME'")
    checkEqual("backtick", "`cmd`".sanitizedForShell(), "'`cmd`'")
}

print("\n8. sanitizedForShell — URL with special chars")
do {
    let url = "http://127.0.0.1:39277/claude/hook?token=abc-123"
    checkEqual("URL passthrough", url.sanitizedForShell(), "'\(url)'")
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
