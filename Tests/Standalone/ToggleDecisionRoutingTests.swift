// Tests/Standalone/ToggleDecisionRoutingTests.swift
// Verification: evaluateRestoreDecision 决策树（decideRestore 6-case 枚举）
//               + toggle 路由表（decision × onMainScreen → restore/stuck/move_to_main）
// Mirrors: Sources/Window/WindowManager+Toggle+Decision.swift (decideRestore / RestoreDecision)
//          Sources/Window/WindowManager+Toggle.swift (路由 switch)
// Run: swift Tests/Standalone/ToggleDecisionRoutingTests.swift

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Mirrors WindowManager.RestoreDecision (WindowManager+Toggle+Decision.swift)
enum MirrorRestoreDecision: Equatable {
    case restore
    case moveToMain
    case noRecord
    case corruptedClearWindowID(UInt32)
    case noFocusedWindow
    case noMainScreen
}

/// Mirror record validity (ToggleRecord.isValid — Quartz center vs Cocoa main frame)
struct MirrorToggleRecord {
    let origFrame: CGRect
    let targetFrame: CGRect
    let windowID: UInt32

    func isValid(mainScreenFrame: CGRect) -> Bool {
        let h = mainScreenFrame.height
        let origCenter = CGPoint(x: origFrame.midX, y: h - origFrame.midY)
        let tgtCenter = CGPoint(x: targetFrame.midX, y: h - targetFrame.midY)
        return !mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }
}

/// Mirrors decideRestore (WindowManager+Toggle+Decision.swift) — 生产与测试必须守护同一棵树
func mirrorDecideRestore(
    focusedOnMain: Bool?,
    record: MirrorToggleRecord?,
    mainScreenFrame: CGRect?
) -> MirrorRestoreDecision {
    guard let focusedOnMain else { return .noFocusedWindow }
    if !focusedOnMain { return .moveToMain }
    guard let record else { return .noRecord }
    guard let mainScreenFrame else { return .noMainScreen }
    if !record.isValid(mainScreenFrame: mainScreenFrame) {
        return .corruptedClearWindowID(record.windowID)
    }
    return .restore
}

/// Mirrors toggle() 路由 switch (WindowManager+Toggle.swift)
/// - Returns: 实际执行的分支名："restore" / "move_to_secondary_stuck" / "move_to_main"
func mirrorRoute(decision: MirrorRestoreDecision, resolutionOnMain: Bool?) -> String {
    switch decision {
    case .restore:
        return "restore"
    case .moveToMain, .noRecord, .corruptedClearWindowID, .noFocusedWindow, .noMainScreen:
        return resolutionOnMain == true ? "move_to_secondary_stuck" : "move_to_main"
    }
}

/// Mirrors CoordinateKit.isOnMainScreen(_:mainScreenFrame:) — 唯一归属判定
func mirrorIsOnMainScreen(_ rect: CGRect, mainScreenFrame: CGRect) -> Bool {
    mainScreenFrame.contains(CGPoint(x: rect.midX, y: rect.midY))
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let mainFrame = CGRect(x: 0, y: 0, width: 1920, height: 1117)
let validRecord = MirrorToggleRecord(
    origFrame: CGRect(x: 100, y: -800, width: 800, height: 600),      // 副屏（上方，Quartz 负 y）
    targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1117),       // 主屏全屏
    windowID: 42
)
let corruptedRecord = MirrorToggleRecord(
    origFrame: CGRect(x: 500, y: 300, width: 800, height: 600),       // orig 在主屏 → corrupted
    targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1117),
    windowID: 42
)

// MARK: 1. decideRestore 决策树

print("1. decideRestore — 决策树 6 case")

check("focusedOnMain=nil → noFocusedWindow",
      mirrorDecideRestore(focusedOnMain: nil, record: nil, mainScreenFrame: nil) == .noFocusedWindow)

check("不在主屏 → moveToMain（短路，不查 record）",
      mirrorDecideRestore(focusedOnMain: false, record: validRecord, mainScreenFrame: mainFrame) == .moveToMain)

check("在主屏 + 无 record → noRecord",
      mirrorDecideRestore(focusedOnMain: true, record: nil, mainScreenFrame: mainFrame) == .noRecord)

check("在主屏 + record + mainScreenFrame=nil → noMainScreen",
      mirrorDecideRestore(focusedOnMain: true, record: validRecord, mainScreenFrame: nil) == .noMainScreen)

check("在主屏 + corrupted record → corruptedClearWindowID",
      mirrorDecideRestore(focusedOnMain: true, record: corruptedRecord, mainScreenFrame: mainFrame) == .corruptedClearWindowID(42))

check("在主屏 + valid record → restore",
      mirrorDecideRestore(focusedOnMain: true, record: validRecord, mainScreenFrame: mainFrame) == .restore)

// MARK: 2. 路由表

print("\n2. toggle 路由 — decision × onMainScreen → 分支")

check(".restore → restore（无条件）", mirrorRoute(decision: .restore, resolutionOnMain: nil) == "restore")
check(".restore → restore（即使 onMain=false）", mirrorRoute(decision: .restore, resolutionOnMain: false) == "restore")

// 非 restore 决策 × 主屏归属三种取值
for decision in [MirrorRestoreDecision.moveToMain, .noRecord, .corruptedClearWindowID(42), .noFocusedWindow, .noMainScreen] {
    let name = String(describing: decision)
    check("\(name) + onMain=true → stuck",
          mirrorRoute(decision: decision, resolutionOnMain: true) == "move_to_secondary_stuck")
    check("\(name) + onMain=false → move_to_main",
          mirrorRoute(decision: decision, resolutionOnMain: false) == "move_to_main")
    check("\(name) + onMain=nil → move_to_main（归属未知不进 stuck）",
          mirrorRoute(decision: decision, resolutionOnMain: nil) == "move_to_main")
}

// MARK: 3. 归属判定纯函数

print("\n3. isOnMainScreen(rect, mainScreenFrame:) — 归属判定")

check("主屏内窗口 → true", mirrorIsOnMainScreen(CGRect(x: 100, y: 200, width: 800, height: 600), mainScreenFrame: mainFrame))
check("副屏（右侧，Quartz x 超界）→ false", !mirrorIsOnMainScreen(CGRect(x: 2000, y: 100, width: 800, height: 600), mainScreenFrame: mainFrame))
check("副屏（上方，Quartz 负 y）→ false", !mirrorIsOnMainScreen(CGRect(x: 100, y: -800, width: 800, height: 600), mainScreenFrame: mainFrame))

// MARK: summary

print("\n==========================================")
print("Summary: \(passed) passed, \(failed) failed")
if failed > 0 {
    print("FAILED: \(failed) checks")
    exit(1)
}
exit(0)
