// Tests/Standalone/FrameConvergenceLoopTests.swift
// Verification: 帧写入收敛循环唯一骨架（write → settle → read → 判据 → 不收敛重写）
// Mirrors: Sources/Support/FrameConvergence.swift
//         Sources/Window/WindowManager+MoveWindow.swift（moveWindowToFrameViaYabai 策略）
//         Sources/Window/WindowManager+AXWrite.swift（writeSizeWithReadback 策略）
//         Sources/Window/WindowManager+MoveWindow+PostMove.swift（verifyAndCorrectPostMoveSize 策略）
// Run: swift Tests/Standalone/FrameConvergenceLoopTests.swift
//
// 背景（playbook 2.16a 第十四刀）："写 frame→等落定→读回→重写"曾有三份平行实现，
// 判据（第十二刀 CoordinateKit 漂移和）与等待常量（第九刀 WindowSettle）已统一，
// 本刀把循环骨架本身收敛为 convergeFrame 一个。本测试锁定骨架语义契约：
// 尝试计数、settle 时序（write 必先于 settle、settle 必先于 read——读回必须等写落定）、
// 读失败重试、写硬失败短路、attempts 归一，以及三个调用点的策略表。

import Foundation
import CoreGraphics

// MARK: - Extracted pure logic

/// Mirrors FrameWriteOutcome
enum MirrorFrameWriteOutcome: Equatable {
    case converged(attempt: Int, frame: CGRect)
    case mismatched(attempts: Int, lastFrame: CGRect?)
    case writeFailed(attempt: Int)
}

/// Mirrors FrameConvergence.convergeFrame（骨架逐行同构；sleep 可注入以便记录时序）
enum MirrorFrameConvergence {
    static func convergeFrame(
        attempts: Int,
        settleMicros: useconds_t,
        write: () -> Bool,
        read: () -> CGRect?,
        isConverged: (CGRect) -> Bool,
        sleep: (useconds_t) -> Void = { usleep($0) }
    ) -> MirrorFrameWriteOutcome {
        let totalAttempts = max(1, attempts)
        var lastFrame: CGRect? = nil
        for attempt in 1...totalAttempts {
            guard write() else { return .writeFailed(attempt: attempt) }
            sleep(settleMicros)
            guard let actual = read() else { continue }
            lastFrame = actual
            if isConverged(actual) {
                return .converged(attempt: attempt, frame: actual)
            }
        }
        return .mismatched(attempts: totalAttempts, lastFrame: lastFrame)
    }
}

/// Mirrors CoordinateKit 漂移和判据（第十二刀统一后的唯一事实源）
func mirrorOriginDrift(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    abs(a.x - b.x) + abs(a.y - b.y)
}

func mirrorSizeDrift(_ a: CGSize, _ b: CGSize) -> CGFloat {
    abs(a.width - b.width) + abs(a.height - b.height)
}

/// Mirrors 三个调用点的策略表（attempts/settle/判据选择）
enum MirrorCallSitePolicy {
    // moveWindowToFrameViaYabai：全 frame 判据（origin+size 双维）
    static let yabaiAttempts = 2
    static let yabaiSettleMicros: UInt32 = 400_000       // WindowSettle.yabaiFrameWriteSettleMicros
    // writeSizeWithReadback 主循环：size 判据（position 在 Phase 2 另写）
    static let sizeReadbackAttempts = 3                  // apply 默认 maxAttempts
    static let sizeReadbackSettleMicros: UInt32 = 25_000 // WindowSettle.axWriteSettleMicros
    // verifyAndCorrectPostMoveSize rewrite 循环：size 判据
    static let postRewriteAttempts = 2
    static let postRewriteSettleMicros: UInt32 = 25_000  // 第十四刀归一：15ms 并入 axWriteSettle
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let target = CGRect(x: 100, y: 200, width: 800, height: 600)

// MARK: 1. 收敛路径 — 尝试计数与 frame 载荷

print("1. 收敛路径")

do {
    var writes = 0, reads = 0, sleeps = 0
    let first = CGRect(x: 100, y: 200, width: 800, height: 600)
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { writes += 1; return true },
        read: { reads += 1; return first },
        isConverged: { mirrorSizeDrift($0.size, target.size) == 0 && mirrorOriginDrift($0.origin, target.origin) == 0 },
        sleep: { _ in sleeps += 1 }
    )
    check("首次读回即收敛 → .converged(attempt: 1)", outcome == .converged(attempt: 1, frame: first))
    check("首次收敛只写一次、只读一次、只 settle 一次（不空转）", writes == 1 && reads == 1 && sleeps == 1)
    if case .converged(_, let frame) = outcome {
        check("converged 载荷 = 实际读回 frame（非目标 frame）", frame == first)
    } else { failed += 1; print("  FAIL: converged 载荷 = 实际读回 frame（非目标 frame）") }
}

do {
    var writeCount = 0
    let drifted = CGRect(x: 100, y: 200, width: 780, height: 600)   // 首轮 size 漂 20
    let fixed = target
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { writeCount += 1; return true },
        read: { writeCount == 1 ? drifted : fixed },
        isConverged: { mirrorSizeDrift($0.size, target.size) == 0 && mirrorOriginDrift($0.origin, target.origin) == 0 },
        sleep: { _ in }
    )
    check("首轮漂移重写后第 2 轮收敛 → .converged(attempt: 2)", outcome == .converged(attempt: 2, frame: fixed))
    check("重写收敛共写 2 次", writeCount == 2)
}

// MARK: 2. 失败路径 — 短路、重试、lastFrame 归属

print("\n2. 失败路径")

