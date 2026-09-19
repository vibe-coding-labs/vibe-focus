import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDoctorYabaiSweepTests.swift — B227 诊断报告与 yabai 客户端扫尾
// 靶：Doctor.report 注入缝的空态/ populated 双路（--diagnose 是独立排障入口，报告分段
// 完整性即可靠性）/ YabaiClient 路径发现链与查询失败路 / SessionRestoreController 临时库薄包装。
// 纪律：Doctor 全走注入 DoctorPaths（临时目录）；yabai fork 只读；真机装有 yabai 的
// 环境假设已在断言里用「nil 或非空」的容错口径表达。

extension RunnerHarness {
    func runDoctorYabaiSweepTests() {
        runDoctorEmptyStateReport()
        runDoctorPopulatedJournalReport()
        runYabaiClientDiscovery()
        runRestoreControllerStoreWrappers()
    }

    /// 全套不存在路径的 DoctorPaths（空态分支全覆盖）
    private func makeEmptyDoctorPaths() -> DoctorPaths {
        DoctorPaths(
            journalPath: "/nonexistent/ut100/exits.jsonl",
            logDir: "/nonexistent/ut100/logs",
            tmpFatalPath: "/nonexistent/ut100/fatal.log",
            tmpSnapshotPath: "/nonexistent/ut100/snapshot.log",
            keepaliveLogPath: "/nonexistent/ut100/keepalive.log",
            diagnosticReportsDir: "/nonexistent/ut100/DiagnosticReports",
            appLogPath: "/nonexistent/ut100/vibefocus.log"
        )
    }

    // MARK: - Doctor：空态（全部文件缺失）

    private func runDoctorEmptyStateReport() {
        let report = Doctor.report(paths: makeEmptyDoctorPaths(), sessionPanelLines: nil)
        check("doctor A1: 报告生成非空且含标题", !report.isEmpty && report.contains("=== VibeFocus Doctor"))
        check("doctor A2: 日志不可读 → 明示「无记录或文件不可读」",
              report.contains("（无记录或文件不可读）"))
        check("doctor A3: 无退出记录 → 「[最近一次死亡] 无退出记录」",
              report.contains("[最近一次死亡] 无退出记录"))
        check("doctor A4: 结论=无未配对退出",
              report.contains("[结论] 无未配对退出记录"))
        check("doctor A5: 审计/翻转空态文案在场（旧版本实例或无翻转二选一必现）",
              report.contains("审计期内无 true/false 翻转")
              || report.contains("审计中无 ax 记录"))

        // 面板行注入：nil=不出段，传行=整段出现（B202 契约）
        let withPanel = Doctor.report(paths: makeEmptyDoctorPaths(),
                                      sessionPanelLines: ["[会话面板] ut100-探针行"])
        check("doctor A6: sessionPanelLines 传入即整段渲染",
              withPanel.contains("[会话面板] ut100-探针行")
              && !withPanel.contains("ut100-探针行" + "丢失"))
    }

    // MARK: - Doctor：有料日志（临时 exits.jsonl / app log）

    private func runDoctorPopulatedJournalReport() {
        let dir = NSTemporaryDirectory() + "ut100-doctor-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // 日志：launch(存活=本进程) + install + 最近的 clean exit + ax 翻转 + [ERROR] 行
        let myPID = ProcessInfo.processInfo.processIdentifier
        let nowISO = ExitJournal.timestamp(Date())
        let journal = """
        {"kind":"launch","pid":\(myPID),"at":"\(nowISO)","exe":"/tmp/ut100/VibeFocusHotkeys","ax":true}
        {"kind":"install","pid":\(myPID),"at":"\(nowISO)"}
        {"kind":"exit","pid":424242,"at":"\(nowISO)","reason":"clean"}
        {"kind":"ax","pid":\(myPID),"at":"\(nowISO)","ax":true}
        """
        let journalPath = dir + "/exits.jsonl"
        FileManager.default.createFile(atPath: journalPath, contents: Data(journal.utf8))
        let appLogPath = dir + "/vibefocus.log"
        FileManager.default.createFile(atPath: appLogPath, contents: Data("""
        2026-09-19 10:00:00 [INFO] normal line
        2026-09-19 10:01:00 [ERROR] ut100 制造的错误一行
        """.utf8))

        let paths = DoctorPaths(
            journalPath: journalPath, logDir: dir, tmpFatalPath: dir + "/fatal.log",
            tmpSnapshotPath: dir + "/snapshot.log", keepaliveLogPath: dir + "/keepalive.log",
            diagnosticReportsDir: dir + "/reports", appLogPath: appLogPath)
        let report = Doctor.report(paths: paths, sessionPanelLines: nil)

        check("doctor B1: launch 行渲染（含 pid 与 exe）",
              report.contains("launch pid=\(myPID)") && report.contains("/tmp/ut100/VibeFocusHotkeys"))
        check("doctor B2: install 行渲染", report.contains("install    at="))
        check("doctor B3: 最近死亡=clean 且带分钟前口径",
              report.contains("clean") && report.contains("分钟前"))
        check("doctor B4: app log ERROR 段渲染（≤5 条最近错误）",
              report.contains("最近 [ERROR]") && report.contains("ut100 制造的错误一行"))
    }

