import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerCrashContextTests.swift — B216：CrashContextRecorder 可注入面直测
// （IPS 报文解析纯函数 / captureTail URL 注入 / 崩溃循环窗口判定 / appendEvent 滚动截断）。
// shared 单例的 state 全程快照-还原，不污染 /tmp 生产上下文。

extension RunnerHarness {
    func runCrashContextTests() {
        // ===== parseIPSJSONPayload：首行头 + JSON 载荷的 ips 格式 =====
        do {
            let good = CrashContextRecorder.parseIPSJSONPayload(
                from: #"{"app":"x"}"# + "\n" + #"{"captureTime":"2026-09-19","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"}}"#)
            check("crashCtx: 合法 ips 报文解析出载荷", good?["captureTime"] as? String == "2026-09-19")
            let exception = good?["exception"] as? [String: Any]
            check("crashCtx: 异常段可取", exception?["signal"] as? String == "SIGSEGV")

            check("crashCtx: 单行（无载荷行）→ nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: #"{"a":1}"#) == nil)
            check("crashCtx: 载荷非 JSON → nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: "header\nnot json at all") == nil)
            check("crashCtx: 空串 → nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: "") == nil)

            // 实例包装版（含日志编排）
            let inst = CrashContextRecorder.shared
            check("crashCtx: parse+log 包装返回同载荷",
                  inst.parseIPSJSONPayloadAndLog(from: "h\n{\"k\":1}")?["k"] as? Int == 1)
        }

        // ===== captureTail：URL 注入，尾部 N 行落盘；源缺失静默跳过 =====
        do {
            let dir = "/tmp/vibefocus-cctx-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let source = URL(fileURLWithPath: dir + "/src.log")
            let output = URL(fileURLWithPath: dir + "/tail.log")
            do {
                try "l1\nl2\nl3\nl4\nl5".data(using: .utf8)!.write(to: source)
            } catch {
                check("crashCtx: 夹具源文件写入失败", false)
            }
            let inst = CrashContextRecorder.shared
            inst.captureTail(sourceURL: source, outputURL: output, lineLimit: 3, context: "test", label: "t")
            let tail = try? String(contentsOf: output, encoding: .utf8)
            check("crashCtx: captureTail 截尾 3 行保序", tail == "l3\nl4\nl5")

            // lineLimit 大于总行数 → 全文
            let outputAll = URL(fileURLWithPath: dir + "/all.log")
            inst.captureTail(sourceURL: source, outputURL: outputAll, lineLimit: 50, context: "test", label: "t")
            check("crashCtx: lineLimit 超总行数 → 全文",
                  (try? String(contentsOf: outputAll, encoding: .utf8)) == "l1\nl2\nl3\nl4\nl5")

            // 源文件不存在 → 不产出输出
            let missing = URL(fileURLWithPath: dir + "/missing.log")
            let output2 = URL(fileURLWithPath: dir + "/tail2.log")
            inst.captureTail(sourceURL: missing, outputURL: output2, lineLimit: 3, context: "test", label: "t")
            check("crashCtx: 源缺失 → 跳过不产出", !FileManager.default.fileExists(atPath: output2.path))
        }

        // ===== 崩溃循环窗口判定三分支（previousCrashFatalAt 快照-还原） =====
        do {
            let inst = CrashContextRecorder.shared
            let savedFatalAt = inst.previousCrashFatalAt
            defer { inst.previousCrashFatalAt = savedFatalAt }

            inst.previousCrashFatalAt = nil
            check("crashCtx: 无致命记录 → 不在崩溃循环", !inst.isWithinCrashLoopWindow())
            inst.previousCrashFatalAt = Date().addingTimeInterval(-10)
            check("crashCtx: 10s 前致命 → 在循环窗口", inst.isWithinCrashLoopWindow())
            inst.previousCrashFatalAt = Date().addingTimeInterval(-3600)
            check("crashCtx: 1h 前致命 → 出窗", !inst.isWithinCrashLoopWindow())
        }

        // ===== appendEventLocked：无 state 跳过 / 追加 / 超 300 滚动截断（state 快照-还原） =====
        do {
            let inst = CrashContextRecorder.shared
            inst.stateLock.lock()
            let savedState = inst.state
            inst.state = nil
            inst.stateLock.unlock()
            defer {
                inst.stateLock.lock()
                inst.state = savedState
                inst.stateLock.unlock()
            }

            inst.appendEventLocked("no-state-event")   // state nil → skip 分支
            inst.stateLock.lock()
            let stillNil = inst.state == nil
            inst.stateLock.unlock()
            check("crashCtx: 无 state 追加被跳过", stillNil)

            inst.stateLock.lock()
            inst.state = CrashContextRecorder.SessionState(
                pid: 1, launchedAt: "t", cleanExit: false, events: [], lastIngestedCrashReport: nil)
            inst.stateLock.unlock()
            for i in 0..<(300 + 5) {
                inst.appendEventLocked("e\(i)")
            }
            inst.stateLock.lock()
            let events = inst.state?.events ?? []
            inst.stateLock.unlock()
            check("crashCtx: 超限滚动截断保尾部 300 条",
                  events.count == 300 && events.first?.hasSuffix(" e5") == true
                  && events.last?.hasSuffix(" e304") == true)
        }
    }

    // MARK: - B248：bootstrap/persist/record 全链（IO 面注入缝，生产 /tmp 上下文零触碰）

    /// 把 shared 的 IO 面整体缝到临时目录并返回还原闭包（路径默认值 = 生产字面量）。
    private func b248RedirectCrashIO(_ inst: CrashContextRecorder, dir: String) {
        let d = dir as NSString
        inst.stateFileURL = URL(fileURLWithPath: d.appendingPathComponent("state.json"))
        inst.plainLogFileURL = URL(fileURLWithPath: d.appendingPathComponent("plain.log"))
        inst.structuredLogFileURL = URL(fileURLWithPath: d.appendingPathComponent("events.jsonl"))
        inst.plainCrashSnapshotURL = URL(fileURLWithPath: d.appendingPathComponent("plain-tail.log"))
        inst.structuredCrashSnapshotURL = URL(fileURLWithPath: d.appendingPathComponent("structured-tail.jsonl"))
        inst.crashSnapshotURL = URL(fileURLWithPath: d.appendingPathComponent("crash-snapshot.log"))
        inst.diagnosticReportsDirectory = URL(fileURLWithPath: d.appendingPathComponent("reports"), isDirectory: true)
        try? FileManager.default.createDirectory(at: inst.diagnosticReportsDirectory, withIntermediateDirectories: true)
    }

    private func b248RestoreCrashIO(_ inst: CrashContextRecorder,
                                    saved: (state: URL, plain: URL, structured: URL,
                                            plainSnap: URL, structuredSnap: URL,
                                            snapshot: URL, reports: URL)) {
        inst.stateFileURL = saved.state
        inst.plainLogFileURL = saved.plain
        inst.structuredLogFileURL = saved.structured
        inst.plainCrashSnapshotURL = saved.plainSnap
        inst.structuredCrashSnapshotURL = saved.structuredSnap
        inst.crashSnapshotURL = saved.snapshot
        inst.diagnosticReportsDirectory = saved.reports
    }

    func runCrashContextBootstrapTests() {
        let fm = FileManager.default
        let inst = CrashContextRecorder.shared
        let dir = "/tmp/vibefocus-cctxb248-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }

        // state 与 IO 面全程快照-还原（Runner 进程内其余测试不可见脏 state）
        inst.stateLock.lock()
        let savedState = inst.state
        inst.stateLock.unlock()
        let savedIO = (state: inst.stateFileURL, plain: inst.plainLogFileURL,
                       structured: inst.structuredLogFileURL, plainSnap: inst.plainCrashSnapshotURL,
                       structuredSnap: inst.structuredCrashSnapshotURL, snapshot: inst.crashSnapshotURL,
                       reports: inst.diagnosticReportsDirectory)
        defer {
            b248RestoreCrashIO(inst, saved: savedIO)
            inst.stateLock.lock()
            inst.state = savedState
            inst.stateLock.unlock()
        }
        b248RedirectCrashIO(inst, dir: dir)

        func seedPreviousState(cleanExit: Bool, events: [String] = [], lastReport: String? = nil) {
            let prev = CrashContextRecorder.SessionState(
                pid: 4242, launchedAt: "2026-09-19T00:00:00Z", cleanExit: cleanExit,
                events: events, lastIngestedCrashReport: lastReport)
            inst.stateLock.lock()
            inst.state = prev
            inst.stateLock.unlock()
            inst.persistState()
        }

        // ===== loadState 三态 =====
        do {
            try? fm.removeItem(atPath: inst.stateFileURL.path)
            check("b248crash: 无状态文件 loadState nil", inst.loadState() == nil)
            seedPreviousState(cleanExit: true, events: ["启动"])
            let loaded = inst.loadState()
            check("b248crash: 合法状态解码回读",
                  loaded?.pid == 4242 && loaded?.cleanExit == true && loaded?.events == ["启动"])
            try? "{\"pid\":".data(using: .utf8)?.write(to: inst.stateFileURL)
            check("b248crash: 损坏 JSON loadState nil", inst.loadState() == nil)
        }

        // ===== persistState：无 state 跳过 / 写出可回读 / 不可写路径不崩 =====
        do {
            try? fm.removeItem(atPath: inst.stateFileURL.path)
            inst.stateLock.lock()
            inst.state = nil
            inst.stateLock.unlock()
            inst.persistState()
            check("b248crash: 无 state persist 跳过不产出", !fm.fileExists(atPath: inst.stateFileURL.path))

            seedPreviousState(cleanExit: false, events: ["e1"])
            let raw = try? JSONDecoder().decode(CrashContextRecorder.SessionState.self,
                                                from: Data(contentsOf: inst.stateFileURL))
            check("b248crash: persist 落盘可回读", raw?.cleanExit == false && raw?.events == ["e1"])

            inst.stateFileURL = URL(fileURLWithPath: dir + "/no-such-sub/state.json")
            inst.persistState()   // 写失败分支：log error，不崩
            check("b248crash: 不可写路径 persist 不崩", true)
            inst.stateFileURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("state.json"))
        }

        // ===== bootstrap：无历史 → 全新 state 落盘 =====
        do {
            try? fm.removeItem(atPath: inst.stateFileURL.path)
            inst.stateLock.lock()
            inst.state = nil
            inst.stateLock.unlock()
            inst.bootstrap()
            let fresh = inst.loadState()
            check("b248crash: bootstrap 无历史落全新 state",
                  fresh != nil && fresh?.cleanExit == false && fresh?.events.isEmpty == true)
            inst.stateLock.lock()
            let memHasState = inst.state != nil
            inst.stateLock.unlock()
            check("b248crash: bootstrap 后内存 state 非空", memHasState)
        }

        // ===== bootstrap：cleanExit 历史 → 清除陈旧崩溃快照 =====
        do {
            seedPreviousState(cleanExit: true)
            try? "stale-snapshot".data(using: .utf8)?.write(to: inst.crashSnapshotURL)
            inst.bootstrap()
            check("b248crash: cleanExit 历史清除陈旧快照", !fm.fileExists(atPath: inst.crashSnapshotURL.path))

            inst.bootstrap()   // 快照已不在 → fileExists false 分支，静默通过
            check("b248crash: 无快照可清时静默通过", true)
        }

        // ===== bootstrap：非 cleanExit 历史 → 快照保存 + 500 行截尾 =====
        do {
            // pretty-printed JSON 使 state 文件展开为 >500 行，命中 suffix(500) 截尾
            let manyEvents = (0..<600).map { "e\($0)" }
            let prev = CrashContextRecorder.SessionState(
                pid: 7, launchedAt: "t", cleanExit: false, events: manyEvents, lastIngestedCrashReport: nil)
            inst.stateLock.lock()
            inst.state = prev
            inst.stateLock.unlock()
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.prettyPrinted]
            let data = (try? pretty.encode(prev)) ?? Data()
            try? data.write(to: inst.stateFileURL)

            inst.bootstrap()
            let snapshotText = try? String(contentsOf: inst.crashSnapshotURL, encoding: .utf8)
            let lineCount = snapshotText?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
            check("b248crash: 非 cleanExit 保存崩溃快照", snapshotText != nil)
            check("b248crash: 快照截尾保 500 行", lineCount == 500)
        }

        // ===== bootstrap：崩溃报告 ingest 全链（成功解析 / 解析失败 / 已 ingest） =====
        do {
            let goodPayload = #"{"captureTime":"2026-09-19T10:00:00Z","procLaunch":"2026-09-19T09:00:00Z","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS"},"termination":{"indicator":"11"},"threads":[{"triggered":true,"queue":"com.apple.main-thread","frames":[{"symbol":"vibe_focus_main"},{"symbol":"next_frame"}]},{"triggered":false,"frames":[]}]}"#

            // 成功解析：报告文本须含 "VibeFocus" 才进入 ingest（首行=ips 头，次行=载荷）
            seedPreviousState(cleanExit: false, events: ["旧事件"])
            let goodURL = inst.diagnosticReportsDirectory.appendingPathComponent("VibeFocus-b248.ips")
            try? ("VibeFocus marker\n" + goodPayload).data(using: .utf8)?.write(to: goodURL)
            inst.bootstrap()
            inst.stateLock.lock()
            let ingested = inst.state?.lastIngestedCrashReport
            let events = inst.state?.events ?? []
            inst.stateLock.unlock()
            check("b248crash: 崩溃报告 ingest 记名", ingested == "VibeFocus-b248.ips")
            check("b248crash: ingest 事件含异常与顶帧",
                  events.contains(where: { $0.contains("crash_report file=VibeFocus-b248.ips")
                      && $0.contains("exception=EXC_BAD_ACCESS") && $0.contains("frame0=vibe_focus_main") }))

            // 已 ingest 同名报告 → 跳过 ingest，走全新 state + 末事件保留
            seedPreviousState(cleanExit: false, events: ["上一条事件"], lastReport: "VibeFocus-b248.ips")
            inst.bootstrap()
            inst.stateLock.lock()
            let carried = inst.state?.events.first
            inst.stateLock.unlock()
            check("b248crash: 同名报告不重复 ingest 且保留末事件", carried?.hasSuffix("上一条事件") == true)

            // 解析失败：载荷行非 JSON → (parse_failed) 事件 + 仍记名防重扫
            seedPreviousState(cleanExit: false, events: [])
            try? "VibeFocus marker\nnot json at all".data(using: .utf8)?.write(
                to: inst.diagnosticReportsDirectory.appendingPathComponent("VibeFocus-b248bad.ips"))
            inst.bootstrap()
            inst.stateLock.lock()
            let failedName = inst.state?.lastIngestedCrashReport
            let failedEvents = inst.state?.events ?? []
            inst.stateLock.unlock()
            check("b248crash: 解析失败仍记名且落 parse_failed 事件",
                  failedName == "VibeFocus-b248bad.ips"
                  && failedEvents.contains(where: { $0.contains("(parse_failed)") }))
        }

        // ===== record：防抖单次排程 + 事件即时入内存、延后落盘 =====
        do {
            try? fm.removeItem(atPath: inst.stateFileURL.path)
            inst.stateLock.lock()
            inst.state = CrashContextRecorder.SessionState(
                pid: 9, launchedAt: "t", cleanExit: false, events: [], lastIngestedCrashReport: nil)
            inst.stateLock.unlock()
            inst.record("r1")
            inst.record("r2")   // 防抖窗内第二次：不重复排程
            Thread.sleep(forTimeInterval: 1.5)
            let persisted = inst.loadState()
            check("b248crash: record 防抖后两事件均落盘",
                  persisted?.events.count == 2 && persisted?.events.last?.hasSuffix("r2") == true)
        }

        // ===== markCleanExit：cleanExit 落账 + 双通道日志尾部快照 =====
        do {
            try? "p1\np2\np3".data(using: .utf8)?.write(to: inst.plainLogFileURL)
            try? "{\"e\":1}\n{\"e\":2}".data(using: .utf8)?.write(to: inst.structuredLogFileURL)
            inst.stateLock.lock()
            inst.state = CrashContextRecorder.SessionState(
                pid: 11, launchedAt: "t", cleanExit: false, events: [], lastIngestedCrashReport: nil)
            inst.stateLock.unlock()
            inst.markCleanExit()
            let plainTail = try? String(contentsOf: inst.plainCrashSnapshotURL, encoding: .utf8)
            let structuredTail = try? String(contentsOf: inst.structuredCrashSnapshotURL, encoding: .utf8)
            let persisted = inst.loadState()
            check("b248crash: markCleanExit 双通道尾部快照落盘",
                  plainTail == "p1\np2\np3" && structuredTail == "{\"e\":1}\n{\"e\":2}")
            check("b248crash: markCleanExit cleanExit 落账", persisted?.cleanExit == true)
        }

        // ===== latestCrashReportURL：目录缺失 / 无报告 / 最新者胜 / 前缀过滤 =====
        do {
            try? fm.removeItem(atPath: inst.diagnosticReportsDirectory.path)
            check("b248crash: 报告目录缺失 → nil", inst.latestCrashReportURL() == nil)
            try? fm.createDirectory(at: inst.diagnosticReportsDirectory, withIntermediateDirectories: true)
            check("b248crash: 空报告目录 → nil", inst.latestCrashReportURL() == nil)

            let old = inst.diagnosticReportsDirectory.appendingPathComponent("VibeFocus-old.ips")
            let new = inst.diagnosticReportsDirectory.appendingPathComponent("VibeFocus-new.ips")
            let other = inst.diagnosticReportsDirectory.appendingPathComponent("Other-app.ips")
            try? "old".data(using: .utf8)?.write(to: old)
            try? "new".data(using: .utf8)?.write(to: new)
            try? "other".data(using: .utf8)?.write(to: other)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: new.path)
            check("b248crash: 最新 mtime 者胜且他前缀被滤",
                  inst.latestCrashReportURL()?.lastPathComponent == "VibeFocus-new.ips")
        }
    }

    // MARK: - B250：capturePreviousCrashFatalDate 只读路径（fatal 文件生产进程独占写，测试只读）
    func runCrashFatalCaptureTests() {
        let inst = CrashContextRecorder.shared
        let saved = inst.previousCrashFatalAt
        defer { inst.previousCrashFatalAt = saved }

        let fatalPath = diagnosticFatalLogPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: fatalPath)
        let size = attrs?[.size] as? Int ?? 0
        inst.capturePreviousCrashFatalDate()
        if size > 0, let mtime = attrs?[.modificationDate] as? Date {
            check("crashFatal: 有致命记录时捕获 mtime",
                  inst.previousCrashFatalAt == mtime)
        } else {
            check("crashFatal: 无致命记录时保持不变",
                  inst.previousCrashFatalAt == saved)
        }
    }
}
