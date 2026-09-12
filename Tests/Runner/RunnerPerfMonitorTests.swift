import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPerfMonitorTests.swift — B178 常开性能监控（PerfMonitorLogic
// 纯判定层直测 + Doctor perfReportLines 报告纯函数 + 停顿行解析契约锁）。
// 运行时线程部分（心跳/看门狗 Thread）不进 Runner——真机验证走 [PERF][STALL] 日志。

extension RunnerHarness {

    func runPerfMonitorTests() {
        // A. 停顿分级阈值（恰等阈值算达到）。
        check("perf A1: 0.249s 不报告", PerfMonitorLogic.stallLevel(deltaS: 0.249) == nil)
        check("perf A2: 0.25s → warn（恰等达标）", PerfMonitorLogic.stallLevel(deltaS: 0.25) == .warn)
        check("perf A3: 0.999s → warn", PerfMonitorLogic.stallLevel(deltaS: 0.999) == .warn)
        check("perf A4: 1.0s → error（恰等升级）", PerfMonitorLogic.stallLevel(deltaS: 1.0) == .error)
        check("perf A5: 66s（实测最坏）→ error", PerfMonitorLogic.stallLevel(deltaS: 66.4) == .error)

        // B. 停顿重复报告节流：首报恒报；同一段停顿增长 <1s 不重报。
        check("perf B1: 首次停顿必报", PerfMonitorLogic.shouldReportStall(lastReportedS: nil, currentDeltaS: 0.3))
        check("perf B2: 增长 0.25s < 1s 不重报", !PerfMonitorLogic.shouldReportStall(lastReportedS: 0.3, currentDeltaS: 0.55))
        check("perf B3: 增长 ≥1s 重报（长阻塞阶梯可见）", PerfMonitorLogic.shouldReportStall(lastReportedS: 0.3, currentDeltaS: 1.3))
        check("perf B4: 恰好增长 1.0s 重报", PerfMonitorLogic.shouldReportStall(lastReportedS: 0.3, currentDeltaS: 1.3 + 0.0))

        // C. 计数器累加 + 非法值防御。
        var counter: PerfMonitorLogic.CounterSnapshot?
        PerfMonitorLogic.record(counter: &counter, name: "restore", durationMs: 300)
        PerfMonitorLogic.record(counter: &counter, name: "restore", durationMs: 2253)
        PerfMonitorLogic.record(counter: &counter, name: "restore", durationMs: -1)
        PerfMonitorLogic.record(counter: &counter, name: "restore", durationMs: .nan)
        check("perf C1: count 只计合法值", counter?.count == 2)
        check("perf C2: totalMs 累计合法值", counter?.totalMs == 2553)
        check("perf C3: maxMs 取峰值", counter?.maxMs == 2253)

        // D. Top-K 排序（maxMs 降序，name 升序破平局）+ limit。
        var table: [String: PerfMonitorLogic.CounterSnapshot] = [:]
        for (name, maxMs) in ["a.move": 8707.0, "b.ups": 2253.0, "c.ups": 2253.0, "d.stop": 66461.0] {
            var c: PerfMonitorLogic.CounterSnapshot?
            PerfMonitorLogic.record(counter: &c, name: name, durationMs: maxMs)
            table[name] = c
        }
        let top = PerfMonitorLogic.topCounters(table, limit: 3)
        check("perf D1: Top-K 按 maxMs 降序", top.map(\.name) == ["d.stop", "a.move", "b.ups"])
        // 平局破平：b.ups/c.ups 同 maxMs 时 name 升序（b 在 c 前）。
        check("perf D2: 平局 name 升序破平", top[2].name == "b.ups" && PerfMonitorLogic.topCounters(table, limit: 4).map(\.name).dropFirst(3).first == "c.ups")
        check("perf D3: limit 截断", PerfMonitorLogic.topCounters(table, limit: 2).count == 2)

        // E. 区间栈 push/pop 嵌套 + 下溢防御（endSection 多调不崩）。
        var stack: [PerfMonitorLogic.Section] = []
        let base = Date()
        stack = PerfMonitorLogic.push(stack: stack, section: .init(name: "hook.request", fields: [:], startedAt: base))
        stack = PerfMonitorLogic.push(stack: stack, section: .init(name: "hook.Stop", fields: [:], startedAt: base))
        check("perf E1: 嵌套压栈深度 2", stack.count == 2 && stack.last?.name == "hook.Stop")
        let (popped1, remaining1) = PerfMonitorLogic.pop(stack: stack)
        check("perf E2: 弹出后进先出", popped1?.name == "hook.Stop" && remaining1.count == 1 && remaining1.last?.name == "hook.request")
        let (popped2, remaining2) = PerfMonitorLogic.pop(stack: remaining1)
        let (popped3, remaining3) = PerfMonitorLogic.pop(stack: remaining2)
        check("perf E3: 空栈下溢返回 nil 不崩", popped2?.name == "hook.request" && popped3 == nil && remaining3.isEmpty)
        check("perf E4: 区间耗时计算", abs((popped2?.elapsedMs(now: base.addingTimeInterval(0.5)) ?? -1) - 500.0) < 0.001)

        // F. 停顿报告格式（日志/快照同语言契约）。
        let sections = [
            PerfMonitorLogic.Section(name: "hook.Stop", fields: ["session": "abc12345"], startedAt: base),
            PerfMonitorLogic.Section(name: "move.toMain", fields: [:], startedAt: base),
        ]
        let report = PerfMonitorLogic.stallReport(
            deltaS: 2.31,
            sections: sections,
            counters: top,
            now: base.addingTimeInterval(2.31)
        )
        check("perf F1: 报告含停顿时长", report.contains("2.31s"))
        check("perf F2: 报告含父子区间链+字段", report.contains("sections=[hook.Stop session=abc12345(2.3s) > move.toMain(2.3s)]"))
        check("perf F3: 报告含计数器 Top", report.contains("d.stop×1 max=66461.0ms"))

        // G. 停顿日志行解析（看门狗日志 → Doctor 报告的契约锁）。
        let stallLine = "[2026-09-12T09:24:30.585Z] [ERROR] [PERF][STALL] main thread blocked 2.31s sections=[hook.Stop] top=[d.stop×1 max=66461.0ms avg=66461.0ms] pid=9796 seq=1 tid=7 deltaMs=2310 sections=2 stallCount=1"
        let parsed = PerfMonitor.parseStallLogLine(stallLine)
        check("perf G1: 解析时间戳", parsed?.at == "2026-09-12T09:24:30.585Z")
        check("perf G2: 解析 deltaMs", parsed?.deltaMs == 2310)
        check("perf G3: 解析级别 ERROR", parsed?.level == "ERROR")
        let warnLine = stallLine.replacingOccurrences(of: "[ERROR]", with: "[WARN]")
        check("perf G4: WARN 级别解析", PerfMonitor.parseStallLogLine(warnLine)?.level == "WARN")
        check("perf G5: 非停顿行拒绝", PerfMonitor.parseStallLogLine("[2026-09-12T09:24:30.585Z] [INFO] [REFRESH] all-spaces fast path") == nil)

        // H. Doctor perfReportLines 报告行（三态：无记录/仅快照/停顿+快照）。
        let empty = Doctor.perfReportLines(snapshotData: nil, stallLogLines: [], now: base).joined(separator: "\n")
        check("perf H1: 无记录给明确交代", empty.contains("无停顿记录、无快照文件"))
        let snapshotJSON = try? JSONEncoder().encode(PerfMonitorLogic.SnapshotFile(
            generatedAt: base,
            stallCount: 3,
            lastStallDeltaS: 2.31,
            lastStallAt: base,
            counters: top
        ))
        let withSnapshot = Doctor.perfReportLines(snapshotData: snapshotJSON, stallLogLines: [], now: base).joined(separator: "\n")
        check("perf H2: 仅快照态", withSnapshot.contains("日志尾部无停顿行") && withSnapshot.contains("stallCount=3"))
        let full = Doctor.perfReportLines(snapshotData: snapshotJSON, stallLogLines: [stallLine], now: base).joined(separator: "\n")
        check("perf H3: 停顿+快照全量态", full.contains("日志尾部停顿 1 次") && full.contains("阻塞 2310ms"))
        let badJSON = Doctor.perfReportLines(snapshotData: Data("not-json".utf8), stallLogLines: [stallLine], now: base).joined(separator: "\n")
        check("perf H4: 快照损坏降级不崩", badJSON.contains("快照文件不存在") && badJSON.contains("日志尾部停顿 1 次"))
    }
}
