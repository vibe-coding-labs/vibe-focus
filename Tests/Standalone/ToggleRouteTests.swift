// Tests/Standalone/ToggleRouteTests.swift
// Verification: toggle 执行路由唯一映射（Batch 5——mode 日志与执行分支同源）
// Mirrors: Sources/Window/WindowManager+Toggle+Decision.swift
//          (RestoreDecision/ToggleRoute/WindowManager.route)
// Run: swift Tests/Standalone/ToggleRouteTests.swift

import Foundation

// MARK: - Mirrored types

enum RestoreDecision: Equatable {
    case restore
    case moveToMain
    case noRecord
    case corruptedClearWindowID(UInt32)
    case noFocusedWindow
    case noMainScreen
}

enum ToggleRoute: Equatable {
    case restore
    case moveToMain
    case moveSecondaryStuck

    var logName: String {
        switch self {
        case .restore: return "restore"
        case .moveToMain: return "move_to_main"
        case .moveSecondaryStuck: return "move_to_secondary_stuck"
        }
    }
}

func route(for decision: RestoreDecision, onMainScreen: Bool?) -> ToggleRoute {
    if case .restore = decision { return .restore }
    return onMainScreen == true ? .moveSecondaryStuck : .moveToMain
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let decisions: [RestoreDecision] = [
    .restore,
    .moveToMain,
    .noRecord,
    .corruptedClearWindowID(42),
    .noFocusedWindow,
    .noMainScreen,
]
let onMainCases: [(label: String, value: Bool?)] = [
    ("onMain=true", true),
    ("onMain=false", false),
    ("onMain=nil", nil),
]

print("1. 全决策 × 全归属组合穷举（6 × 3 = 18）")
do {
    // 语义表：
    //   .restore → restore（归属无关）
    //   其余决策：onMain=true → moveSecondaryStuck；false/nil → moveToMain
    let expected: [String: ToggleRoute] = [
        "restore|true": .restore,
        "restore|false": .restore,
        "restore|nil": .restore,
        "moveToMain|true": .moveSecondaryStuck,
        "moveToMain|false": .moveToMain,
        "moveToMain|nil": .moveToMain,
        "noRecord|true": .moveSecondaryStuck,
        "noRecord|false": .moveToMain,
        "noRecord|nil": .moveToMain,
        "corrupted|true": .moveSecondaryStuck,
        "corrupted|false": .moveToMain,
        "corrupted|nil": .moveToMain,
        "noFocus|true": .moveSecondaryStuck,
        "noFocus|false": .moveToMain,
        "noFocus|nil": .moveToMain,
        "noScreen|true": .moveSecondaryStuck,
        "noScreen|false": .moveToMain,
        "noScreen|nil": .moveToMain,
    ]
    func key(_ d: RestoreDecision, _ v: Bool?) -> String {
        let dName: String
        switch d {
        case .restore: dName = "restore"
        case .moveToMain: dName = "moveToMain"
        case .noRecord: dName = "noRecord"
        case .corruptedClearWindowID: dName = "corrupted"
        case .noFocusedWindow: dName = "noFocus"
        case .noMainScreen: dName = "noScreen"
        }
        let vName = v == nil ? "nil" : (v! ? "true" : "false")
        return "\(dName)|\(vName)"
    }
    var allOK = true
    for d in decisions {
        for c in onMainCases {
            let got = route(for: d, onMainScreen: c.value)
            if got != expected[key(d, c.value)]! { allOK = false }
        }
    }
    check("18 组合全部命中语义表", allOK)
}

print("2. restore 决策与归属解耦（record 有效即回原位，不受 onMain 影响）")
do {
    for c in onMainCases {
        if route(for: .restore, onMainScreen: c.value) != .restore { check("restore 恒路由 restore", false); exit(1) }
    }
    check("restore 恒路由 restore", true)
}

print("3. logName 与审计 mode 值一致")
do {
    check("restore", ToggleRoute.restore.logName == "restore")
    check("move_to_main", ToggleRoute.moveToMain.logName == "move_to_main")
    check("move_to_secondary_stuck", ToggleRoute.moveSecondaryStuck.logName == "move_to_secondary_stuck")
    // 关键组合：mode 与执行同源（Batch 5 修复的日志失真点）
    check("moveToMain 决策 + onMain=true → mode=move_to_secondary_stuck（与执行一致）",
          route(for: .moveToMain, onMainScreen: true).logName == "move_to_secondary_stuck")
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
