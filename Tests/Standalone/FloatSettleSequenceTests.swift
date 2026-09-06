// Tests/Standalone/FloatSettleSequenceTests.swift
// Verification: 「float 脱管 → 等重摆落定 → 缓存失效」唯一序列原语
// Mirrors: Sources/Support/FloatSettle.swift (FloatSettle.floatAndSettle)
//          Sources/Support/FrameConvergence.swift (waitForRelayout 序列骨架)
//          Sources/Support/WindowSettle.swift (等待常量)
// Run: swift Tests/Standalone/FloatSettleSequenceTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored types

enum FloatToggleOutcomeMirror: Equatable {
    case toggled
    case skippedNoOp
}

enum WindowSettleMirror {
    static let floatRelayoutSettleMicros: useconds_t = 300_000
    static let floatRelayoutMinSettleMicros: useconds_t = 120_000
    static let frameVerifyPollIntervalMs: UInt32 = 25
}

enum FrameConvergenceMirror {
    /// 镜像 waitForRelayout：先无条件睡下限，再轮询「连续两读稳定」早返回，预算兜底。
    static func waitForRelayout(
        minSettleMicros: useconds_t,
        intervalMs: UInt32,
        budgetMs: UInt32,
        read: () -> CGRect?,
        isSame: (CGRect, CGRect) -> Bool,
        sleep: (useconds_t) -> Void = { usleep($0) },
        pollSleep: (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) {
        sleep(minSettleMicros)
        var waitedMs: UInt32 = 0
        var prev = read()
        while waitedMs < budgetMs {
            let nap = min(intervalMs, budgetMs - waitedMs)
            pollSleep(nap)
            waitedMs += nap
            let current = read()
            if let p = prev, let c = current, isSame(p, c) {
                return
            }
            prev = current
        }
    }
}

enum FloatSettleMirror {
    struct Outcome: Equatable {
        let didToggle: Bool
        let durationMs: Int
    }