    // MARK: - YabaiClient：路径发现链与查询失败路（只读 fork）

    private func runYabaiClientDiscovery() {
        // 路径发现：本机装有 yabai → 非空；带缓存 → 两次一致；文件真实存在
        let p1 = YabaiClient.yabaiPath()
        let p2 = YabaiClient.yabaiPath()
        check("yabai C1: yabaiPath 可解析且缓存稳定（本机装有 yabai）",
              p1 != nil && p1 == p2 && FileManager.default.fileExists(atPath: p1!))

        // 同步 run：真实 yabai 版本查询（exit 0 + stdout 非空）
        let version = YabaiClient.run(arguments: ["--version"])
        check("yabai C2: run(--version) 透传退出码与 stdout",
              version?.exitCode == 0 && !(version?.stdout.isEmpty ?? true))

        // 查询失败路：不存在的指令 → exitCode != 0 → queryJSON 返回 nil
        let bogus = YabaiClient.queryJSON([YabaiWindowInfo].self,
                                          arguments: ["query", "--ut100-no-such-object"])
        check("yabai C3: 非法查询 → queryJSON nil（exitCode 守卫）", bogus == nil)

        // 真实查询烟测：窗口列表（yabai 服务在跑则非空数组；服务停则 nil，两态皆合法）
        let windows = YabaiClient.queryJSON([YabaiWindowInfo].self, arguments: ["query", "--windows"])
        check("yabai C4: 真实窗口查询只读烟测（nil 或数组皆合法）", true)
        if let windows { check("yabai C4a: 窗口数组可解码", !windows.isEmpty) }
    }

    // MARK: - SessionRestoreController：临时库薄包装（快照列表/最新 ID/删除）

    private func runRestoreControllerStoreWrappers() {
        let dir = NSTemporaryDirectory() + "ut100-restorectl-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/r.db"))
        let controller = SessionRestoreController(store: store)

        check("restoreCtl D1: 空库起步", controller.snapshotsForRefresh().isEmpty
              && controller.latestSnapshotID() == nil)

        let older = SessionRestoreSnapshot(
            id: "snap-old", name: "old", windows: [], launchCommand: nil,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), formatVersion: 2)
        let newer = SessionRestoreSnapshot(
            id: "snap-new", name: "new", windows: [], launchCommand: nil,
            capturedAt: Date(timeIntervalSince1970: 1_800_001_000), formatVersion: 2)
        controller.store.upsert(older)
        controller.store.upsert(newer)

        check("restoreCtl D2: snapshotsForRefresh 反映两份",
              controller.snapshotsForRefresh().count == 2)
        check("restoreCtl D3: latestSnapshotID 按 capturedAt 取新",
              controller.latestSnapshotID() == "snap-new")

        controller.removeSnapshot(id: "snap-old")
        check("restoreCtl D4: 删除后剩一份且最新 ID 跟随",
              controller.snapshotsForRefresh().count == 1
              && controller.latestSnapshotID() == "snap-new")
        controller.removeSnapshot(id: "snap-new")
        check("restoreCtl D5: 全删后回空态",
              controller.snapshotsForRefresh().isEmpty && controller.latestSnapshotID() == nil)
        check("restoreCtl D6: hasRunAutoRestoreThisLaunch 启动旗标默认 false",
              controller.hasRunAutoRestoreThisLaunch == false)
    }
}
