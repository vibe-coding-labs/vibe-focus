// Tests/Standalone/ErrorHandlingTests.swift
// Verification: 错误日志级别分类、诊断信息完整性
// Mirrors: Sources/Space/SpaceController+Query.swift:28-66, 117-173
// Run: swift Tests/Standalone/ErrorHandlingTests.swift

import Foundation

// MARK: - Mirrored types

struct MockShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - Test helpers

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Error classification logic (mirrors SpaceController+Query.swift)

/// 判断 yabai query 失败是否为预期场景
/// - Parameter stderr: yabai 命令的 stderr 输出
/// - Returns: true 表示预期失败（应使用 debug 级别），false 表示异常失败（应使用 warn/error 级别）
func isExpectedQueryFailure(_ stderr: String) -> Bool {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    // 预期失败场景：
    // 1. "could not retrieve window details" — 无焦点窗口（用户点击桌面、所有窗口最小化）
    // 2. "could not locate window" — 窗口 ID 无效（窗口已关闭）
    return trimmed.contains("could not retrieve window details") ||
           trimmed.contains("could not locate window")
}

/// 判断 yabai query 失败是否需要记录详细诊断
/// - Parameter stderr: yabai 命令的 stderr 输出
/// - Returns: true 表示需要详细日志，false 表示简单日志即可
func needsDetailedDiagnostics(_ stderr: String) -> Bool {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    // 异常失败需要详细诊断
    return !isExpectedQueryFailure(trimmed)
}

// MARK: - Tests

print("=== Error Handling Tests ===\n")

// Test 1: 预期失败场景 — 无焦点窗口
print("1. 预期失败：无焦点窗口")
do {
    let stderr = "could not retrieve window details"
    check("应识别为预期失败", isExpectedQueryFailure(stderr))
    check("不需要详细诊断", !needsDetailedDiagnostics(stderr))
}

// Test 2: 预期失败场景 — 窗口不存在
print("\n2. 预期失败：窗口不存在")
do {
    let stderr = "could not locate window"
    check("应识别为预期失败", isExpectedQueryFailure(stderr))
    check("不需要详细诊断", !needsDetailedDiagnostics(stderr))
}

// Test 3: 异常失败场景 — 权限错误
print("\n3. 异常失败：权限错误")
do {
    let stderr = "yabai: permission denied"
    check("应识别为异常失败", !isExpectedQueryFailure(stderr))
    check("需要详细诊断", needsDetailedDiagnostics(stderr))
}

// Test 4: 异常失败场景 — SA 错误
print("\n4. 异常失败：Scripting Addition 错误")
do {
    let stderr = "scripting-addition is not loaded"
    check("应识别为异常失败", !isExpectedQueryFailure(stderr))
    check("需要详细诊断", needsDetailedDiagnostics(stderr))
}

// Test 5: 异常失败场景 — 空输出
print("\n5. 异常失败：空 stderr")
do {
    let stderr = ""
    check("应识别为异常失败", !isExpectedQueryFailure(stderr))
    check("需要详细诊断", needsDetailedDiagnostics(stderr))
}

// Test 6: 预期失败带额外文本
print("\n6. 预期失败：带额外文本")
do {
    let stderr = "yabai: could not retrieve window details (no window has focus)"
    check("应识别为预期失败", isExpectedQueryFailure(stderr))
    check("不需要详细诊断", !needsDetailedDiagnostics(stderr))
}

// Test 7: 窗口不存在带窗口 ID
print("\n7. 预期失败：窗口不存在（带窗口 ID）")
do {
    let stderr = "yabai: could not locate window with id '12345'"
    check("应识别为预期失败", isExpectedQueryFailure(stderr))
    check("不需要详细诊断", !needsDetailedDiagnostics(stderr))
}

// Test 8: 空白字符处理
print("\n8. 边界情况：只有空白字符")
do {
    let stderr = "   \n\t  "
    check("应识别为异常失败", !isExpectedQueryFailure(stderr))
    check("需要详细诊断", needsDetailedDiagnostics(stderr))
}

// MARK: - Summary

print("\n=== Summary ===")
print("Passed: \(passed)")
print("Failed: \(failed)")

if failed > 0 {
    print("\n❌ Some tests failed")
    exit(1)
} else {
    print("\n✅ All tests passed")
    exit(0)
}
