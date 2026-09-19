import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerGateSweepTests.swift — B242 门与粘合段扫尾
// 靶：①restoreLayout 有快照粘合段（种子未安装 bundle 快照 → 委托 executor → 守卫拒绝，
// 覆盖 controller 侧 snapshot 解析/委托行）；②HookEventHandler.handleUserPromptSubmit
// 门 0（自动恢复总开关关闭 → auto_restore_disabled 响应，registry.touch 只读早退）。
// 纪律：偏好翻转快照还原；touch 对真身 DB 仅只读查询（session 不存在必早退）。

extension RunnerHarness {
    func runGateSweepTests() {
        runRestoreLayoutSeededRefusal()
        runUPSDisabledGate()
    }

    /// MainActor 异步桥接（B154/B228 家法）
    private func runMainActorAsync<T: Sendable>(
        _ block: @escaping @MainActor () async -> T
    ) -> T? {
        let box = OverlayAsyncResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    // MARK: - restoreLayout 有快照粘合段

    private func runRestoreLayoutSeededRefusal() {
        let dir = NSTemporaryDirectory() + "ut100-gate-restore-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/g.db"))
        let controller = SessionRestoreController(store: store)

        let snapshot = SessionRestoreSnapshot(
            id: "ut100-seeded", name: "seeded",
            windows: [SessionWindowSnapshot(
                appBundleID: "com.example.nonexistent-ut100",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                displayID: 1, wasMinimized: false, panes: [])],
            launchCommand: nil, capturedAt: Date(), formatVersion: 2)
        store.upsert(snapshot)

        // 指定 ID 命中 → 委托 executor → 实例守卫拒绝（controller 侧解析/委托行覆盖）
        let byID = runMainActorAsync { await controller.restoreLayout(snapshotID: "ut100-seeded") }
        check("gate A1: restoreLayout 种子快照 → 解析命中并委托 → 守卫拒绝",
              byID?.ok == false && byID!.message.contains("未安装"))

        // 不指定 ID → store.latest() 兜底通道同样走通
        let byLatest = runMainActorAsync { await controller.restoreLayout(snapshotID: nil) }
        check("gate A2: latest 兜底 → 同一守卫拒绝", byLatest?.ok == false)
    }

    // MARK: - handleUserPromptSubmit 门 0：自动恢复总开关关闭

    private func runUPSDisabledGate() {
        let saved = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        // B242 加固：cfprefs 写回是异步的——defer 还原后必须回读自校验，
        // 否则后续测试（hookDispatch 等）会读到旧值（实测红绿交替根因）
        defer {
            ClaudeHookPreferences.autoRestoreOnPromptSubmit = saved
            for _ in 0..<5 where ClaudeHookPreferences.autoRestoreOnPromptSubmit != saved {
                ClaudeHookPreferences.autoRestoreOnPromptSubmit = saved
            }
        }
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = false

        let payload = ClaudeHookPayload(
            event: .userPromptSubmit, sessionID: "ut100-gate0", source: nil, timestamp: nil,
            cwd: "/tmp", model: nil, terminalCtx: nil,
            lastAssistantMessage: nil, transcriptPath: nil, message: nil)

        let result = runMainActorAsync {
            await HookEventHandler.shared.handleUserPromptSubmit(payload: payload)
        }
        check("gate B1: 总开关关 → auto_restore_disabled（200 + handled=false）",
              result?.statusCode == 200
              && result?.response.code == "auto_restore_disabled"
              && result?.response.handled == false)
    }
}
