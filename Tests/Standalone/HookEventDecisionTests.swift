// Tests/Standalone/HookEventDecisionTests.swift
// Verification: Hook event handling decision chains, cooldown logic, session binding decisions
// Mirrors: Sources/Hook/HookEventHandler.swift:18-437
// Run: swift Tests/Standalone/HookEventDecisionTests.swift

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Cooldown check: should skip auto-restore due to recent restore?
/// HookEventHandler.swift:193-195
func isInCooldown(lastRestoreTime: Date?, now: Date, cooldownSeconds: TimeInterval) -> Bool {
    guard let lastRestore = lastRestoreTime else { return false }
    return now.timeIntervalSince(lastRestore) < cooldownSeconds
}

/// SessionStart binding decision: local vs remote
/// HookEventHandler.swift:50-64
enum BindingDecision {
    case local
    case remote(machineLabel: String)
    case noTerminalContext
    case noUsefulContext
}

func decideBinding(hasTerminalCtx: Bool, hasUsefulContext: Bool, isRemote: Bool, machineLabel: String?) -> BindingDecision {
    guard hasTerminalCtx else { return .noTerminalContext }
    guard hasUsefulContext else { return .noUsefulContext }
    if isRemote, let label = machineLabel, !label.isEmpty {
        return .remote(machineLabel: label)
    }
    return .local
}

/// ScreenPosition framesMatch — all 4 dimensions must be within tolerance
/// WindowManager+ScreenPosition.swift:73-78
func framesMatchExact(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
    fabs(lhs.origin.x - rhs.origin.x) <= tolerance &&
    fabs(lhs.origin.y - rhs.origin.y) <= tolerance &&
    fabs(lhs.size.width - rhs.size.width) <= tolerance &&
    fabs(lhs.size.height - rhs.size.height) <= tolerance
}

