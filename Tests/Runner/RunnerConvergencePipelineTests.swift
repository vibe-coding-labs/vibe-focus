import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerConvergencePipelineTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runConvergencePipelineTests() {
    // MARK: FrameConvergence.shortfalls/resendSegments（真实实现——补发计划唯一事实源）

    do {
        let target = CGRect(x: 75, y: 38, width: 1653, height: 1079)
        let tol: CGFloat = 20
        // 与真实 CoordinateKit 交叉验证：shortfalls 空集 ⇔ isFrameConverged。
        let converged = CGRect(x: 80, y: 40, width: 1650, height: 1075)
        check("shortfalls: 双维容差内 → 空集（与 isFrameConverged 对拍）",
              FrameConvergence.shortfalls(current: converged, target: target, tolerance: tol).isEmpty
              && CoordinateKit.isFrameConverged(actual: converged, target: target, tolerance: tol))
        let driftedOrigin = CGRect(x: 200, y: 38, width: 1653, height: 1079)
        check("shortfalls: 仅 origin 超 20 → [.origin]",
              FrameConvergence.shortfalls(current: driftedOrigin, target: target, tolerance: tol) == [.origin])
        let driftedSize = CGRect(x: 75, y: 38, width: 1653, height: 900)
        check("shortfalls: 仅 size 超 20 → [.size]",
              FrameConvergence.shortfalls(current: driftedSize, target: target, tolerance: tol) == [.size])
        check("shortfalls: 双维超 → [.origin, .size]",
              FrameConvergence.shortfalls(current: CGRect(x: 500, y: 500, width: 800, height: 600), target: target, tolerance: tol) == [.origin, .size])
        check("shortfalls: 恰在容差边界（=20）→ 空集（≤ 判定）",
              FrameConvergence.shortfalls(current: CGRect(x: 95, y: 38, width: 1653, height: 1079), target: target, tolerance: tol).isEmpty)
        check("shortfalls: current=nil → 全缺（最坏防御，历史 ?? false 语义）",
              FrameConvergence.shortfalls(current: nil, target: target, tolerance: tol) == [.origin, .size])

        // resendSegments：四分支 × 两写序。
        check("resend: 无偏差 → 空计划",
              FrameConvergence.resendSegments(shortfall: [], order: .resizeThenMove).isEmpty)
        check("resend: 仅 origin 缺 → [.move]（两写序同）",
              FrameConvergence.resendSegments(shortfall: [.origin], order: .resizeThenMove) == [.move]
              && FrameConvergence.resendSegments(shortfall: [.origin], order: .moveThenResize) == [.move])
        check("resend: 仅 size 缺 → [.resize]（两写序同）",
              FrameConvergence.resendSegments(shortfall: [.size], order: .moveThenResize) == [.resize]
              && FrameConvergence.resendSegments(shortfall: [.size], order: .resizeThenMove) == [.resize])
        check("resend: 全缺 × resizeThenMove → resize→move（源屏先行序）",
              FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .resizeThenMove) == [.resize, .move])
        check("resend: 全缺 × moveThenResize → move→resize（历史序）",
              FrameConvergence.resendSegments(shortfall: [.origin, .size], order: .moveThenResize) == [.move, .resize])

        // 交叉验证（防公式单边漂移）：shortfalls 与真实 CoordinateKit 在漂移样本上一致。
        let samples: [(CGRect, Bool)] = [
            (CGRect(x: 75, y: 38, width: 1653, height: 1079), true),
            (CGRect(x: 80, y: 48, width: 1643, height: 1069), true),
            (CGRect(x: 96, y: 59, width: 1632, height: 1057), false),
            (CGRect(x: 97, y: 38, width: 1653, height: 1079), false),
        ]
        var crossOK = true
        for (sample, expectConverged) in samples {
            let short = FrameConvergence.shortfalls(current: sample, target: target, tolerance: tol)
            if short.isEmpty != (expectConverged && CoordinateKit.isFrameConverged(actual: sample, target: target, tolerance: tol)) { crossOK = false }
        }
        check("shortfalls × CoordinateKit 交叉验证 4 样本一致", crossOK)
    }

    // MARK: FrameWriteExecutor（真实实现——执行编排 + apply 调用序列断言）

    do {
        let target = CGRect(x: 75, y: 38, width: 1653, height: 1079)
        let tol: CGFloat = 20
        let missSize = CGRect(x: 75, y: 38, width: 1653, height: 900)   // 仅 size 缺
        let fullMiss = CGRect(x: 500, y: 500, width: 800, height: 600)  // 双维缺
        let noSleep: (UInt32) -> Void = { _ in } // 虚拟时间：预算分支瞬时跑满

        func makeExecutor(
            read: @escaping () -> CGRect?,
            calls: @escaping (String) -> Void
        ) -> FrameWriteExecutor {
            FrameWriteExecutor(
                deps: .init(
                    read: read,
                    applyMove: { calls("move") },
                    applyResizeAdaptive: { calls("resizeAdaptive") },
                    applyResizeRobust: { calls("resizeRobust") }
                ),
                tolerance: tol,
                op: "runner", stage: "executor-test", windowID: 1,
                pollSleep: noSleep
            )
        }

        // A. resizeThenMove 满意路径：读恒收敛 → resize→move 各一次，零补发。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { target }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            check("executor A: 调用序列 [resizeAdaptive, move]",
                  calls == ["resizeAdaptive", "move"])
            check("executor A: converged / 1 轮 / 0 补发",
                  run.outcome.isConverged && run.convergedRounds == 1 && run.resendCount == 0)
        }

        // B. moveThenResize 满意路径：move→resize 各一次。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { target }, calls: { calls.append($0) })
                .run(target: target, order: .moveThenResize)
            check("executor B: 调用序列 [move, resizeAdaptive]",
                  calls == ["move", "resizeAdaptive"])
            check("executor B: converged", run.outcome.isConverged)
        }

        // C. size 单缺补发：phase1 等待耗尽（13 次读全缺）→ move → 段二补 adaptive
        //    resize → 读收敛。序列锁死：resize→move→resize。
        do {
            var n = 0
            var calls: [String] = []
            let run = makeExecutor(
                read: { n += 1; return n <= 14 ? missSize : target },
                calls: { calls.append($0) }
            ).run(target: target, order: .resizeThenMove)
            check("executor C: 调用序列 [resizeAdaptive, move, resizeAdaptive]（单缺补发走择优通道）",
                  calls == ["resizeAdaptive", "move", "resizeAdaptive"])
            check("executor C: converged / 1 轮", run.outcome.isConverged && run.convergedRounds == 1)
        }

        // D. 全缺 × 两轮不收敛：段一 [resizeAdaptive, move]；段二每轮计划两段走
        //    robust 纯 yabai 按写序 [resizeRobust, move]；停滞重发（4 读不变）在
        //    轮询内重复同一计划、不计新轮——因此断言模式而非精确次数。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { fullMiss }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            check("executor D: 段一 [resizeAdaptive, move]",
                  calls.count >= 2 && calls[0] == "resizeAdaptive" && calls[1] == "move")
            var pairsOK = (calls.count - 2) >= 2 && (calls.count - 2) % 2 == 0
            var i = 2
            while i + 1 < calls.count {
                if calls[i] != "resizeRobust" || calls[i + 1] != "move" { pairsOK = false }
                i += 2
            }
            check("executor D: 段二每轮 [resizeRobust, move] 按写序（停滞重发重复同一计划）", pairsOK)
            check("executor D: mismatched / 2 轮 / 停滞补发计入 resend（≥1）",
                  !run.outcome.isConverged && run.convergedRounds == 2 && run.resendCount >= 1)
        }

        // E. 停滞重发：读恒 size 缺 → 轮询内 4 读不变即幂等补发 adaptive（≥1 次）。
        do {
            var calls: [String] = []
            let run = makeExecutor(read: { missSize }, calls: { calls.append($0) })
                .run(target: target, order: .resizeThenMove)
            let adaptiveCount = calls.filter { $0 == "resizeAdaptive" }.count
            check("executor E: 停滞重发触发多次 adaptive 补发（≥3）", adaptiveCount >= 3)
            check("executor E: 全程无 robust（单 size 缺不进全缺通道）", !calls.contains("resizeRobust"))
            check("executor E: 不收敛如实上报 mismatched", !run.outcome.isConverged)
        }
    }

    // MARK: WindowManager.route（真实实现——toggle 执行路由唯一映射，Batch 5）

    do {
        check("route: .restore → restore（onMain=true 不影响）",
              WindowManager.route(for: .restore, onMainScreen: true) == .restore)
        check("route: .restore → restore（onMain=nil 也不影响）",
              WindowManager.route(for: .restore, onMainScreen: nil) == .restore)
        check("route: .moveToMain + onMain=false → moveToMain",
              WindowManager.route(for: .moveToMain, onMainScreen: false) == .moveToMain)
        check("route: .moveToMain + onMain=true → moveSecondaryStuck（mode 与执行同源）",
              WindowManager.route(for: .moveToMain, onMainScreen: true) == .moveSecondaryStuck)
        check("route: .noRecord + onMain=nil → moveToMain（归属未知不进 stuck）",
              WindowManager.route(for: .noRecord, onMainScreen: nil) == .moveToMain)
        check("route: .corruptedClearWindowID + onMain=true → moveSecondaryStuck",
              WindowManager.route(for: .corruptedClearWindowID(7), onMainScreen: true) == .moveSecondaryStuck)
        check("route: .noFocusedWindow + onMain=false → moveToMain",
              WindowManager.route(for: .noFocusedWindow, onMainScreen: false) == .moveToMain)
        check("route: .noMainScreen + onMain=true → moveSecondaryStuck",
              WindowManager.route(for: .noMainScreen, onMainScreen: true) == .moveSecondaryStuck)
        check("route: logName 与审计 mode 值一致",
              WindowManager.ToggleRoute.restore.logName == "restore"
              && WindowManager.ToggleRoute.moveToMain.logName == "move_to_main"
              && WindowManager.ToggleRoute.moveSecondaryStuck.logName == "move_to_secondary_stuck")

    // MARK: ToggleFocusBranching（真实实现——P6 三分支焦点决策纯内核，分支组合穷尽锁定）

    do {
        // CGWindowEntry 只有 init?(from dict:)（memberwise 被吞），测试经 dict 构造。
        func win(_ id: UInt32, pid: pid_t = 100, layer: Int = 0, onScreen: Bool = true, withBounds: Bool = true) -> CGWindowEntry {
            var dict: [String: Any] = [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowIsOnscreen as String: onScreen,
            ]
            if withBounds {
                dict[kCGWindowBounds as String] = ["X": CGFloat(10), "Y": CGFloat(20), "Width": CGFloat(800), "Height": CGFloat(600)]
            }
            return CGWindowEntry(from: dict)!
        }

        // 分支 1 候选集：三条件过滤（异 pid / layer≠0 / 离屏全排除）+ z-order 顺序保持。
        let snapshot = [win(1), win(2, pid: 200), win(3, layer: -1), win(4, onScreen: false), win(5)]
        check("branch1: 候选集只留前台普通可见窗（顺序保持）",
              ToggleFocusBranching.cgListFocusCandidates(snapshot: snapshot, ownerPID: 100).map(\.windowID) == [1, 5])

        // 分支 1 快速路径：恰好 1 个。
        check("branch1: 单候选带 bounds → 命中",
              ToggleFocusBranching.singleWindowFastPath([win(7)])?.windowID == 7)
        check("branch1: 零候选 → nil（窗口在别的 space/最小化）",
              ToggleFocusBranching.singleWindowFastPath([]) == nil)
        check("branch1: 多候选 → nil（z-order ≠ AX focus，P0.3 教训）",
              ToggleFocusBranching.singleWindowFastPath([win(7), win(8)]) == nil)
        check("branch1: 单候选无 bounds → nil（落 yabai，拆分前同款边界）",
              ToggleFocusBranching.singleWindowFastPath([win(7, withBounds: false)]) == nil)

        // 分支 2 接受判定：id 可精确转 UInt32 + pid 与前台一致。
        func yabaiInfo(_ id: Int?, pid: Int?) -> YabaiWindowInfo {
            YabaiWindowInfo(id: id, pid: pid, app: "App", title: "t", space: 1, display: 1,
                            frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true,
                            isMinimizedRaw: false, hasFocusRaw: true)
        }
        check("branch2: id+pid 全匹配 → winID",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(77, pid: 100), frontPID: 100)?.winID == 77)
        check("branch2: yabai 无报告 → nil", ToggleFocusBranching.yabaiFocusCandidate(nil, frontPID: 100) == nil)
        check("branch2: id 缺失 → nil",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(nil, pid: 100), frontPID: 100) == nil)
        check("branch2: id 超出 UInt32 → nil（UInt32(exactly:) 失败）",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(4_294_967_296, pid: 100), frontPID: 100) == nil
              && ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(-1, pid: 100), frontPID: 100) == nil)
        check("branch2: pid 不一致 → nil（yabai/系统焦点不同步，回退 AX）",
              ToggleFocusBranching.yabaiFocusCandidate(yabaiInfo(77, pid: 200), frontPID: 100) == nil)

        // 分支 3 身份落位：全量快照按 windowID 查，不过滤 layer/onScreen（AX 认定不二次裁剪）。
        let fullList = [win(1), win(9, layer: 5, onScreen: false)]
        check("branch3: 按 windowID 命中（含离屏/高层窗口）",
              ToggleFocusBranching.axIdentityEntry(cgList: fullList, winID: 9)?.windowID == 9)
        check("branch3: 查不到 → nil（调用壳降位仅记 windowID/AX）",
              ToggleFocusBranching.axIdentityEntry(cgList: fullList, winID: 42) == nil)
    }

    }

    // MARK: FrameConvergence.convergeFrame（真实实现直测——镜像测试锁副本，本段锁真身，Batch 11）

    do {
        // convergeFrame 语义契约（FrameConvergenceLoopTests 锁副本；此处真身逐分支）：
        // write→settle→read→判据；write 硬失败短路；read nil 不终止；attempts 归一。

        // C1. 首轮即收敛：write 1 次、settle 1 次、read 1 次。
        do {
            var calls: [String] = []
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3,
                settleMicros: 1,
                write: { calls.append("write"); return true },
                read: { calls.append("read"); return CGRect(x: 0, y: 0, width: 100, height: 100) },
                isConverged: { _ in true },
                sleep: { _ in calls.append("settle") }
            )
            check("convergeFrame C1: converged(attempt:1) 且序列 write→settle→read",
                  outcome == .converged(attempt: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                  && calls == ["write", "settle", "read"])
        }

        // C2. 第 3 轮收敛：前两轮判据不满足，attempt 计数如实。
        do {
            var round = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { true },
                read: { CGRect(x: round * 10, y: 0, width: 100, height: 100) },
                isConverged: { _ in
                    round += 1
                    return round >= 3
                },
                sleep: { _ in }
            )
            check("convergeFrame C2: 第 3 轮收敛 attempt=3", 
                  outcome == .converged(attempt: 3, frame: CGRect(x: 20, y: 0, width: 100, height: 100)))
        }

        // C3. 走满轮数不收敛 → mismatched（lastFrame=最后一次读回）。
        do {
            let outcome = FrameConvergence.convergeFrame(
                attempts: 2, settleMicros: 1,
                write: { true },
                read: { CGRect(x: 5, y: 5, width: 50, height: 50) },
                isConverged: { _ in false },
                sleep: { _ in }
            )
            check("convergeFrame C3: mismatched(attempts:2, lastFrame)",
                  outcome == .mismatched(attempts: 2, lastFrame: CGRect(x: 5, y: 5, width: 50, height: 50)))
        }

        // C4. write 硬失败：当轮短路（无 settle/read），attempt 计入。
        do {
            var writes = 0
            var settles = 0
            var reads = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { writes += 1; return writes < 2 },  // 第 2 轮 write 失败
                read: { reads += 1; return CGRect(x: 0, y: 0, width: 1, height: 1) },
                isConverged: { _ in false },
                sleep: { _ in settles += 1 }
            )
            check("convergeFrame C4: writeFailed(attempt:2)；失败轮不进 settle/read（写2/settle1/read1）",
                  outcome == .writeFailed(attempt: 2) && writes == 2 && settles == 1 && reads == 1)
        }

        // C5. read 持续 nil：轮次继续（不终止、不计收敛），走满后 mismatched(lastFrame=nil)。
        do {
            var reads = 0
            let outcome = FrameConvergence.convergeFrame(
                attempts: 3, settleMicros: 1,
                write: { true },
                read: { reads += 1; return nil },
                isConverged: { _ in true },               // 有读即判收敛——nil 读不该触发
                sleep: { _ in }
            )
            check("convergeFrame C5: nil 读不终止不收敛（3 读后 mismatched lastFrame=nil）",
                  outcome == .mismatched(attempts: 3, lastFrame: nil) && reads == 3)
        }

        // C6. attempts=0 归一为 1（防 1...0 崩溃）。
        do {
            let outcome = FrameConvergence.convergeFrame(
                attempts: 0, settleMicros: 1,
                write: { true },
                read: { CGRect(x: 0, y: 0, width: 1, height: 1) },
                isConverged: { _ in false },
                sleep: { _ in }
            )
            check("convergeFrame C6: attempts=0 归一 1 轮 mismatched",
                  outcome == .mismatched(attempts: 1, lastFrame: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
    }

    // MARK: CoordinateKit 真实实现直测（访问器与 NSScreen 依赖函数，Batch 11）

    do {
        // QuartzRect 访问器与换算。
        let qr = QuartzRect(x: 3, y: 4, width: 100, height: 50)
        check("coordKit: midX/midY/maxX/maxY", qr.midX == 53 && qr.midY == 29 && qr.maxX == 103 && qr.maxY == 54)
        check("coordKit: cgRect 换算", qr.cgRect == CGRect(x: 3, y: 4, width: 100, height: 50))
        check("coordKit: sizeDescription", qr.sizeDescription == "100x50")

        // DisplayIdentifier / SpaceIdentifier 便捷构造。
        check("coordKit: DisplayIdentifier.yabai/.cgDisplay 构造",
              DisplayIdentifier.yabai(2) == .yabaiIndex(2) && DisplayIdentifier.cgDisplay(7) == .cgDirectDisplayID(7))
        check("coordKit: SpaceIdentifier.native 构造",
              SpaceIdentifier.native(9) == .nativeID(9))

        // NSScreen 依赖函数（Runner 跑在 GUI 会话，screens 非空）。
        if let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first {
            check("coordKit: mainScreenQuartzFrame 非空且含原点屏 frame",
                  CoordinateKit.mainScreenQuartzFrame == mainScreen.frame)
            check("coordKit: isOnMainScreen(mainScreen 中心)=true",
                  CoordinateKit.isOnMainScreen(CGPoint(x: mainScreen.frame.midX, y: mainScreen.frame.midY)))
            check("coordKit: isOnMainScreen(远点)=false",
                  !CoordinateKit.isOnMainScreen(CGPoint(x: 99_999, y: 99_999)))
            check("coordKit: mainScreenHeight > 0", CoordinateKit.mainScreenHeight > 0)
            let yabaiIdx = CoordinateKit.yabaiDisplayIndex(for: mainScreen)
            check("coordKit: yabaiDisplayIndex(主屏)=1", yabaiIdx == 1)
            check("coordKit: nsScreen(forYabaiDisplayIndex:1) 回主屏",
                  CoordinateKit.nsScreen(forYabaiDisplayIndex: 1) != nil)
            check("coordKit: nsScreen(越界 99)=nil（防御分支）",
                  CoordinateKit.nsScreen(forYabaiDisplayIndex: 99) == nil)
            check("coordKit: quartzVisibleFrame 非空且在屏 frame 内（visibleFrame ⊆ frame）",
                  CoordinateKit.quartzVisibleFrame(of: mainScreen).width <= mainScreen.frame.width
                  && CoordinateKit.quartzVisibleFrame(of: mainScreen).height <= mainScreen.frame.height)
            check("coordKit: clampFrame 夹取（屏外点收回 bounds）",
                  CoordinateKit.clampFrame(CGRect(x: 9_999, y: 9_999, width: 50, height: 50),
                                           into: mainScreen.frame).maxX <= mainScreen.frame.maxX)
            check("coordKit: cocoaY/quartzY 往返自洽",
                  CoordinateKit.cocoaY(fromQuartzY: CoordinateKit.quartzY(fromCocoaY: 37)) == 37)
        }

        // 纯收敛判据（真身直测，Batch 4 nonisolated 化后的回归位）。
        check("coordKit: isFrameConverged 漂移和判据",
              CoordinateKit.isFrameConverged(actual: CGRect(x: 8, y: 0, width: 100, height: 100),
                                             target: CGRect(x: 0, y: 0, width: 100, height: 100),
                                             tolerance: 20)
              && !CoordinateKit.isFrameConverged(actual: CGRect(x: 21, y: 0, width: 100, height: 100),
                                                 target: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                 tolerance: 20))
    }

    // MARK: FloatSettle（真实实现——float 脱管→等重摆→缓存失效唯一序列原语，Batch 6）

    do {
        // A. 真 toggle：setFloat 恰一次 → 睡下限 → 稳定早返回 → 缓存恒清，顺序锁定。
        do {
            var events: [String] = []
            var sleeps: [useconds_t] = []
            var polls: [UInt32] = []
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42,
                operationID: "fs-a",
                knownWindowInfo: nil,
                tolerance: 20,
                setFloat: { id, op, _ in events.append("float(\(id),\(op))"); return .toggled },
                read: { _ in CGRect(x: 0, y: 0, width: 800, height: 600) },
                clearCache: { events.append("clear") },
                sleep: { sleeps.append($0); events.append("sleep") },
                pollSleep: { polls.append($0); events.append("poll") }
            )
            check("floatsettle A: 序列 float→sleep→poll→clear（真身）",
                  events == ["float(42,fs-a)", "sleep", "poll", "clear"])
            check("floatsettle A: 下限取 WindowSettle.floatRelayoutMinSettleMicros（120ms）",
                  sleeps == [WindowSettle.floatRelayoutMinSettleMicros])
            check("floatsettle A: 两读稳定即早返回（1 拍 25ms）",
                  polls == [WindowSettle.frameVerifyPollIntervalMs])
            check("floatsettle A: didToggle=true 如实上报", outcome.didToggle)
        }

        // B. skippedNoOp（已 float/unmanaged/query-nil）：零等待、缓存仍恒清。
        do {
            var waitEvents = 0
            var clears = 0
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-b", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .skippedNoOp },
                read: { _ in waitEvents += 1; return nil },
                clearCache: { clears += 1 },
                sleep: { _ in waitEvents += 1 }, pollSleep: { _ in waitEvents += 1 })
            check("floatsettle B: 已 float 零读零等待", waitEvents == 0)
            check("floatsettle B: 缓存恒清语义（跳过场景仍清一次）", clears == 1)
            check("floatsettle B: didToggle=false 如实上报", !outcome.didToggle)
        }

        // C. 预算兜底（μs→ms 修正回归金丝雀）：永不稳定走满 300ms = 12 拍。
        //    Batch 6 前四处手抄直传微秒值（budgetMs=300_000 → 病理路径轮询 100 分钟），
        //    本断言锁死换算，防回归。
        do {
            var polls = 0
            var readN = 0
            let outcome = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-c", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .toggled },
                read: { _ in readN += 1; return CGRect(x: readN * 100, y: 0, width: 800, height: 600) },
                clearCache: {},
                sleep: { _ in }, pollSleep: { _ in polls += 1 })
            check("floatsettle C: 预算按毫秒计（300ms=12 拍，而非 30 万拍 100 分钟）", polls == 12 && readN == 13)
            check("floatsettle C: 走满预算仍如实上报 didToggle", outcome.didToggle)
        }

        // D. isSame 判据真身策略 + E. 读全 nil 防御（B84：FloatSettleSequenceTests 镜像退役，缺口语义转真身）
        do {
            // 相邻两读漂移 8（≤ 容差 20，单轴）→ 1 拍稳定早返回
            var beat = 0
            var pollsD2 = 0
            let d2 = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-d2", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .toggled },
                read: { _ in beat += 1; return CGRect(x: 0, y: 0, width: 800, height: beat == 1 ? 600 : 608) },
                clearCache: {}, sleep: { _ in }, pollSleep: { _ in pollsD2 += 1 })
            check("floatsettle D: 相邻两读漂移 8 ≤ 容差 20 → 1 拍稳定", d2.didToggle && pollsD2 == 1)
            // 相邻两读漂移 21（> 容差 20）→ 永不误判稳定，走满 12 拍
            var drift = 0
            var pollsD1 = 0
            _ = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-d1", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .toggled },
                read: { _ in drift += 1; return CGRect(x: drift * 21, y: 0, width: 800, height: 600) },
                clearCache: {}, sleep: { _ in }, pollSleep: { _ in pollsD1 += 1 })
            check("floatsettle D: 相邻两读漂移 21 > 容差 20 → 不误判稳定（走满 12 拍）", pollsD1 == 12)
            // 读全 nil：走满预算不崩溃、缓存仍清、didToggle 如实
            var pollsE = 0
            var clearsE = 0
            let e1 = FloatSettle.floatAndSettle(
                windowID: 42, operationID: "fs-e", knownWindowInfo: nil, tolerance: 20,
                setFloat: { _, _, _ in .toggled },
                read: { _ in nil },
                clearCache: { clearsE += 1 }, sleep: { _ in }, pollSleep: { _ in pollsE += 1 })
            check("floatsettle E: 读全 nil 走满预算不崩溃、缓存仍清",
                  pollsE == 12 && clearsE == 1 && e1.didToggle)
        }
    }

    // MARK: MoveToMainPipeline（真实实现——move_to_main 阶段管线，Batch 7）

    do {
        final class Rec {
            var events: [String] = []
            var floatIDs: [UInt32] = []
            var saveArgs: (windowID: UInt32, origFrame: CGRect)?
            var postCheckWindowID: UInt32?
            var notifyCount = 0
        }

        let sysWideAX = AXUIElementCreateSystemWide()
        let identity = WindowIdentity(windowID: 42, pid: 100, bundleIdentifier: "com.test.app", appName: "Test", windowNumber: nil, title: "t")
        let realScreen = NSScreen.screens.first!
        let mainScreenFrame = realScreen.frame
        let knownFrame = CGRect(x: -800, y: -700, width: 1146, height: 707)
        let axReadFrame = CGRect(x: -810, y: -710, width: 1146, height: 707)
        let onMainCenterFrame = CGRect(x: mainScreenFrame.midX, y: mainScreenFrame.midY, width: 800, height: 600)

        /// 假通道工厂：默认「AX 路径 happy path」配置，场景按需覆盖。
        func makeDeps(
            _ rec: Rec,
            hasAX: Bool = true,
            visSpace: SpaceIdentifier? = .yabaiIndex(1),
            resolveOK: Bool = true,
            axFrameToRead: CGRect?,
            queryDisplay: Int? = 2,
            settableOK: Bool = true,
            applyDirectOK: Bool = true,
            applyAXOK: Bool = true,
            handleOK: Bool = true
        ) -> MoveToMainPipeline.Deps {
            MoveToMainPipeline.Deps(
                hasAX: { rec.events.append("hasAX"); return hasAX },
                notifyAXRequired: { rec.notifyCount += 1 },
                captureSpaceContext: { _, _ in
                    rec.events.append("capture")
                    return SpaceContext(sourceSpaceIndex: .yabaiIndex(5), targetSpaceIndex: nil,
                                        sourceDisplayIndex: .yabaiIndex(2), sourceDisplaySpaceIndex: 7)
                },
                visibleSpaceIndexOfMainDisplay: { rec.events.append("visSpace"); return visSpace },
                floatAndSettle: { id, _, _ in
                    rec.events.append("float"); rec.floatIDs.append(id)
                    return FloatSettle.Outcome(didToggle: true, durationMs: 123)
                },
                resolveWindow: { _ in rec.events.append("resolve"); return resolveOK ? sysWideAX : nil },
                readAXFrame: { _ in rec.events.append("readAXFrame"); return axFrameToRead },
                queryWindow: { _ in
                    rec.events.append("query")
                    return queryDisplay.map {
                        YabaiWindowInfo(id: 42, pid: 100, app: "App", title: "t", space: 5, display: $0,
                                        frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true,
                                        isMinimizedRaw: false, hasFocusRaw: false)
                    }
                },
                isSettable: { _ in rec.events.append("settable"); return settableOK },
                mainScreen: { rec.events.append("mainScreen"); return realScreen },
                targetFrameFor: { _ in
                    rec.events.append("targetFrame")
                    return CGRect(x: 75, y: 38, width: mainScreenFrame.width, height: mainScreenFrame.height)
                },
                targetDisplayIndexOf: { _ in rec.events.append("targetIndex"); return 1 },
                windowHandleOf: { _ in rec.events.append("handle"); return handleOK ? 77 : nil },
                visibleFrameOfYabaiDisplay: { _ in rec.events.append("sourceVisible"); return CGRect(x: 0, y: 0, width: 3440, height: 1440) },
                applyFrameDirect: { _, _, _, _ in rec.events.append("applyDirect"); return applyDirectOK },
                applyAX: { _, _, _, _ in rec.events.append("applyAX"); return applyAXOK },
                postCheck: { _, id, _, _, _, _ in
                    rec.events.append("postCheck"); rec.postCheckWindowID = id; return 8
                },
                save: { _, id, orig, _, _, _, _ in
                    rec.events.append("save"); rec.saveArgs = (id, orig); return 3
                }
            )
        }

        // A. AX 路径 happy path：origFrame 来自 AX 读（apply 前），apply 后 post-check→save。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "A", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame))
            check("pipeline A: AX 路径结局 moved(effectiveWindowID=77)", result.outcome == .moved(effectiveWindowID: 77))
            check("pipeline A: 序列 hasAX→capture→readAXFrame→query→settable→mainScreen→target→float→applyAX→postCheck→save",
                  rec.events == ["hasAX", "capture", "readAXFrame", "query", "settable", "mainScreen", "targetFrame", "targetIndex", "handle", "float", "applyAX", "postCheck", "save"])
            check("pipeline A: AX 路径 float 恰一次（apply 前、用 effectiveWindowID）", rec.floatIDs == [77])
            check("pipeline A: save 收到的 origFrame = AX 快照读值", rec.saveArgs?.origFrame == axReadFrame)
            check("pipeline A: postCheck 用 effectiveWindowID", rec.postCheckWindowID == 77)
        }

        // B. P2 路径 happy path：预 float 恰一次，origFrame 用 knownOrigFrame（绝不 AX 读）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "B", knownWindowAX: nil, knownOrigFrame: knownFrame, deps: makeDeps(rec, axFrameToRead: nil))
            check("pipeline B: P2 路径结局 moved(77)", result.outcome == .moved(effectiveWindowID: 77))
            check("pipeline B: 序列 capture→visSpace→float→resolve→query→…→sourceVisible→applyDirect→postCheck→save",
                  rec.events == ["hasAX", "capture", "visSpace", "float", "resolve", "query", "settable", "mainScreen", "targetFrame", "targetIndex", "handle", "sourceVisible", "applyDirect", "postCheck", "save"])
            check("pipeline B: readAXFrame 未被调用（a049a86 快照时机铁律）", !rec.events.contains("readAXFrame"))
            check("pipeline B: float 恰一次（预 float，窗口 42）", rec.floatIDs == [42])
            check("pipeline B: save 收到 knownOrigFrame", rec.saveArgs?.origFrame == knownFrame)
            check("pipeline B: floatMs = P2 预 float 段耗时", result.timings.floatMs == result.timings.p2SpaceMoveMs)
        }

        // C. AX 路径已在主屏：skip 短路（不 settable/不 apply/不 post-check/不 save）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "C", knownWindowAX: sysWideAX, knownOrigFrame: nil,
                                                deps: makeDeps(rec, axFrameToRead: onMainCenterFrame, queryDisplay: 1))
            check("pipeline C: 已在主屏 → alreadyOnMain", result.outcome == .alreadyOnMain)
            check("pipeline C: 序列止于 skip 检查（短路 settable/apply/save）",
                  rec.events == ["hasAX", "capture", "readAXFrame", "query", "mainScreen"])
        }

        // D. AX 拒绝：notify 恰一次，其余一切短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "D", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, hasAX: false, axFrameToRead: nil))
            check("pipeline D: ax_denied", result.outcome == .failed(stage: "ax_denied"))
            check("pipeline D: 无任何通道调用 + notify 恰一次", rec.events == ["hasAX"] && rec.notifyCount == 1)
        }

        // E. P2 主屏 visible space 解析失败：float 之前短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "E", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, visSpace: nil, axFrameToRead: nil))
            check("pipeline E: visible_space 失败", result.outcome == .failed(stage: "visible_space"))
            check("pipeline E: float 未被发起", !rec.events.contains("float"))
        }

        // F. P2 resolve 失败：float 已发生（真实序），apply/post-check/save 短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "F", knownWindowAX: nil, knownOrigFrame: nil, deps: makeDeps(rec, resolveOK: false, axFrameToRead: nil))
            check("pipeline F: resolve_window 失败", result.outcome == .failed(stage: "resolve_window"))
            check("pipeline F: 序列止于 resolve（float 已发生，无 apply/save）",
                  rec.events == ["hasAX", "capture", "visSpace", "float", "resolve"])
        }

        // G. origFrame 不可读：快照 guard 短路（query 都不发起）。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "G", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: nil))
            check("pipeline G: orig_frame 失败", result.outcome == .failed(stage: "orig_frame"))
            check("pipeline G: 序列止于 AX 快照读", rec.events == ["hasAX", "capture", "readAXFrame"])
        }

        // H. settable false：不解析主屏不 apply。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "H", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame, settableOK: false))
            check("pipeline H: settable 失败", result.outcome == .failed(stage: "settable"))
            check("pipeline H: 序列止于 settable", rec.events == ["hasAX", "capture", "readAXFrame", "query", "settable"])
        }

        // I. P2 frame 直写不收敛：post-check/save 短路。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "I", knownWindowAX: nil, knownOrigFrame: knownFrame, deps: makeDeps(rec, axFrameToRead: nil, applyDirectOK: false))
            check("pipeline I: apply_p2 失败", result.outcome == .failed(stage: "apply_p2"))
            check("pipeline I: 无 postCheck/save", !rec.events.contains("postCheck") && !rec.events.contains("save"))
        }

        // J. AX apply 失败：post-check/save 短路；float 恰一次。
        do {
            let rec = Rec()
            let result = MoveToMainPipeline.run(identity: identity, op: "J", knownWindowAX: sysWideAX, knownOrigFrame: nil, deps: makeDeps(rec, axFrameToRead: axReadFrame, applyAXOK: false))
            check("pipeline J: apply_ax 失败", result.outcome == .failed(stage: "apply_ax"))
            check("pipeline J: float 恰一次且无 postCheck/save",
                  rec.floatIDs == [77] && !rec.events.contains("postCheck") && !rec.events.contains("save"))
        }

        // L. windowHandle 解析失败 → effectiveWindowID 回退 identity.windowID；
        //    space 上下文字段为 nil 时日志分支如实降级。
        do {
            let rec = Rec()
            let result2 = MoveToMainPipeline.run(identity: identity, op: "L2", knownWindowAX: sysWideAX, knownOrigFrame: nil,
                                                 deps: makeDeps(rec, axFrameToRead: axReadFrame, handleOK: false))
            check("pipeline L: windowHandle nil → 回退 identity.windowID",
                  result2.outcome == .moved(effectiveWindowID: 42))
        }

        // K. skip 纯决策（真实实现直锁；镜像另立 MoveToMainSkipDecisionTests）。
        check("pipeline K: display≠1 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 2, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: display nil 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: nil, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: 主屏 frame nil 不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: nil, frame: onMainCenterFrame))
        check("pipeline K: 中心在主屏内 → skip", MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreenFrame, frame: onMainCenterFrame))
        check("pipeline K: 中心在主屏外不 skip", !MoveToMainPipeline.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreenFrame, frame: CGRect(x: -800, y: -700, width: 400, height: 300)))
    }
    }
}
