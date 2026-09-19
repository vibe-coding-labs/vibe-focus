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

        // I. B182 直方图桶（恰等边界进高桶）。
        check("perf I1: 9.9ms → <10 桶", PerfMonitorLogic.bucketIndex(durationMs: 9.9) == 0)
        check("perf I2: 10ms → 10-50 桶", PerfMonitorLogic.bucketIndex(durationMs: 10) == 1)
        check("perf I3: 200ms → 200-1k 桶", PerfMonitorLogic.bucketIndex(durationMs: 200) == 3)
        check("perf I4: 1000ms → >=1k 桶", PerfMonitorLogic.bucketIndex(durationMs: 1000) == 4)
        var bucketed: PerfMonitorLogic.CounterSnapshot?
        PerfMonitorLogic.record(counter: &bucketed, name: "restore", durationMs: 7)
        PerfMonitorLogic.record(counter: &bucketed, name: "restore", durationMs: 2253)
        check("perf I5: 直方图分桶累计", bucketed?.buckets == [1, 0, 0, 0, 1])
        check("perf I6: 桶摘要格式", PerfMonitorLogic.bucketSummary([1, 0, 0, 0, 1]) == "<10:1/10-50:0/50-200:0/200-1k:0/>=1k:1")

        // J. B182 journal 环形缓冲（容量裁剪 + dropped 计数）。
        var ring = PerfMonitorLogic.JournalRing(capacity: 3)
        ring.append("a"); ring.append("b"); ring.append("c")
        check("perf J1: 未满全保留", ring.entries == ["a", "b", "c"] && ring.dropped == 0)
        ring.append("d")
        check("perf J2: 满后淘汰最旧", ring.entries == ["b", "c", "d"] && ring.dropped == 1)

        // K. B182 stallReport 带 journal 段（空 journal 不出段——旧格式兼容）。
        let reportNoJournal = PerfMonitorLogic.stallReport(deltaS: 1.0, sections: [], counters: [], now: base)
        check("perf K1: 空 journal 不出段", !reportNoJournal.contains("journal=["))
        let reportWithJournal = PerfMonitorLogic.stallReport(
            deltaS: 1.0, sections: [], counters: [], now: base,
            journal: ["[+100ms M] ▶hook.Stop", "[+200ms M] ▶move.toMain"])
        check("perf K2: journal 段含主线程轨迹", reportWithJournal.contains("journal=[") && reportWithJournal.contains("▶hook.Stop"))

        // L. B182 Doctor 快照渲染：直方图 + 停顿历史 + journal 尾。
        let richSnapshot = try? JSONEncoder().encode(PerfMonitorLogic.SnapshotFile(
            generatedAt: base,
            stallCount: 1,
            lastStallDeltaS: 1.5,
            lastStallAt: base,
            counters: [bucketed].compactMap { $0 },
            journal: ["[+1ms M] ▶bubble.summon"],
            stalls: [PerfMonitorLogic.StallRecord(at: base, deltaMs: 1500, level: "ERROR", sectionsSummary: "hook.Stop>move.toMain", stackSummary: "sampled(12 frames)")]
        ))
        let rich = Doctor.perfReportLines(snapshotData: richSnapshot, stallLogLines: [], now: base).joined(separator: "\n")
        check("perf L1: 直方图渲染", rich.contains(">=1k:1"))
        check("perf L2: 停顿历史渲染", rich.contains("停顿历史") && rich.contains("hook.Stop>move.toMain") && rich.contains("sampled(12 frames)"))
        check("perf L3: journal 尾渲染", rich.contains("▶bubble.summon"))

        // M. B190 ShellRunner 主线程 fork 埋点：命名契约 + 告警判定 + journal 静默名单。
        check("perf M1: 后台 fork 计数名 shell.<bin>", PerfMonitorLogic.shellCounterName(executable: "/opt/homebrew/bin/yabai", isMainThread: false) == "shell.yabai")
        check("perf M2: 主线程 fork 计数名 shell.main.<bin>", PerfMonitorLogic.shellCounterName(executable: "/opt/homebrew/bin/yabai", isMainThread: true) == "shell.main.yabai")
        check("perf M3: osascript 主线程命名", PerfMonitorLogic.shellCounterName(executable: "/usr/bin/osascript", isMainThread: true) == "shell.main.osascript")
        check("perf M4: 主线程 fork 告警阈值 = 100ms（契约锁）", PerfMonitorLogic.mainForkWarnMs == 100)
        check("perf M5: 主线程恰等阈值告警", PerfMonitorLogic.shouldWarnMainFork(isMainThread: true, durationMs: 100))
        check("perf M6: 主线程低于阈值不告警", !PerfMonitorLogic.shouldWarnMainFork(isMainThread: true, durationMs: 99.9))
        check("perf M7: 后台 fork 再慢也不告警", !PerfMonitorLogic.shouldWarnMainFork(isMainThread: false, durationMs: 2000))
        check("perf M8: 阈值可注入", PerfMonitorLogic.shouldWarnMainFork(isMainThread: true, durationMs: 50, thresholdMs: 50))
        let quiet = PerfMonitorLogic.journalQuietSections
        check("perf M9: 静默名单含四类周期区间", quiet == ["overlay.refreshIndices", "registry.purge", "bubble.followTick", "bubble.voiceYield"])
        check("perf M10: 关键路径不在静默名单（轨迹必须留）",
              !quiet.contains("toggle") && !quiet.contains("restore") && !quiet.contains("bubble.submit")
              && !quiet.contains("hook.request") && !quiet.contains("move.toMain"))

        // N. B190 运行时接线：measure 返回闭包值且落账；ShellRunner 真 fork 计入
        // shell[.main].<bin> 直方图（Runner 在主线程跑，名带 .main. 中段）。
        let measured = PerfMonitor.shared.measure("perf.test.measure") { 42 }
        check("perf N1: measure 返回闭包值", measured == 42)
        check("perf N2: measure 落账", PerfMonitor.shared.snapshotCounters().contains { $0.name == "perf.test.measure" && $0.count >= 1 })
        let echoName = PerfMonitorLogic.shellCounterName(executable: "/bin/echo", isMainThread: Thread.isMainThread)
        _ = ShellRunner.run(executable: "/bin/echo", arguments: ["vibefocus-perf-probe"])
        check("perf N3: ShellRunner 真 fork 落账（\(echoName)）", PerfMonitor.shared.snapshotCounters().contains { $0.name == echoName && $0.count >= 1 })

        // O. B194 窗口迁移健康报告行（--diagnose 一键体检的纯渲染层）。
        do {
            let healthy = Doctor.windowMigrationReportLines(
                auditNewestAgeS: 240,
                hookResponses: [("stay_on_current_screen", 12), ("restored_to_original", 3)],
                rollbackOK: 2, rollbackFailed: 0, mainForkRecent: 1).joined(separator: "\n")
            check("perf O1: 审计新鲜（<1h）报正常分钟数", healthy.contains("审计通道: 正常（最新记录 4 分钟前）"))
            check("perf O2: 响应分布按次数列出 top", healthy.contains("stay_on_current_screen×12") && healthy.contains("restored_to_original×3"))
            check("perf O3: 回滚计数与主线程 fork 计数渲染",
                  healthy.contains("残窗回滚: 成功 2 / 失败 0") && healthy.contains("主线程 fork(≥100ms, 日志尾): 1 次"))
            let stale = Doctor.windowMigrationReportLines(
                auditNewestAgeS: 4 * 3600 + 120, hookResponses: [], rollbackOK: 0, rollbackFailed: 1, mainForkRecent: 0).joined(separator: "\n")
            check("perf O4: 审计 >1h 亮断写告警（历史事故口径）",
                  stale.contains("审计通道: ⚠️ 疑似断写（最新记录 4 小时前"))
            check("perf O5: 回滚失败>0 提示 grep rollback", stale.contains("失败 1") && stale.contains("grep rollback"))
            let empty = Doctor.windowMigrationReportLines(
                auditNewestAgeS: nil, hookResponses: [], rollbackOK: 0, rollbackFailed: 0, mainForkRecent: 0).joined(separator: "\n")
            check("perf O6: 表空/不可读亮 ⚠️ 无任何记录 + 响应分布暂无数据",
                  empty.contains("审计通道: ⚠️ 无任何记录") && empty.contains("Hook 响应分布: 暂无数据"))
        }
    }
}

