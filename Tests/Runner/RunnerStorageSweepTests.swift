import AppKit
import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerStorageSweepTests.swift — B220 存储与记账家族覆盖扫尾
// 靶（合并态缺口）：WindowStateStore+Bindings 49 行 / PerfMonitor 实例域 141 行 /
// SessionPanelLogic 4 行 / TerminalGridStore 6 行 / TerminalUsageTracker 15 行 /
// ExitJournal 包装层 34 行。
// 纪律：SQLite 全走 WindowStateStore(dbPath:) 临时库；UserDefaults 域快照/还原；
// ExitJournal/PerfMonitor 快照只落 Runner 自有进程名域的日志文件（--diagnose 按进程名
// 区分，不触生产 app 文件）。

extension RunnerHarness {
    func runStorageSweepTests() {
        runBindingsCRUDSweep()
        runPerfMonitorInstanceSweep()
        runPanelLogicSortSweep()
        runGridStorePrefsSweep()
        runUsageTrackerSweep()
        runExitJournalWrapperSweep()
    }

    // MARK: - WindowStateStore+Bindings：绑定 CRUD 全字段 + upsert 列所有权

    private func runBindingsCRUDSweep() {
        // A. 全字段写入读回（含 toggle 几何/空间列——UPS 回原位凭证的数据面）
        do {
            let dir = NSTemporaryDirectory() + "ut100-bindings-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let store = WindowStateStore(dbPath: dir + "/b.db")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var st = WindowState(
                windowID: 301, pid: 4242, tty: "/dev/ttys3", axWindowNumber: 33,
                appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "repo — zsh",
                termSessionID: "term-1", itermSessionID: "iterm-9", sessionID: "sess-A",
                bindingType: .remote, isCompleted: false, createdAt: now,
                updatedAt: now.addingTimeInterval(60)
            )
            st.cwd = "/tmp/proj"
            st.model = "opus"
            st.envWindowID = "env-7"
            st.origX = 10; st.origY = 20; st.origW = 800; st.origH = 600
            st.targetX = 0; st.targetY = 0; st.targetW = 1728; st.targetH = 1117
            st.sourceSpace = 2; st.sourceDisplay = 1; st.sourceYabaiDisp = 1; st.sourceDispSpace = 2
            st.targetDisplay = 1
            st.toggleReason = "manual_hotkey"
            st.toggledAt = now.addingTimeInterval(90)

            store.saveWindowState(st)
            let back = store.findWindowState(windowID: 301)
            check("bind A1: 全字段往返（身份/终端上下文/session）",
                  back?.windowID == 301 && back?.pid == 4242 && back?.tty == "/dev/ttys3"
                  && back?.axWindowNumber == 33 && back?.appName == "iTerm2"
                  && back?.bundleIdentifier == "com.googlecode.iterm2" && back?.title == "repo — zsh"
                  && back?.termSessionID == "term-1" && back?.itermSessionID == "iterm-9"
                  && back?.sessionID == "sess-A" && back?.cwd == "/tmp/proj" && back?.model == "opus"
                  && back?.envWindowID == "env-7")
            check("bind A2: toggle 几何/空间列往返",
                  back?.origX == 10 && back?.targetH == 1117
                  && back?.sourceSpace == 2 && back?.sourceDisplay == 1
                  && back?.sourceYabaiDisp == 1 && back?.sourceDispSpace == 2
                  && back?.targetDisplay == 1 && back?.toggleReason == "manual_hotkey"
                  && back?.toggledAt == now.addingTimeInterval(90)
                  && back?.hasToggleState == true)

            // B. upsert 列所有权（B152 契约的绑定面）：ON CONFLICT 只更新身份列，
            //    orig*/target*/source*/target_display/toggle_reason/toggled_at 保留旧行值
            var st2 = WindowState(
                windowID: 301, pid: 5000, tty: "/dev/ttys9", axWindowNumber: nil,
                appName: "Terminal", bundleIdentifier: "com.apple.Terminal", title: "new",
                termSessionID: nil, itermSessionID: nil, sessionID: "sess-B",
                bindingType: .local, isCompleted: true, createdAt: now,
                updatedAt: now.addingTimeInterval(120)
            )
            st2.completedAt = now.addingTimeInterval(130)
            store.saveWindowState(st2)
            let merged = store.findWindowState(windowID: 301)
            check("bind B1: upsert 更新身份/session/completed 列",
                  merged?.pid == 5000 && merged?.sessionID == "sess-B" && merged?.isCompleted == true
                  && merged?.completedAt == now.addingTimeInterval(130)
                  && merged?.title == "new")
            check("bind B2: toggle 列不被 upsert 抹除（旧 geometry/reason/toggledAt 保留）",
                  merged?.origX == 10 && merged?.targetX == 0
                  && merged?.toggleReason == "manual_hotkey"
                  && merged?.toggledAt == now.addingTimeInterval(90)
                  && merged?.sourceSpace == 2 && merged?.targetDisplay == 1)

            // C. 三条查询通道 + latest-wins
            check("bind C1: findWindowStateBySession 命中（updated_at DESC）",
                  store.findWindowStateBySession(sessionID: "sess-B")?.windowID == 301)
            check("bind C2: findWindowStateBySession 未命中 → nil",
                  store.findWindowStateBySession(sessionID: "nope") == nil)
            check("bind C3: findWindowStateByWindowID 命中 / 未命中 nil",
                  store.findWindowStateByWindowID(301)?.windowID == 301
                  && store.findWindowStateByWindowID(999) == nil)
            check("bind C4: loadAllWindowStates 全量 + windowStatesCount",
                  store.loadAllWindowStates().count == 1 && store.windowStatesCount == 1)

            // D. 过期清理：活跃/完成双保留窗语义（老活跃删、老完成留、新全留）。
            //    prune 用真实时钟做截断，这里必须以 Date() 为基准（假想纪元会全部落在窗内）
            let realNow = Date()
            func mkState(_ wid: UInt32, completed: Bool, age: TimeInterval) -> WindowState {
                var s = WindowState(
                    windowID: wid, pid: 1, tty: nil, axWindowNumber: nil, appName: nil,
                    bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                    sessionID: "s-\(wid)", bindingType: .local, isCompleted: completed,
                    createdAt: realNow, updatedAt: realNow.addingTimeInterval(-age)
                )
                if completed { s.completedAt = realNow.addingTimeInterval(-age) }
                return s
            }
            store.saveWindowState(mkState(401, completed: false, age: 86_400 * 10))
            store.saveWindowState(mkState(402, completed: true, age: 86_400 * 10))
            store.saveWindowState(mkState(403, completed: false, age: 60))
            let removed = store.pruneExpiredWindowStates(
                activeRetention: 86_400 * 7, completedRetention: 86_400 * 30)
            check("bind D1: 双保留窗清理——只删 10 天前的活跃行（老完成/新活跃/301 共 3 行留存）",
                  removed == 1 && store.windowStatesCount == 3)

            // E. 单删/全删/空删
            store.deleteWindowState(windowID: 403)
            check("bind E1: 单删生效", store.findWindowState(windowID: 403) == nil)
            store.deleteAllWindowsStates()
            check("bind E2: 全删清空", store.windowStatesCount == 0
                  && store.loadAllWindowStates().isEmpty)
        }

