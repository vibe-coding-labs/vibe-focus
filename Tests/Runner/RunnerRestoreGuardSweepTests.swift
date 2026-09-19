import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRestoreGuardSweepTests.swift — B241 恢复守卫链扫尾
// 靶：SessionRestoreExecutor.restore 实例环境守卫早退（未安装 bundle → 拒绝，零建窗）/
// restoreLayout 空库分支 / runAutoRestoreIfEnabled 禁用短路。
// 纪律：restore 全链只走到实例守卫即被拒——不会创建任何终端窗口、不发 AppleEvents。

extension RunnerHarness {
    func runRestoreGuardSweepTests() {
        let dir = NSTemporaryDirectory() + "ut100-restoreguard-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/g.db"))
        let controller = SessionRestoreController(store: store)
        let executor = SessionRestoreExecutor(controller: controller)

        // A. Executor 实例环境守卫：未安装 bundle → 拒绝（冷拉起/建窗之前）
        let unknownSnapshot = SessionRestoreSnapshot(
            id: "ut100-unknown", name: "n",
            windows: [SessionWindowSnapshot(
                appBundleID: "com.example.nonexistent-ut100",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                displayID: 1, wasMinimized: false, panes: [])],
            launchCommand: nil, capturedAt: Date(), formatVersion: 2)
        let refused = runMainActorAsync { await executor.restore(snapshot: unknownSnapshot) }
        check("restoreGuard A1: 未安装终端 bundle → 实例守卫拒绝（ok=false + 未安装文案）",
              refused?.ok == false
              && refused?.message.contains("未安装") == true)

        // B. restoreLayout：空库 → 明示无可恢复
        let empty = runMainActorAsync { await controller.restoreLayout(snapshotID: nil) }
        check("restoreGuard A2: 空库 restoreLayout → ok=false 明示无快照",
              empty?.ok == false && !empty!.message.isEmpty)

        // C. restoreLayout(snapshotID:) 指定不存在 ID → ok=false
        let missing = runMainActorAsync { await controller.restoreLayout(snapshotID: "ut100-nope") }
        check("restoreGuard A3: 指定不存在快照 ID → ok=false", missing?.ok == false)

        // D. runAutoRestoreIfEnabled：自动恢复关闭（Runner 域持久值）→ 短路不置旗标
        let enabledBefore = TerminalGridPreferences.autoRestoreEnabled
        if !enabledBefore {
            controller.runAutoRestoreIfEnabled()
            check("restoreGuard A4: 自动恢复关闭 → 短路（旗标不置）",
                  !controller.hasRunAutoRestoreThisLaunch)
        } else {
            check("restoreGuard A4: 环境自动恢复已开启，跳过短路断言", true)
        }
    }

    /// MainActor 异步桥接（B154/B228 家法：Task + 短片泵主 RunLoop，30s 死线）
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
}
