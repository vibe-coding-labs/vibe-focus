// Tests/Standalone/OverlayRefreshPolicyTests.swift
// Verification: Overlay 刷新防风暴门 + 屏幕热插拔防护（纯判定矩阵）
// Mirrors: Sources/Overlay/OverlayRefreshPolicy.swift (OverlayRefreshPolicy)
//          Sources/Overlay/ScreenHotplugGuard.swift (ScreenHotplugGuard)
// Run: swift Tests/Standalone/OverlayRefreshPolicyTests.swift
//
// 背景：刷新风暴是 Overlay 的历史事故类（SIGUSR1 连发 / toggle 连续触发 force
// refresh 堆积占用 yabai 单进程）。门序契约：suspend 先于 enabled，force 穿透
// suspend 不穿透 disabled；去重判定恰好等于间隔不算重复。

import Foundation

// MARK: - Mirrored types

enum OverlayRefreshPolicyMirror {
    enum GateDecision: Equatable { case skipSuspended, skipDisabled, proceed }
    static func refreshGate(suspended: Bool, enabled: Bool, force: Bool) -> GateDecision {
        if suspended && !force { return .skipSuspended }
        if !enabled { return .skipDisabled }
        return .proceed
    }
    static func isDuplicateForceTrigger(lastTriggerAt: Date, now: Date, minInterval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastTriggerAt) < minInterval
    }
}

enum ScreenHotplugGuardMirror {
    static func identityMatches(preUUIDs: Set<UUID>, currentUUIDs: Set<UUID>) -> Bool {
        preUUIDs == currentUUIDs
    }
    struct Result: Equatable { let index: Int; let uuid: UUID }
    static func filterStale(_ results: [Result], liveUUIDs: Set<UUID>) -> [Result] {
        results.filter { liveUUIDs.contains($0.uuid) }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

// MARK: 场景 A：refreshGate 八组合穷举

let g = OverlayRefreshPolicyMirror.self
check("A1: suspend+disabled+非force → skipSuspended（门序：suspend 优先）",
      g.refreshGate(suspended: true, enabled: false, force: false) == .skipSuspended)
check("A2: suspend+disabled+force → skipDisabled（force 穿透 suspend 不穿透 disabled）",
      g.refreshGate(suspended: true, enabled: false, force: true) == .skipDisabled)
check("A3: suspend+enabled+非force → skipSuspended",
      g.refreshGate(suspended: true, enabled: true, force: false) == .skipSuspended)
check("A4: suspend+enabled+force → proceed（toggle 后的 debounce 补刷新通道）",
      g.refreshGate(suspended: true, enabled: true, force: true) == .proceed)
check("A5: 非suspend+disabled+非force → skipDisabled",
      g.refreshGate(suspended: false, enabled: false, force: false) == .skipDisabled)
check("A6: 非suspend+disabled+force → skipDisabled",
      g.refreshGate(suspended: false, enabled: false, force: true) == .skipDisabled)
check("A7: 非suspend+enabled+非force → proceed（常态自动刷新）",
      g.refreshGate(suspended: false, enabled: true, force: false) == .proceed)
check("A8: 非suspend+enabled+force → proceed（SIGUSR1/热插拔强制刷新）",
      g.refreshGate(suspended: false, enabled: true, force: true) == .proceed)

// MARK: 场景 B：去重判定边界（恰等于间隔不算重复）

let last = Date(timeIntervalSince1970: 1000)
check("B1: 间隔 0.29 < 0.3 → 重复丢弃", g.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.29), minInterval: 0.3))
check("B2: 间隔 0.31 越过阈值 → 放行（< 语义，构建恰等值受浮点精度干扰不可靠）", !g.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.31), minInterval: 0.3))
check("B3: lastTriggerAt=distantPast → 放行（启动首次）", !g.isDuplicateForceTrigger(lastTriggerAt: .distantPast, now: last, minInterval: 0.3))

// MARK: 场景 C：热插拔防护（集合相等语义 + 防御过滤）

let u1 = UUID(), u2 = UUID(), u3 = UUID()
check("C1: uuid 集合相等 → 未插拔（顺序无关）",
      ScreenHotplugGuardMirror.identityMatches(preUUIDs: [u1, u2], currentUUIDs: [u2, u1]))
check("C2: 插入新屏 → 不一致丢弃",
      !ScreenHotplugGuardMirror.identityMatches(preUUIDs: [u1], currentUUIDs: [u1, u2]))
check("C3: 拔除屏幕 → 不一致丢弃",
      !ScreenHotplugGuardMirror.identityMatches(preUUIDs: [u1, u2], currentUUIDs: [u2]))
check("C4: filterStale 剔除已消失屏幕条目",
      ScreenHotplugGuardMirror.filterStale([.init(index: 0, uuid: u1), .init(index: 1, uuid: u3)], liveUUIDs: [u1]) == [.init(index: 0, uuid: u1)])
check("C5: filterStale 全 live → 原样保留",
      ScreenHotplugGuardMirror.filterStale([.init(index: 0, uuid: u1)], liveUUIDs: [u1, u2]).count == 1)

print("\nOverlayRefreshPolicyTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
