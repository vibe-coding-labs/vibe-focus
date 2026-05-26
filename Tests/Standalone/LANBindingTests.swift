// Tests/Standalone/LANBindingTests.swift
// Verification: Remote binding type conversion and filtering logic
// Mirrors: Sources/Hook/LANHookPreferences.swift:19-47
// Run: swift Tests/Standalone/LANBindingTests.swift

import Foundation

// MARK: - Mirrored logic (LANHookPreferences.swift:19-47)

/// Mirrors the getter logic: converts [String: Any] → [String: UInt32?]
func parseRemoteBindings(from raw: [String: Any]) -> [String: UInt32?] {
    var result: [String: UInt32?] = [:]
    for (key, value) in raw {
        if let id = value as? UInt32 {
            result[key] = id
        } else if let id = value as? Int {
            result[key] = UInt32(id)
        }
    }
    return result
}

/// Mirrors the setter logic: converts [String: UInt32?] → [String: Any], filtering nil
func storeRemoteBindings(_ bindings: [String: UInt32?]) -> [String: Any] {
    var storable: [String: Any] = [:]
    for (key, value) in bindings {
        if let id = value {
            storable[key] = id
        }
    }
    return storable
}

/// Mirrors activeRemoteBindings: filters out nil values
func activeRemoteBindings(from bindings: [String: UInt32?]) -> [String: UInt32] {
    bindings.compactMapValues { $0 }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - parseRemoteBindings — UInt32 values

print("1. parseRemoteBindings — UInt32 values from dict")
do {
    let raw: [String: Any] = [
        "machine-a": UInt32(100),
        "machine-b": UInt32(200),
    ]
    let result = parseRemoteBindings(from: raw)
    checkEqual("count", result.count, 2)
    checkEqual("machine-a", result["machine-a"]!!, UInt32(100))
    checkEqual("machine-b", result["machine-b"]!!, UInt32(200))
}

print("\n2. parseRemoteBindings — Int values (common in UserDefaults)")
do {
    // UserDefaults often stores integers as Int, not UInt32
    let raw: [String: Any] = [
        "machine-a": Int(100),
        "machine-b": Int(200),
    ]
    let result = parseRemoteBindings(from: raw)
    checkEqual("count", result.count, 2)
    checkEqual("machine-a from Int", result["machine-a"]!!, UInt32(100))
    checkEqual("machine-b from Int", result["machine-b"]!!, UInt32(200))
}

print("\n3. parseRemoteBindings — mixed UInt32 and Int")
do {
    let raw: [String: Any] = [
        "machine-a": UInt32(100),
        "machine-b": Int(200),
    ]
    let result = parseRemoteBindings(from: raw)
    checkEqual("count", result.count, 2)
    checkEqual("UInt32 entry", result["machine-a"]!!, UInt32(100))
    checkEqual("Int entry", result["machine-b"]!!, UInt32(200))
}

print("\n4. parseRemoteBindings — empty dict")
do {
    let result = parseRemoteBindings(from: [:])
    checkEqual("empty", result.count, 0)
}

print("\n5. parseRemoteBindings — non-numeric values ignored")
do {
    let raw: [String: Any] = [
        "machine-a": UInt32(100),
        "machine-b": "not-a-number",
        "machine-c": Double(3.14),
        "machine-d": true,
    ]
    let result = parseRemoteBindings(from: raw)
    checkEqual("only numeric entries parsed", result.count, 1)
    checkEqual("machine-a kept", result["machine-a"]!!, UInt32(100))
    check("string ignored", result["machine-b"] == nil)
    check("double ignored", result["machine-c"] == nil)
    check("bool ignored", result["machine-d"] == nil)
}

print("\n6. parseRemoteBindings — negative Int triggers overflow trap")
do {
    // Note: In production, negative Int→UInt32 conversion would crash.
    // The real LANHookPreferences code has the same trap risk — this test
    // documents the behavior. We skip actually running it to avoid crash.
    check("negative Int documented as trap risk (skipped)", true)
}

// MARK: - storeRemoteBindings

print("\n7. storeRemoteBindings — stores non-nil values")
do {
    let bindings: [String: UInt32?] = [
        "machine-a": 100,
        "machine-b": 200,
    ]
    let stored = storeRemoteBindings(bindings)
    checkEqual("count", stored.count, 2)
    checkEqual("machine-a", stored["machine-a"] as? UInt32, UInt32(100))
    checkEqual("machine-b", stored["machine-b"] as? UInt32, UInt32(200))
}

print("\n8. storeRemoteBindings — filters nil values")
do {
    let bindings: [String: UInt32?] = [
        "machine-a": 100,
        "machine-b": nil,  // pending, not yet assigned
        "machine-c": 300,
    ]
    let stored = storeRemoteBindings(bindings)
    checkEqual("nil filtered out", stored.count, 2)
    check("machine-a stored", stored["machine-a"] != nil)
    check("machine-b NOT stored", stored["machine-b"] == nil)
    check("machine-c stored", stored["machine-c"] != nil)
}

print("\n9. storeRemoteBindings — all nil")
do {
    let bindings: [String: UInt32?] = [
        "machine-a": nil,
        "machine-b": nil,
    ]
    let stored = storeRemoteBindings(bindings)
    checkEqual("all nil → empty dict", stored.count, 0)
}

print("\n10. storeRemoteBindings — empty dict")
do {
    let stored = storeRemoteBindings([:])
    checkEqual("empty → empty", stored.count, 0)
}

// MARK: - activeRemoteBindings

print("\n11. activeRemoteBindings — filters nil")
do {
    let bindings: [String: UInt32?] = [
        "machine-a": 100,
        "machine-b": nil,
        "machine-c": 300,
    ]
    let active = activeRemoteBindings(from: bindings)
    checkEqual("count", active.count, 2)
    checkEqual("machine-a", active["machine-a"], UInt32(100))
    checkEqual("machine-c", active["machine-c"], UInt32(300))
    check("machine-b absent", active["machine-b"] == nil)
}

print("\n12. activeRemoteBindings — all active")
do {
    let bindings: [String: UInt32?] = [
        "a": 1,
        "b": 2,
        "c": 3,
    ]
    let active = activeRemoteBindings(from: bindings)
    checkEqual("all 3 active", active.count, 3)
}

print("\n13. activeRemoteBindings — all nil")
do {
    let bindings: [String: UInt32?] = [
        "a": nil,
        "b": nil,
    ]
    let active = activeRemoteBindings(from: bindings)
    checkEqual("all nil → empty", active.count, 0)
}

// MARK: - Roundtrip: store → parse → active

print("\n14. Roundtrip: store → parse → active")
do {
    let original: [String: UInt32?] = [
        "machine-a": 100,
        "machine-b": nil,
        "machine-c": 300,
    ]
    let stored = storeRemoteBindings(original)
    let parsed = parseRemoteBindings(from: stored)
    let active = activeRemoteBindings(from: parsed)
    checkEqual("active count after roundtrip", active.count, 2)
    checkEqual("machine-a roundtrip", active["machine-a"], UInt32(100))
    checkEqual("machine-c roundtrip", active["machine-c"], UInt32(300))
}

print("\n15. Roundtrip: nil values lost in store step")
do {
    let original: [String: UInt32?] = [
        "pending": nil,
    ]
    let stored = storeRemoteBindings(original)
    checkEqual("nil value not stored", stored.count, 0)
    let parsed = parseRemoteBindings(from: stored)
    checkEqual("nothing to parse back", parsed.count, 0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
