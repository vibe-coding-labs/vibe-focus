// Tests/Standalone/IPSParserTests.swift
// Verification: parseIPSJSONPayload — extract JSON payload from macOS .ips crash report
// Mirrors: Sources/Support/CrashContextRecorder.swift:173-189
// Run: swift Tests/Standalone/IPSParserTests.swift

import Foundation

// MARK: - Mirrored function (CrashContextRecorder.swift:173-189)

func parseIPSJSONPayload(from reportText: String) -> [String: Any]? {
    let lines = reportText.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count >= 2 else {
        return nil
    }
    let payloadText = lines.dropFirst().joined(separator: "\n")
    guard let data = payloadText.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let payload = object as? [String: Any] else {
        return nil
    }
    return payload
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

// MARK: - Valid IPS report

print("1. parseIPSJSONPayload — valid two-line report")
do {
    let report = """
    header_line
    {"key": "value", "number": 42}
    """
    let result = parseIPSJSONPayload(from: report)
    check("parses successfully", result != nil)
    checkEqual("key extracted", result?["key"] as? String, "value")
    checkEqual("number extracted", result?["number"] as? Int, 42)
}

print("\n2. parseIPSJSONPayload — multi-line JSON payload")
do {
    let report = """
    os_name
    {
      "appName": "VibeFocus",
      "exception": {"type": "SIGSEGV", "signal": "11"},
      "threads": [1, 2, 3]
    }
    """
    let result = parseIPSJSONPayload(from: report)
    check("multi-line parses", result != nil)
    checkEqual("appName", result?["appName"] as? String, "VibeFocus")
    let exception = result?["exception"] as? [String: Any]
    checkEqual("exception.type", exception?["type"] as? String, "SIGSEGV")
    checkEqual("exception.signal", exception?["signal"] as? String, "11")
    let threads = result?["threads"] as? [Int]
    checkEqual("threads count", threads?.count, 3)
}

print("\n3. parseIPSJSONPayload — first line is header, dropped")
do {
    let report = """
    macOS 14.5 (23F79)
    {"os": "macOS", "version": "14.5"}
    """
    let result = parseIPSJSONPayload(from: report)
    check("parses", result != nil)
    checkEqual("os", result?["os"] as? String, "macOS")
    // header line is NOT in the result
    check("no 'header_line' key in result", result?["header_line"] == nil)
}

// MARK: - Edge cases

print("\n4. parseIPSJSONPayload — single line (too few lines)")
do {
    let report = "only one line"
    check("single line → nil", parseIPSJSONPayload(from: report) == nil)
}

print("\n5. parseIPSJSONPayload — empty string")
do {
    check("empty string → nil", parseIPSJSONPayload(from: "") == nil)
}

print("\n6. parseIPSJSONPayload — two lines but second is not JSON")
do {
    let report = """
    header
    not-json-at-all
    """
    check("invalid JSON → nil", parseIPSJSONPayload(from: report) == nil)
}

print("\n7. parseIPSJSONPayload — second line is JSON array (not object)")
do {
    let report = """
    header
    [1, 2, 3]
    """
    // JSONSerialization produces NSArray, not NSDictionary → cast to [String: Any] fails
    check("JSON array → nil", parseIPSJSONPayload(from: report) == nil)
}

print("\n8. parseIPSJSONPayload — second line is empty JSON object")
do {
    let report = """
    header
    {}
    """
    let result = parseIPSJSONPayload(from: report)
    check("empty object parses", result != nil)
    checkEqual("empty object count", result?.count, 0)
}

print("\n9. parseIPSJSONPayload — second line is just a JSON string value")
do {
    let report = """
    header
    "hello"
    """
    // Top-level JSON string is valid JSON but not a [String: Any]
    check("top-level string → nil", parseIPSJSONPayload(from: report) == nil)
}

print("\n10. parseIPSJSONPayload — second line is JSON null")
do {
    let report = """
    header
    null
    """
    check("null → nil", parseIPSJSONPayload(from: report) == nil)
}

print("\n11. parseIPSJSONPayload — second line is JSON boolean")
do {
    let report = """
    header
    true
    """
    check("boolean → nil", parseIPSJSONPayload(from: report) == nil)
}

// MARK: - Realistic IPS report structure

print("\n12. parseIPSJSONPayload — realistic macOS IPS report excerpt")
do {
    let report = """
    {"app_name":"VibeFocus","timestamp":"2026-05-25T00:00:00Z","os_version":"macOS 15.5"}
    {"proc_name":"VibeFocus","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000000"},"pid":12345,"threads":[{"id":1,"frames":[{"image":"VibeFocus","addr":123456}]}]}
    """
    // In real .ips files, first line is header JSON, second is payload JSON
    // But our parser drops first line regardless
    let result = parseIPSJSONPayload(from: report)
    check("realistic report parses", result != nil)
    checkEqual("proc_name", result?["proc_name"] as? String, "VibeFocus")
    let exception = result?["exception"] as? [String: Any]
    checkEqual("exception type", exception?["type"] as? String, "EXC_BAD_ACCESS")
    checkEqual("pid", result?["pid"] as? Int, 12345)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
