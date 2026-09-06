// Tests/Standalone/ToggleFallbackWindowTests.swift
// Verification: windowless-frontmost toggle fallback (pickFallbackFrontWindow)
// Mirrors: Sources/Window/WindowManager+Toggle+FocusFallback.swift
// Run: swift Tests/Standalone/ToggleFallbackWindowTests.swift
//
// 回归背景（2026-09-06 toggle-00000182 真机事故）：前台是 SystemUIServer（无 layer-0 可见
// 窗口）时三级焦点解析全空，toggle 死在 "focused window identity missing"，用户视角 = ⌃Q
// 死键、窗口间无法切换。兜底修复 = 取 z-order 最前的普通用户窗口继续正常决策。
// 本文件锁定兜底选择器的全部判定分支，防回归。

import AppKit
import CoreGraphics
import Foundation

// MARK: - CGWindowEntry (mirrors Sources/Support/CGWindowEntry.swift:5-36, 仅测试所需字段)

struct CGWindowEntry {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect?
    let name: String?
    let isOnScreen: Bool

    init(windowID: UInt32, ownerPID: pid_t, ownerName: String? = nil, layer: Int = 0,
         bounds: CGRect? = nil, name: String? = nil, isOnScreen: Bool = true) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
        self.name = name
        self.isOnScreen = isOnScreen
    }
}

// MARK: - pickFallbackFrontWindow (mirrors Sources/Window/WindowManager+Toggle+FocusFallback.swift)

func pickFallbackFrontWindow(
    snapshot: [CGWindowEntry],
    ownPID: pid_t,
    activationPolicyOf: (pid_t) -> NSApplication.ActivationPolicy?
) -> CGWindowEntry? {
    snapshot.first { entry in
        guard entry.layer == 0, entry.isOnScreen, entry.ownerPID != ownPID else { return false }
        guard let b = entry.bounds, b.width > 1, b.height > 1 else { return false }
        return activationPolicyOf(entry.ownerPID) == .regular
    }
}

// MARK: - 测试装置

var failures: [String] = []
var checks = 0

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    checks += 1
    if got != want {
        failures.append("\(label): got \(got), want \(want)")
    }
}

func expectNil<T>(_ got: T?, _ label: String) {
    checks += 1
    if got != nil {
        failures.append("\(label): expected nil, got \(String(describing: got))")
    }
}

// pid 语义表（模拟真实进程布局）
let pidSystemUIServer: pid_t = 526      // .accessory（菜单栏/控制中心宿主）
let pidDock: pid_t = 480                // .accessory
let pidVibeFocusSelf: pid_t = 9999      // 本 app（.regular，但自身窗口必须排除）
let pidTerminal: pid_t = 31198          // .regular
let pidZCode: pid_t = 505               // .regular

func policyOf(pid: pid_t) -> NSApplication.ActivationPolicy? {
    switch pid {
    case pidSystemUIServer, pidDock: return .accessory
    case pidVibeFocusSelf, pidTerminal, pidZCode: return .regular
    default: return nil
    }
}

func entry(_ windowID: UInt32, _ pid: pid_t, layer: Int = 0,
           size: CGSize = CGSize(width: 1200, height: 800), onScreen: Bool = true) -> CGWindowEntry {
    CGWindowEntry(
        windowID: windowID, ownerPID: pid, ownerName: "p\(pid)", layer: layer,
        bounds: CGRect(origin: .zero, size: size), name: "w\(windowID)", isOnScreen: onScreen
    )
}

// MARK: 1. 真机事故场景（2026-09-06 toggle-00000182）：SystemUIServer 持焦，
//         快照里只有系统表面 + 本 app overlay + 一个普通 app 窗口 → 必须命中普通窗口。
//         修复前该场景走 "focused window identity missing" 死终（⌃Q 死键）。
do {
    let snapshot: [CGWindowEntry] = [
        entry(1, pidVibeFocusSelf),              // 本 app overlay（z-order 最前）
        entry(2, pidSystemUIServer, layer: 25),  // 菜单栏条目（layer≠0）
        entry(3, pidDock),                       // Dock（.accessory，layer==0 也不合格）
        entry(4, pidTerminal)                    // 唯一普通用户窗口
    ]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 4, "accident-scenario picks terminal window")
}

// MARK: 2. z-order 优先级：多个普通窗口时取数组最前（CGWindowList 前→后 = 视觉最前）。
do {
    let snapshot = [entry(10, pidZCode), entry(11, pidTerminal)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 10, "z-order first regular window wins")
}

// MARK: 3. 全系统快照（无任何 .regular 窗口）→ nil（维持原死终路径，但日志有归因）。
do {
    let snapshot = [entry(20, pidSystemUIServer, layer: 25), entry(21, pidDock)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectNil(got?.windowID, "all-system snapshot yields nil")
}

// MARK: 4. layer≠0 的普通 app 窗口不合格（桌面/贴纸层等）。
do {
    let snapshot = [entry(30, pidZCode, layer: -1), entry(31, pidTerminal, layer: 25)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectNil(got?.windowID, "non-layer-0 windows excluded")
}

// MARK: 5. isOnScreen=false（隐藏 Space 的窗口）不合格。
do {
    let snapshot = [entry(40, pidTerminal, onScreen: false)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectNil(got?.windowID, "offscreen window excluded")
}

// MARK: 6. 1x1 占位窗不合格。
do {
    let snapshot = [entry(50, pidTerminal, size: CGSize(width: 1, height: 1)),
                    entry(51, pidZCode, size: CGSize(width: 2, height: 2))]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 51, "1x1 spacer excluded, next regular picked")
}

// MARK: 7. 自身 pid 硬排除（即使 overlay 是 .regular + layer==0）。
do {
    let snapshot = [entry(60, pidVibeFocusSelf), entry(61, pidTerminal)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 61, "own overlay excluded")
}

// MARK: 8. 进程已退出（policy 查不到 → nil）不合格。
do {
    let deadPID: pid_t = 77777
    let snapshot = [entry(70, deadPID), entry(71, pidTerminal)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 71, "dead-owner window excluded")
}

// MARK: 9. bounds 缺失的窗口不合格（CGWindowList 偶发无 bounds）。
do {
    let noBounds = CGWindowEntry(windowID: 80, ownerPID: pidTerminal, bounds: nil)
    let snapshot = [noBounds, entry(81, pidZCode)]
    let got = pickFallbackFrontWindow(snapshot: snapshot, ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectEqual(got?.windowID ?? 0, 81, "missing-bounds window excluded")
}

// MARK: 10. 空快照 → nil。
do {
    let got = pickFallbackFrontWindow(snapshot: [], ownPID: pidVibeFocusSelf, activationPolicyOf: policyOf)
    expectNil(got?.windowID, "empty snapshot yields nil")
}

print("ToggleFallbackWindowTests: \(checks) checks, \(failures.count) failures")
if !failures.isEmpty {
    for f in failures { print("  FAIL: \(f)") }
    exit(1)
}
print("All ToggleFallbackWindowTests passed.")