extension RunnerHarness {
    /// B224：崩溃报告 IPS 解析通道直测——首行 meta + JSON payload 双段格式、
    /// 单行/坏 JSON/非字典守卫（诊断日志副作用无害）。
    func runCrashIPSParserTests() {
        print("\n=== CrashIPSParser (B224) ===")
        let payload = #"{"occurrence":{"captureTime":"2026-09-19"},"procName":"VibeFocus","faultingThread":0}"#
        let ips = "Meta\n" + payload
        let ok = CrashContextRecorder.shared.parseIPSJSONPayloadAndLog(from: ips)
        check("ips: 首行 meta 后 JSON 解出字段",
              (ok?["procName"] as? String) == "VibeFocus" && (ok?["faultingThread"] as? Int) == 0)
        check("ips: 单行无 payload → nil",
              CrashContextRecorder.shared.parseIPSJSONPayloadAndLog(from: "only-meta-line") == nil)
        check("ips: 坏 JSON → nil",
              CrashContextRecorder.shared.parseIPSJSONPayloadAndLog(from: "Meta\n{not-json") == nil)
        check("ips: JSON 非字典 → nil",
              CrashContextRecorder.shared.parseIPSJSONPayloadAndLog(from: "Meta\n[1,2,3]") == nil)
        check("ips: 空串 → nil",
              CrashContextRecorder.shared.parseIPSJSONPayloadAndLog(from: "") == nil)
    }
}