/// Log level selection based on duration threshold
/// Support.swift:171
func logLevelForDuration(_ durationMs: Int, warnThresholdMs: Int) -> String {
    durationMs >= warnThresholdMs ? "warn" : "info"
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

// MARK: - Cooldown logic

print("1. Cooldown — no previous restore → not in cooldown")
do {
    check("nil lastRestore → not in cooldown", !isInCooldown(lastRestoreTime: nil, now: Date(), cooldownSeconds: 30))
}

print("\n2. Cooldown — recent restore → in cooldown")
do {
    let now = Date()
    let recent = now.addingTimeInterval(-5) // 5s ago, within 30s cooldown
    check("5s ago within 30s cooldown → in cooldown", isInCooldown(lastRestoreTime: recent, now: now, cooldownSeconds: 30))
}

print("\n3. Cooldown — old restore → not in cooldown")
do {
    let now = Date()
    let old = now.addingTimeInterval(-60) // 60s ago, past 30s cooldown
    check("60s ago past 30s cooldown → not in cooldown", !isInCooldown(lastRestoreTime: old, now: now, cooldownSeconds: 30))
}

print("\n4. Cooldown — exact boundary")
do {
    let now = Date()
    // Exactly 30s ago → not in cooldown (< is strict)
    let exact = now.addingTimeInterval(-30)
    check("exactly 30s ago → NOT in cooldown (strict <)", !isInCooldown(lastRestoreTime: exact, now: now, cooldownSeconds: 30))

    // 29.9s ago → in cooldown
    let justBefore = now.addingTimeInterval(-29.9)
    check("29.9s ago → in cooldown", isInCooldown(lastRestoreTime: justBefore, now: now, cooldownSeconds: 30))
}

print("\n5. Cooldown — zero cooldown duration")
do {
    let now = Date()
    let recent = now.addingTimeInterval(-1)
    check("zero cooldown → never in cooldown", !isInCooldown(lastRestoreTime: recent, now: now, cooldownSeconds: 0))
}

// MARK: - Binding decision

print("\n6. BindingDecision — no terminal context")
do {
    let result = decideBinding(hasTerminalCtx: false, hasUsefulContext: false, isRemote: false, machineLabel: nil)
    if case .noTerminalContext = result { check("no terminal ctx → .noTerminalContext", true) }
    else { check("no terminal ctx → .noTerminalContext", false) }
}

print("\n7. BindingDecision — has ctx but not useful")
do {
    let result = decideBinding(hasTerminalCtx: true, hasUsefulContext: false, isRemote: false, machineLabel: nil)
    if case .noUsefulContext = result { check("not useful → .noUsefulContext", true) }
    else { check("not useful → .noUsefulContext", false) }
}

print("\n8. BindingDecision — local binding")
do {
    let result = decideBinding(hasTerminalCtx: true, hasUsefulContext: true, isRemote: false, machineLabel: nil)
    if case .local = result { check("local → .local", true) }
    else { check("local → .local", false) }
}

print("\n9. BindingDecision — remote binding")
do {
    let result = decideBinding(hasTerminalCtx: true, hasUsefulContext: true, isRemote: true, machineLabel: "remote-192-168-1-100")
    if case .remote(let label) = result {
        check("remote → .remote", true)
        check("label preserved", label == "remote-192-168-1-100")
    } else {
        check("remote → .remote", false)
    }
}

print("\n10. BindingDecision — remote but empty label falls back to local")
do {
    let result = decideBinding(hasTerminalCtx: true, hasUsefulContext: true, isRemote: true, machineLabel: "")
    if case .local = result { check("empty label → .local fallback", true) }
    else { check("empty label → .local fallback", false) }
}

print("\n11. BindingDecision — remote but nil label falls back to local")
do {
    let result = decideBinding(hasTerminalCtx: true, hasUsefulContext: true, isRemote: true, machineLabel: nil)
    if case .local = result { check("nil label → .local fallback", true) }
    else { check("nil label → .local fallback", false) }
}

// MARK: - framesMatchExact

print("\n12. framesMatchExact — exact match")
do {
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("exact match", framesMatchExact(frame, frame, tolerance: 5))
}

print("\n13. framesMatchExact — within tolerance on all dimensions")
do {
    let a = CGRect(x: 102, y: 198, width: 803, height: 598)
    let b = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("3px off all dims within 5px tolerance", framesMatchExact(a, b, tolerance: 5))
}

print("\n14. framesMatchExact — one dimension outside tolerance fails")
do {
    let a = CGRect(x: 100, y: 200, width: 806, height: 600) // width 6px off
    let b = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("width 6px off outside 5px → false", !framesMatchExact(a, b, tolerance: 5))

    let c = CGRect(x: 100, y: 206, width: 800, height: 600) // y 6px off
    check("y 6px off outside 5px → false", !framesMatchExact(c, b, tolerance: 5))
}

print("\n15. framesMatchExact — all four dimensions checked independently")
do {
    let target = CGRect(x: 0, y: 0, width: 1920, height: 1117)
    // Only x off by 6
    check("x off → fail", !framesMatchExact(CGRect(x: 6, y: 0, width: 1920, height: 1117), target, tolerance: 5))
    // Only y off by 6
    check("y off → fail", !framesMatchExact(CGRect(x: 0, y: 6, width: 1920, height: 1117), target, tolerance: 5))
    // Only width off by 6
    check("width off → fail", !framesMatchExact(CGRect(x: 0, y: 0, width: 1926, height: 1117), target, tolerance: 5))
    // Only height off by 6
    check("height off → fail", !framesMatchExact(CGRect(x: 0, y: 0, width: 1920, height: 1123), target, tolerance: 5))
}

print("\n16. framesMatchExact — zero tolerance requires exact match")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 100.0001, y: 200, width: 800, height: 600)
    check("0.0001px off with 0 tolerance → false", !framesMatchExact(a, b, tolerance: 0))
    check("exact with 0 tolerance → true", framesMatchExact(a, a, tolerance: 0))
}

// MARK: - Log level selection

print("\n17. logLevelForDuration — below threshold → info")
do {
    checkEqual("100ms < 300ms → info", logLevelForDuration(100, warnThresholdMs: 300), "info")
    checkEqual("0ms → info", logLevelForDuration(0, warnThresholdMs: 300), "info")
    checkEqual("299ms < 300ms → info", logLevelForDuration(299, warnThresholdMs: 300), "info")
}

print("\n18. logLevelForDuration — at/above threshold → warn")
do {
    checkEqual("300ms >= 300ms → warn", logLevelForDuration(300, warnThresholdMs: 300), "warn")
    checkEqual("5000ms → warn", logLevelForDuration(5000, warnThresholdMs: 300), "warn")
    checkEqual("1ms >= 1ms → warn", logLevelForDuration(1, warnThresholdMs: 1), "warn")
}

print("\n19. logLevelForDuration — custom thresholds")
do {
    checkEqual("150ms < 200ms → info", logLevelForDuration(150, warnThresholdMs: 200), "info")
    checkEqual("200ms >= 200ms → warn", logLevelForDuration(200, warnThresholdMs: 200), "warn")
    checkEqual("50ms < 100ms → info", logLevelForDuration(50, warnThresholdMs: 100), "info")
    checkEqual("100ms >= 100ms → warn", logLevelForDuration(100, warnThresholdMs: 100), "warn")
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
