// Tests/Standalone/SupportMiscTests.swift
// Verification: makeOperationID, elapsedMilliseconds, verboseLoggingEnabled parsing
// Mirrors: Sources/Support/Support.swift:46-49, 51-67, 130-138
// Run: swift Tests/Standalone/SupportMiscTests.swift

import Foundation

// MARK: - Mirrored functions

// Mirrors Support.swift:130-134
func makeOperationID(prefix: String = "op", sequence: UInt64) -> String {
    let normalizedPrefix = prefix.isEmpty ? "op" : prefix
    return "\(normalizedPrefix)-\(String(format: "%08llu", sequence))"
}

// Mirrors Support.swift:136-138
func elapsedMilliseconds(since startAt: Date) -> Int {
    max(0, Int((Date().timeIntervalSince(startAt) * 1000).rounded()))
}

// Mirrors Support.swift:46-49 verbose logging check
func isVerboseLoggingEnabled(_ envValue: String?) -> Bool {
    let value = envValue?.lowercased() ?? ""
    return value == "1" || value == "true" || value == "yes"
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

// MARK: - makeOperationID

print("1. makeOperationID — default prefix")
do {
    checkEqual("default prefix, seq 1", makeOperationID(sequence: 1), "op-00000001")
    checkEqual("default prefix, seq 0", makeOperationID(sequence: 0), "op-00000000")
    checkEqual("default prefix, seq 99999999", makeOperationID(sequence: 99999999), "op-99999999")
}

print("\n2. makeOperationID — custom prefix")
do {
    checkEqual("custom prefix 'toggle'", makeOperationID(prefix: "toggle", sequence: 42), "toggle-00000042")
    checkEqual("custom prefix 'restore'", makeOperationID(prefix: "restore", sequence: 100), "restore-00000100")
    checkEqual("custom prefix 'hook'", makeOperationID(prefix: "hook", sequence: 7), "hook-00000007")
}

print("\n3. makeOperationID — empty prefix falls back to 'op'")
do {
    checkEqual("empty prefix", makeOperationID(prefix: "", sequence: 1), "op-00000001")
}

print("\n4. makeOperationID — zero-padded formatting")
do {
    checkEqual("1 digit", makeOperationID(sequence: 1), "op-00000001")
    checkEqual("3 digits", makeOperationID(sequence: 123), "op-00000123")
    checkEqual("5 digits", makeOperationID(sequence: 12345), "op-00012345")
    checkEqual("8 digits", makeOperationID(sequence: 12345678), "op-12345678")
}

// MARK: - elapsedMilliseconds

print("\n5. elapsedMilliseconds — zero elapsed")
do {
    let now = Date()
    let elapsed = elapsedMilliseconds(since: now)
    check("same instant ≈ 0ms", elapsed >= 0 && elapsed <= 10)
}

print("\n6. elapsedMilliseconds — known duration")
do {
    let past = Date().addingTimeInterval(-1.5) // 1.5 seconds ago
    let elapsed = elapsedMilliseconds(since: past)
    check("1.5s ago ≈ 1500ms", elapsed >= 1400 && elapsed <= 1600)
}

print("\n7. elapsedMilliseconds — future date (clamped to 0)")
do {
    let future = Date().addingTimeInterval(5.0)
    let elapsed = elapsedMilliseconds(since: future)
    checkEqual("future date → clamped to 0", elapsed, 0)
}

print("\n8. elapsedMilliseconds — long duration")
do {
    let longAgo = Date().addingTimeInterval(-3600.0) // 1 hour ago
    let elapsed = elapsedMilliseconds(since: longAgo)
    check("1 hour ≈ 3,600,000ms", elapsed >= 3_500_000 && elapsed <= 3_700_000)
}

// MARK: - verboseLoggingEnabled parsing

print("\n9. verboseLoggingEnabled — '1' triggers verbose")
do {
    check("'1' → verbose", isVerboseLoggingEnabled("1"))
    check("'true' → verbose", isVerboseLoggingEnabled("true"))
    check("'True' → verbose (case insensitive)", isVerboseLoggingEnabled("True"))
    check("'TRUE' → verbose", isVerboseLoggingEnabled("TRUE"))
    check("'yes' → verbose", isVerboseLoggingEnabled("yes"))
    check("'YES' → verbose", isVerboseLoggingEnabled("YES"))
    check("'Yes' → verbose", isVerboseLoggingEnabled("Yes"))
}

print("\n10. verboseLoggingEnabled — non-verbose values")
do {
    check("'0' → not verbose", !isVerboseLoggingEnabled("0"))
    check("'false' → not verbose", !isVerboseLoggingEnabled("false"))
    check("'no' → not verbose", !isVerboseLoggingEnabled("no"))
    check("'random' → not verbose", !isVerboseLoggingEnabled("random"))
    check("empty string → not verbose", !isVerboseLoggingEnabled(""))
}

print("\n11. verboseLoggingEnabled — nil env value")
do {
    check("nil → not verbose", !isVerboseLoggingEnabled(nil))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