extension RunnerHarness {
    /// B225：崩溃取证/诊断通道注入式补测——captureTail URL 注入双分支（截尾语义 +
    /// 源缺失跳过）、sampleMainThread 冒烟、logDiagnostics/心跳注册冒烟（副作用=日志）。
    func runCrashForensicsIOTests() {
        print("\n=== CrashForensicsIO (B225) ===")
        let dir = "/tmp/vf-b225-forensics-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // --- captureTail：10 行源截尾 3 行；多余空行保留语义（omittingEmpty=false） ---
        let source = URL(fileURLWithPath: dir + "/app.log")
        let body = (1...10).map { "line-\($0)" }.joined(separator: "\n")
        try? body.data(using: .utf8)!.write(to: source)
        let output = URL(fileURLWithPath: dir + "/tail.txt")
        CrashContextRecorder.shared.captureTail(
            sourceURL: source, outputURL: output, lineLimit: 3, context: "b218", label: "app.log")
        let tail = try? String(contentsOf: output, encoding: .utf8)
        check("forensics: captureTail 截尾 3 行保序",
              tail == "line-8\nline-9\nline-10")
        let outputAll = URL(fileURLWithPath: dir + "/tail-all.txt")
        CrashContextRecorder.shared.captureTail(
            sourceURL: source, outputURL: outputAll, lineLimit: 100, context: "b218", label: "app.log")
        check("forensics: lineLimit 超行数全量保留",
              (try? String(contentsOf: outputAll, encoding: .utf8)) == body)

        // --- 源缺失：跳过分支（不产出输出文件、不崩） ---
        let missing = URL(fileURLWithPath: dir + "/missing.log")
        let outputSkip = URL(fileURLWithPath: dir + "/tail-skip.txt")
        CrashContextRecorder.shared.captureTail(
            sourceURL: missing, outputURL: outputSkip, lineLimit: 3, context: "b218", label: "missing.log")
        check("forensics: 源缺失跳过且无输出文件", !FileManager.default.fileExists(atPath: outputSkip.path))

        // --- logDiagnostics：冒烟（fork codesign 采集，副作用=日志） ---
        logDiagnostics("runner-b218")
        check("forensics: logDiagnostics 冒烟不崩", true)
    }
}

extension RunnerHarness {
    /// B226：诊断面补测——BacktraceSampler.symbolize 未命中回落 hex、DoctorPaths.live
    /// 路径契约、VibeFocusDoctor.report 冒烟。
    func runDiagnosticsSmallTests() {
        print("\n=== DiagnosticsSmall (B226) ===")
        check("diag: symbolize 空表 → 空数组", BacktraceSampler.symbolize([]) == [])
        check("diag: symbolize 野地址回落 0x hex",
              BacktraceSampler.symbolize([0x12345678]) == ["0x12345678"])

        let paths = DoctorPaths.live()
        check("diag: DoctorPaths.live 日志域路径契约",
              paths.logDir == NSHomeDirectory() + "/Library/Logs/VibeFocus"
              && paths.appLogPath == paths.logDir + "/vibefocus.log"
              && paths.keepaliveLogPath == "/tmp/vibefocus-keepalive.log"
              && paths.diagnosticReportsDir == NSHomeDirectory() + "/Library/Logs/DiagnosticReports")
        check("diag: DoctorPaths.live 临时快照路径在 tmp",
              paths.tmpFatalPath.hasPrefix("/tmp/") && paths.tmpSnapshotPath.hasPrefix("/tmp/"))

        let report = VibeFocusDoctor.report()
        check("diag: doctor report 冒烟非空", !report.isEmpty)
    }
}