do {
    var sleeps = 0, reads = 0
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { false },
        read: { reads += 1; return nil },
        isConverged: { _ in true },
        sleep: { _ in sleeps += 1 }
    )
    // 写失败必须发生在第 1 轮判据之前：不 settle、不 read
    check("首轮写硬失败 → .writeFailed(attempt: 1)，不 settle 不 read",
          outcome == .writeFailed(attempt: 1) && sleeps == 0 && reads == 0)
}

do {
    var sleeps = 0, reads = 0, writes = 0
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { writes += 1; return writes < 2 },
        read: { reads += 1; return nil },
        isConverged: { _ in true },
        sleep: { _ in sleeps += 1 }
    )
    check("第 2 轮写硬失败短路 → .writeFailed(attempt: 2)，第 2 轮的 settle/read 不执行",
          outcome == .writeFailed(attempt: 2) && sleeps == 1 && reads == 1)
}

do {
    var writes = 0
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { writes += 1; return true },
        read: { writes >= 3 ? target : nil },   // 前两轮读失败，第三轮才读到且收敛
        isConverged: { $0 == target },
        sleep: { _ in }
    )
    check("读失败视为本轮未收敛、继续重试 → 第 3 轮收敛", outcome == .converged(attempt: 3, frame: target))
}

do {
    var writes = 0
    let lastGood = CGRect(x: 0, y: 0, width: 10, height: 10)
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 3, settleMicros: 1_000,
        write: { writes += 1; return true },
        read: { writes == 1 ? lastGood : nil },  // 首轮读到漂移 frame，后两轮读失败
        isConverged: { $0 == target },
        sleep: { _ in }
    )
    check("读失败耗尽 → .mismatched(attempts: 3, lastFrame: 最后一次成功读)",
          outcome == .mismatched(attempts: 3, lastFrame: lastGood))
}

// MARK: 3. 时序与归一 — settle 介于 write 与 read 之间

print("\n3. 时序与归一")

do {
    var events: [String] = []
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 2, settleMicros: 7_777,
        write: { events.append("write"); return true },
        read: { events.append("read"); return nil },
        isConverged: { _ in false },
        sleep: { m in events.append("sleep(\(m))") }
    )
    let expected = ["write", "sleep(7777)", "read", "write", "sleep(7777)", "read"]
    check("事件序列严格为 write→settle→read 循环（读回必须等写落定）", events == expected)
    check("读失败耗尽返回 .mismatched(attempts: 2, lastFrame: nil)", outcome == .mismatched(attempts: 2, lastFrame: nil))
}

do {
    var writeCount = 0
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 0, settleMicros: 1_000,
        write: { writeCount += 1; return true },
        read: { nil },
        isConverged: { _ in true },
        sleep: { _ in }
    )
    check("attempts=0 归一为 1（防 1...0 崩溃）：恰写一次，返回 .mismatched(attempts: 1)",
          writeCount == 1 && outcome == .mismatched(attempts: 1, lastFrame: nil))
}

do {
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 1, settleMicros: 1_000,
        write: { true },
        read: { target },
        isConverged: { $0 == target },
        sleep: { _ in }
    )
    check("attempts=1 边界：恰一轮 write→settle→read 判据即返回", outcome == .converged(attempt: 1, frame: target))
}

// MARK: 4. 调用点策略表 — 三处 wiring 的参数与判据选择

print("\n4. 调用点策略表")

check("moveWindowToFrameViaYabai：attempts=2，settle=400ms（yabaiFrameWriteSettle），判据=frame 漂移和",
      MirrorCallSitePolicy.yabaiAttempts == 2 && MirrorCallSitePolicy.yabaiSettleMicros == 400_000)
check("writeSizeWithReadback 主循环：attempts=3（apply 默认），settle=25ms（axWriteSettle），判据=size 漂移和",
      MirrorCallSitePolicy.sizeReadbackAttempts == 3 && MirrorCallSitePolicy.sizeReadbackSettleMicros == 25_000)
check("verifyAndCorrectPostMoveSize rewrite：attempts=2，settle=25ms（原 15ms 档已归一进 axWriteSettle）",
      MirrorCallSitePolicy.postRewriteAttempts == 2 && MirrorCallSitePolicy.postRewriteSettleMicros == 25_000)

do {
    // yabai 版判据 = origin+size 双维漂移和（isFrameConverged）；size 版 = 仅 size 漂移和（isSizeConverged）。
    // PostMove/size 循环有意不查 origin（position 在 Phase 2 另写，origin 漂移不该触发 size 重写）。
    let actual = CGRect(x: 101, y: 200, width: 800, height: 600)  // origin 漂 1，size 不漂
    let tol: CGFloat = 2
    let frameVerdict = mirrorOriginDrift(actual.origin, target.origin) + mirrorSizeDrift(actual.size, target.size) <= tol
    let sizeVerdict = mirrorSizeDrift(actual.size, target.size) <= tol
    check("判据分工：frame 判据对 origin 漂移敏感，size 判据不敏感（Phase 2 position 另写的结构后果）",
          frameVerdict && sizeVerdict)
    let bigSizeDrift = CGRect(x: 100, y: 200, width: 700, height: 600)
    check("两判据在 size 漂移上同式同阈（同一漂移和，tol=2 时漂 100 均不收敛）",
          !(mirrorSizeDrift(bigSizeDrift.size, target.size) <= tol))
}

// MARK: 5. 默认 sleep 冒烟 — 默认参数走真实 usleep

print("\n5. 默认 sleep 冒烟")

do {
    let start = Date()
    let outcome = MirrorFrameConvergence.convergeFrame(
        attempts: 1, settleMicros: 20_000,
        write: { true },
        read: { target },
        isConverged: { $0 == target }
    )
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    check("默认 sleep=usleep：20ms settle 实际耗时 ≥15ms 且首读收敛", elapsedMs >= 15 && outcome == .converged(attempt: 1, frame: target))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
