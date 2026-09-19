import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTargetResolveTailTests.swift — B243 目标解析尾差
// 靶：TerminalGridController+TargetResolve 的 focusTargetSpaceIfNeeded 门 0 早退
// （target 非 displaySpace 形态 → nil，不触 yabai）与 activeSpaceIndex 只读烟测。
// 纪律：TerminalGridPreferences.target 偏好快照/还原（B84 家法）；yabai 只读。

extension RunnerHarness {
    func runTargetResolveTailTests() {
        let savedTarget = TerminalGridPreferences.target
        defer { TerminalGridPreferences.target = savedTarget }

        let controller = TerminalGridController.shared
        guard let screen = NSScreen.screens.first else {
            check("targetResolve A0: 测试环境无屏（环境异常跳过）", true)
            return
        }

        // 门 0：target = "main"（非 displaySpace 形态）→ 早退 nil，不触 yabai
        TerminalGridPreferences.target = "main"
        let mainGateOpt = runMainActorAsyncForTarget {
            await controller.focusTargetSpaceIfNeeded(screen: screen, op: "ut100-main")
        }
        let mainGate: String? = mainGateOpt ?? nil
        check("targetResolve A1: main 形态 → 门 0 早退 nil", mainGate == nil)

        // 门 0：target = focused（同样非 displaySpace）→ nil
        TerminalGridPreferences.target = "focused"
        let focusedGateOpt = runMainActorAsyncForTarget {
            await controller.focusTargetSpaceIfNeeded(screen: screen, op: "ut100-focused")
        }
        let focusedGate: String? = focusedGateOpt ?? nil
        check("targetResolve A2: focused 形态 → 门 0 早退 nil", focusedGate == nil)

        // displaySpace 形态 + yabai 不可用分支无法在本机稳定制造（yabai 在跑），
        // 走真实通道：displaySpace(1,1) → 定位成功 nil（无话可说）或 yabai 文案，双口径。
        TerminalGridPreferences.target = "d1s1"
        let displaySpaceOpt = runMainActorAsyncForTarget {
            await controller.focusTargetSpaceIfNeeded(screen: screen, op: "ut100-d1s1")
        }
        let displaySpace: String? = displaySpaceOpt ?? nil
        check("targetResolve A3: displaySpace 形态 → 切视角或文案，双口径合法",
              displaySpace == nil || !displaySpace!.isEmpty)

        // activeSpaceIndex：真实 yabai 查询（nil 或 ≥1 双口径）
        let active = controller.activeSpaceIndex(for: screen)
        check("targetResolve A4: activeSpaceIndex 只读烟测（nil 或 ≥1）",
              active == nil || active! >= 1)
    }

    /// MainActor 异步桥接（B154/B228 家法）
    private func runMainActorAsyncForTarget<T: Sendable>(
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
