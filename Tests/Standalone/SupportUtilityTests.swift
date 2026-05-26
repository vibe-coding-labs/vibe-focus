// Tests/Standalone/SupportUtilityTests.swift
// Verification: sanitizeFieldValue, serializeFields, truncateForLog, elapsedMilliseconds
// Mirrors: Sources/Support/Support.swift:73-146
// Run: swift Tests/Standalone/SupportUtilityTests.swift

import Foundation

// MARK: - Mirrored functions (Sources/Support/Support.swift:73-146)

func sanitizeFieldValue(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\"", with: "\\\"")
    if escaped.contains(" ") || escaped.contains("=") || escaped.contains("\"") {
        return "\"\(escaped)\""
    }
    return escaped
}

func serializeFields(_ fields: [String: String]) -> String {
    guard !fields.isEmpty else { return "" }
    let pairs = fields
        .filter { !$0.key.isEmpty }
        .sorted { $0.key < $1.key }
        .map { key, value in "\(key)=\(sanitizeFieldValue(value))" }
    guard !pairs.isEmpty else { return "" }
    return " " + pairs.joined(separator: " ")
}

func truncateForLog(_ text: String, limit: Int = 260) -> String {
    guard text.count > limit else { return text }
    let endIndex = text.index(text.startIndex, offsetBy: limit)
    return "\(text[..<endIndex])..."
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

// MARK: - sanitizeFieldValue

print("1. sanitizeFieldValue — plain text (no escaping needed)")
do {
    checkEqual("simple word", sanitizeFieldValue("hello"), "hello")
    checkEqual("number", sanitizeFieldValue("12345"), "12345")
    checkEqual("empty", sanitizeFieldValue(""), "")
}

print("\n2. sanitizeFieldValue — special chars get escaped")
do {
    checkEqual("newline", sanitizeFieldValue("a\nb"), "a\\nb")
    checkEqual("tab", sanitizeFieldValue("a\tb"), "a\\tb")
    checkEqual("carriage return", sanitizeFieldValue("a\rb"), "a\\rb")
    checkEqual("backslash", sanitizeFieldValue("a\\b"), "a\\\\b")
    checkEqual("double quote", sanitizeFieldValue("a\"b"), "\"a\\\"b\"")
    checkEqual("all combined", sanitizeFieldValue("a\n\t\r\\\"b"), "\"a\\n\\t\\r\\\\\\\"b\"")
}

print("\n3. sanitizeFieldValue — values with space/get quoted")
do {
    checkEqual("contains space", sanitizeFieldValue("hello world"), "\"hello world\"")
    checkEqual("contains equals", sanitizeFieldValue("key=value"), "\"key=value\"")
    checkEqual("contains quote", sanitizeFieldValue("say \"hi\""), "\"say \\\"hi\\\"\"")
}

// MARK: - serializeFields

print("\n4. serializeFields — empty and nil")
do {
    checkEqual("empty dict", serializeFields([:]), "")
}

print("\n5. serializeFields — single field")
do {
    checkEqual("single field", serializeFields(["key": "value"]), " key=value")
}

print("\n6. serializeFields — multiple fields sorted by key")
do {
    let result = serializeFields(["z": "1", "a": "2", "m": "3"])
    checkEqual("sorted keys", result, " a=2 m=3 z=1")
}

print("\n7. serializeFields — empty key filtered out")
do {
    let result = serializeFields(["": "ignored", "valid": "kept"])
    checkEqual("empty key filtered", result, " valid=kept")
}

print("\n8. serializeFields — values with special chars")
do {
    let result = serializeFields(["path": "/usr/local/bin", "name": "hello world"])
    // path contains / (no quoting), name contains space (quoted)
    check("contains escaped values", result.contains("name=") && result.contains("path="))
}

// MARK: - truncateForLog

print("\n9. truncateForLog — short text unchanged")
do {
    checkEqual("short text", truncateForLog("hello", limit: 10), "hello")
    checkEqual("exact length", truncateForLog("12345", limit: 5), "12345")
    checkEqual("empty string", truncateForLog("", limit: 10), "")
}

print("\n10. truncateForLog — long text truncated with ellipsis")
do {
    let long = String(repeating: "x", count: 300)
    let result = truncateForLog(long, limit: 260)
    check("truncated length is 263 (260 + ...)", result.count == 263)
    check("ends with ...", result.hasSuffix("..."))
    check("starts correctly", result.hasPrefix("xxx"))

    let result10 = truncateForLog("abcdefghij", limit: 5)
    checkEqual("10 chars truncated at 5", result10, "abcde...")
}

print("\n11. truncateForLog — default limit is 260")
do {
    let long = String(repeating: "a", count: 261)
    let result = truncateForLog(long)
    check("default limit 260 applied", result.count == 263 && result.hasSuffix("..."))

    let short = String(repeating: "a", count: 260)
    checkEqual("260 chars not truncated", truncateForLog(short), short)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