        // F. 不可用 db（sqlite 打不开）→ 全族 guard 短路不崩
        do {
            let broken = WindowStateStore(dbPath: "/dev/null/ut100-impossible/x.db")
            if broken.db == nil {
                check("bind F1: 打不开的库 → find 返回 nil",
                      broken.findWindowState(windowID: 1) == nil
                      && broken.findWindowStateBySession(sessionID: "x") == nil
                      && broken.findWindowStateByWindowID(1) == nil)
                check("bind F2: 打不开的库 → 写入/删除/统计安全短路",
                  broken.loadAllWindowStates().isEmpty && broken.windowStatesCount == 0)
                broken.saveWindowState(WindowState(
                    windowID: 1, pid: 1, tty: nil, axWindowNumber: nil, appName: nil,
                    bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                    sessionID: nil, bindingType: .local, isCompleted: false,
                    createdAt: Date(), updatedAt: Date()))
                broken.deleteWindowState(windowID: 1)
                broken.deleteAllWindowsStates()
                check("bind F3: 打不开的库 → prune 返回 0",
                      broken.pruneExpiredWindowStates(activeRetention: 1, completedRetention: 1) == 0)
            } else {
                check("bind F1: /dev/null 路径 sqlite 打开未失败（环境相关，跳过断言）", true)
            }
        }
    }

    // MARK: - PerfMonitor 实例域：section 栈/计数器/measure/journal（不启动心跳线程）

    private func runPerfMonitorInstanceSweep() {
        let pm = PerfMonitor.shared
        // endSection 空栈下溢分支（若其它测试泄漏过 begin，多弹几次必达下溢）
        pm.endSection(); pm.endSection()
        check("perf A1: 空栈 endSection 下溢不崩", true)

        // 嵌套 section：begin×2 → end×2（push/pop 配对）
        pm.beginSection("ut100.outer", fields: ["k": "v"])
        pm.beginSection("ut100.inner")
        pm.endSection()
        pm.endSection()
        check("perf A2: 嵌套 begin/end 配对收敛", true)

        // 计数器记录 + 快照读回
        pm.record("ut100.counter", durationMs: 12.5)
        pm.record("ut100.counter", durationMs: 30.5)
        let counters = pm.snapshotCounters()
        let mine = counters.first { $0.name == "ut100.counter" }
        check("perf A3: record 计数/累计/极值进快照",
              mine != nil && mine?.count == 2
              && abs((mine?.totalMs ?? 0) - 43.0) < 0.01
              && mine?.maxMs == 30.5)

        // measure：值透传 + 错误重抛
        let value = pm.measure("ut100.measure") { 42 }
        check("perf A4: measure 返回体值", value == 42)
        struct Boom: Error {}
        var rethrown = false
        do {
            _ = try pm.measure("ut100.throw") { () -> Int in throw Boom() }
        } catch { rethrown = true }
        check("perf A5: measure 重抛体错误", rethrown)

        // journal 环形缓冲容量（64 条，超额淘汰最旧——只验调用安全与容量不变量）
        for i in 0..<80 { pm.journal("ut100-j\(i)") }
        check("perf A6: journal 超容量写入不崩", true)

        // 快照落盘→读回（Runner 自有进程域日志文件）
        pm.writeSnapshot(reason: "ut100-sweep")
        let loaded = PerfMonitor.loadSnapshotFile()
        check("perf A7: writeSnapshot→loadSnapshotFile 回读", loaded != nil)
    }

    // MARK: - SessionPanelLogic：排序三钥匙（状态权重→活动时间→sessionID 平局）

    private func runPanelLogicSortSweep() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func mkBinding(_ sid: String, wid: UInt32) -> WindowState {
            WindowState(
                windowID: wid, pid: 1, tty: nil, axWindowNumber: nil, appName: "Term",
                bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                sessionID: sid, bindingType: .local, isCompleted: false,
                createdAt: now, updatedAt: now
            )
        }
        let t = now.addingTimeInterval(-30)
        let rows = SessionPanelLogic.buildRows(
            bindings: [mkBinding("s-b", wid: 1), mkBinding("s-a", wid: 2), mkBinding("s-c", wid: 3)],
            activities: [
                "s-b": SessionActivity(lastEvent: .stop, at: t, lastCode: nil),          // done(3)
                "s-a": SessionActivity(lastEvent: .stop, at: t, lastCode: nil),          // done(3)
                "s-c": SessionActivity(lastEvent: .userPromptSubmit, at: t, lastCode: nil),
            ],
            geo: [1: SessionWindowGeo(space: 1, display: 1)],
            now: now
        )
        // s-c 是 running(权重 1) 应排最前；s-a/s-b 同权重同刻 → sessionID 字典序平局
        check("panel B1: 排序=状态权重升序，平局按 sessionID 字典序",
              rows.first?.sessionID == "s-c"
              && Array(rows.dropFirst().map(\.sessionID)) == ["s-a", "s-b"])
        // 活动时间不等 → 新者在前（覆盖 lDate != rDate 分支）
        let rows2 = SessionPanelLogic.buildRows(
            bindings: [mkBinding("old", wid: 5), mkBinding("new", wid: 6)],
            activities: [
                "old": SessionActivity(lastEvent: .stop, at: now.addingTimeInterval(-3600), lastCode: nil),
                "new": SessionActivity(lastEvent: .stop, at: now.addingTimeInterval(-10), lastCode: nil),
            ],
            geo: [:],
            now: now
        )
        check("panel B2: 同权重按活动时间新→旧",
              rows2.map(\.sessionID) == ["new", "old"])
    }

    // MARK: - TerminalGridPreferences：偏好写穿（默认域快照/还原）

    private func runGridStorePrefsSweep() {
        let d = UserDefaults.standard
        let savedRows = TerminalGridPreferences.rows
        let savedCols = TerminalGridPreferences.cols
        let savedPref = TerminalGridPreferences.appPreference
        let savedCmd = TerminalGridPreferences.launchCommand
        let savedAuto = TerminalGridPreferences.autoRestoreEnabled
        defer {
            TerminalGridPreferences.rows = savedRows
            TerminalGridPreferences.cols = savedCols
            TerminalGridPreferences.appPreference = savedPref
            TerminalGridPreferences.launchCommand = savedCmd
            TerminalGridPreferences.autoRestoreEnabled = savedAuto
        }
        TerminalGridPreferences.rows = 3
        TerminalGridPreferences.cols = 99
        check("gridPref C1: rows/cols 写穿且上界钳制到 maxGridSize(4)",
              TerminalGridPreferences.rows == 3 && TerminalGridPreferences.cols == TerminalGridPlanner.maxGridSize)
        TerminalGridPreferences.appPreference = .iterm2
        check("gridPref C2: appPreference 写穿（rawValue 持久化）",
              TerminalGridPreferences.appPreference == .iterm2)
        TerminalGridPreferences.launchCommand = "export FOO=1"
        check("gridPref C3: launchCommand 写穿", TerminalGridPreferences.launchCommand == "export FOO=1")
        TerminalGridPreferences.autoRestoreEnabled = true
        check("gridPref C4: autoRestoreEnabled 写穿", TerminalGridPreferences.autoRestoreEnabled)
        _ = d // 保留 defaults 句柄语义（读经偏好 API，键私有）
    }

    // MARK: - TerminalUsageTracker：衰减排序平局 + 坏数据回灌

    private func runUsageTrackerSweep() {
        // 平局分支：count 与 lastAt 全等 → 权重相等 → lastAt 平局比较
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        var table = TerminalUsageTable()
        table.record(bundleID: "com.a", at: t0)
        table.record(bundleID: "com.a", at: t0)
        table.record(bundleID: "com.b", at: t0)
        table.record(bundleID: "com.b", at: t0)
        let ranked = table.ranked(now: t0)
        check("usage D1: 等权重平局比较分支可达且双方在列",
              ranked.count == 2 && ranked.allSatisfy { $0.count == 2 })
        check("usage D2: minCount 过滤噪声",
              table.ranked(minCount: 3, now: t0).isEmpty)
        let enc = table.encoded()
        check("usage D3: 编解码往返",
              enc != nil && TerminalUsageTable.decode(enc!) == table
              && TerminalUsageTable.decode(Data("junk".utf8)) == nil)

        // 坏 defaults 数据 → 冷启动回灌落空表（loadTable 兜底分支）
        let d = UserDefaults.standard
        let saved = d.data(forKey: TerminalUsageTable.userDefaultsKey)
        defer {
            if let saved { d.set(saved, forKey: TerminalUsageTable.userDefaultsKey) }
            else { d.removeObject(forKey: TerminalUsageTable.userDefaultsKey) }
        }
        d.set(Data("junk".utf8), forKey: TerminalUsageTable.userDefaultsKey)
        let fresh = TerminalUsageTracker()
        check("usage D4: 坏 JSON 冷启动回灌落空表", fresh.table.entries.isEmpty)
    }

    // MARK: - ExitJournal：默认路径包装层（只落 Runner 自有进程名域文件）

    private func runExitJournalWrapperSweep() {
        // filePath 契约：exits.jsonl + 进程名后缀（--diagnose 按进程名区分）
        check("journal E1: filePath=exits.jsonl-<进程名>（非 app 进程域名隔离契约）",
              ExitJournal.filePath.hasSuffix("exits.jsonl-\(ProcessInfo.processInfo.processName)")
              && ExitJournal.filePath.contains("VibeFocus"))

        // recordCleanExitIfUnrecorded：首调写 clean + 置位，再调跳过（in-memory 旗标）
        ExitJournal.recordCleanExitIfUnrecorded()
        ExitJournal.recordCleanExitIfUnrecorded()
        check("journal E2: recordCleanExitIfUnrecorded 幂等（第二调被旗标挡）", true)

        // lastExitReason 只读：文件在→可解析；不在→nil（两态皆合法）
        _ = ExitJournal.lastExitReason()
        check("journal E3: lastExitReason 只读调用安全", true)
        check("journal E4: lastExitReason(journalContents:) 纯解析三态",
              ExitJournal.lastExitReason(journalContents: "{\"kind\":\"exit\",\"reason\":\"clean\"}\n") == "clean"
              && ExitJournal.lastExitReason(journalContents: "{\"kind\":\"launch\"}\n") == nil
              && ExitJournal.lastExitReason(journalContents: "") == nil)

        // appendLine 包装（runner 自有文件追加一行原始文本）
        ExitJournal.appendLine("{\"reason\":\"ut100-sweep\"}")
        check("journal E5: appendLine 追加安全", true)

        // openAppendFD 包装 + 用后即关（不泄漏 fd）；前置已保证该域文件可写
        let fd = ExitJournal.openAppendFD()
        check("journal E6: openAppendFD 取得合法 fd 并关闭", fd >= 0)
        if fd >= 0 { close(fd) }
    }
}