    static func floatAndSettle(
        windowID: UInt32,
        operationID: String,
        knownWindowInfo: Int?,
        tolerance: CGFloat,
        setFloat: (UInt32, String, Int?) -> FloatToggleOutcomeMirror,
        read: (UInt32) -> CGRect?,
        clearCache: () -> Void,
        sleep: (useconds_t) -> Void = { _ in },
        pollSleep: (UInt32) -> Void = { _ in }
    ) -> Outcome {
        let outcome = setFloat(windowID, operationID, knownWindowInfo)
        if outcome == .toggled {
            FrameConvergenceMirror.waitForRelayout(
                minSettleMicros: WindowSettleMirror.floatRelayoutMinSettleMicros,
                intervalMs: WindowSettleMirror.frameVerifyPollIntervalMs,
                // 与生产 FloatSettle 同步：μs→ms 换算（Batch 6 修正 unit bug，
                // 预算 300ms 而非 300_000ms，见 FloatSettle.swift 注释）。
                budgetMs: UInt32(WindowSettleMirror.floatRelayoutSettleMicros / 1_000),
                read: { read(windowID) },
                isSame: { abs($0.origin.x - $1.origin.x) + abs($0.origin.y - $1.origin.y)
                        + abs($0.size.width - $1.size.width) + abs($0.size.height - $1.size.height) <= tolerance },
                sleep: sleep,
                pollSleep: pollSleep
            )
        }
        clearCache()
        return Outcome(didToggle: outcome == .toggled, durationMs: 0)
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

/// 事件记录器：断言序列顺序与等待量。
final class Recorder {
    var events: [String] = []
    var sleeps: [useconds_t] = []
    var polls: [UInt32] = []
    var clearCount = 0
    var setFloatCalls = 0
    var reads = 0
}

let windowID: UInt32 = 42

// MARK: 场景 A：真 toggle —— setFloat → 等重摆 → 清缓存，顺序与等待量锁定

do {
    let rec = Recorder()
    var readCount = 0
    let outcome = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-a",
        knownWindowInfo: nil,
        tolerance: 20,
        setFloat: { id, op, info in
            rec.setFloatCalls += 1
            rec.events.append("float(\(id),\(op))")
            return .toggled
        },
        read: { id in
            rec.reads += 1
            return CGRect(x: 0, y: 0, width: 800, height: 600)
        },
        clearCache: {
            rec.clearCount += 1
            rec.events.append("clear")
        },
        sleep: { rec.sleeps.append($0); rec.events.append("sleep(\($0))") },
        pollSleep: { rec.polls.append($0); rec.events.append("poll(\($0))") }
    )
    check("A1: setFloat 恰好一次", rec.setFloatCalls == 1)
    check("A2: 先睡重摆启动下限 120ms", rec.sleeps == [WindowSettleMirror.floatRelayoutMinSettleMicros])
    check("A3: 稳定后早返回（读数 2 次即两读相等，轮询仅 1 拍）", rec.reads == 2 && rec.polls == [WindowSettleMirror.frameVerifyPollIntervalMs])
    check("A4: 缓存失效恰好一次且在等待之后", rec.clearCount == 1 && rec.events.last == "clear" && !rec.sleeps.isEmpty)
    check("A5: 序列顺序 float→sleep→poll→clear", rec.events == ["float(42,op-a)", "sleep(120000)", "poll(25)", "clear"])
    check("A6: didToggle 如实上报", outcome.didToggle == true)
}

// MARK: 场景 B：已 float（skippedNoOp）—— 零等待、缓存仍恒清

do {
    let rec = Recorder()
    let outcome = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-b",
        knownWindowInfo: 7,
        tolerance: 20,
        setFloat: { _, _, _ in
            rec.setFloatCalls += 1
            rec.events.append("float")
            return .skippedNoOp
        },
        read: { _ in rec.reads += 1; return nil },
        clearCache: { rec.clearCount += 1; rec.events.append("clear") },
        sleep: { rec.sleeps.append($0) },
        pollSleep: { rec.polls.append($0) }
    )
    check("B1: skippedNoOp 不进重摆等待（零读零睡）", rec.reads == 0 && rec.sleeps.isEmpty && rec.polls.isEmpty)
    check("B2: 缓存恒清语义——跳过场景仍清一次", rec.clearCount == 1)
    check("B3: didToggle=false 如实上报", outcome.didToggle == false)
    check("B4: 序列 float→clear", rec.events == ["float", "clear"])
}

// MARK: 场景 C：预算兜底 —— 重摆期间 frame 一直抖，走满 120ms 下限 + 300ms 预算

do {
    let rec = Recorder()
    var pollRound = 0
    _ = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-c",
        knownWindowInfo: nil,
        tolerance: 20,
        setFloat: { _, _, _ in .toggled },
        read: { _ in
            pollRound += 1
            return CGRect(x: pollRound * 100, y: 0, width: 800, height: 600)
        },
        clearCache: { rec.clearCount += 1 },
        sleep: { rec.sleeps.append($0) },
        pollSleep: { rec.polls.append($0) }
    )
    let totalPollMs = rec.polls.reduce(0, +)
    check("C1: 永不稳定时走满预算 300ms", totalPollMs == WindowSettleMirror.floatRelayoutSettleMicros / 1000)
    check("C2: 下限先于轮询", rec.sleeps == [WindowSettleMirror.floatRelayoutMinSettleMicros] && rec.polls.first != nil)
    check("C3: 轮询节拍 25ms 且被预算截断（12 拍）", rec.polls.count == 12 && rec.polls.allSatisfy { $0 == 25 })
    check("C4: 走满预算后缓存仍清", rec.clearCount == 1)
}

// MARK: 场景 D：稳定判据容差接线 —— 漂移和 > tolerance 视为未稳定

do {
    var reads = 0
    var polls = 0
    _ = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-d",
        knownWindowInfo: nil,
        tolerance: 20,
        setFloat: { _, _, _ in .toggled },
        read: { _ in
            reads += 1
            // 每次读都比上次漂 21 > 容差 20：永不稳定
            return CGRect(x: reads * 21, y: 0, width: 100, height: 100)
        },
        clearCache: {},
        sleep: { _ in },
        pollSleep: { _ in polls += 1 }
    )
    check("D1: 漂移 21 > 容差 20 不误判稳定（走满 12 拍预算）", polls == 12)

    reads = 0
    polls = 0
    _ = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-d2",
        knownWindowInfo: nil,
        tolerance: 20,
        setFloat: { _, _, _ in .toggled },
        read: { _ in
            reads += 1
            return CGRect(x: reads == 1 ? 0 : 8, y: 0, width: 100, height: 100)
        },
        clearCache: {},
        sleep: { _ in },
        pollSleep: { _ in polls += 1 }
    )
    check("D2: 漂移 8 ≤ 容差 20 两读即稳定（1 拍早返回）", polls == 1)
}

// MARK: 场景 E：读失败（nil）不终止等待

do {
    var polls = 0
    var readCount = 0
    _ = FloatSettleMirror.floatAndSettle(
        windowID: windowID,
        operationID: "op-e",
        knownWindowInfo: nil,
        tolerance: 20,
        setFloat: { _, _, _ in .toggled },
        read: { _ in
            readCount += 1
            return nil
        },
        clearCache: {},
        sleep: { _ in },
        pollSleep: { _ in polls += 1 }
    )
    check("E1: 读全 nil 走满预算不崩溃", polls == 12 && readCount == 13)
}

// MARK: 汇总

print("\nFloatSettleSequenceTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
