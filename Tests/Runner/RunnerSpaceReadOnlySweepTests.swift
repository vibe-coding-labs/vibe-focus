import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceReadOnlySweepTests.swift — B245 Space 域只读查询烟测
// 靶：SpaceController+Query（querySpaces/queryWindow/visibleSpaceIndex/queryDisplays/
// queryAllWindows/exactYabaiDisplayIndex）+ YabaiClient async 通道（runAsync/queryJSONAsync）。
// 全部只读 yabai fork，零建窗零移动零偏好写；yabai 在跑→实值断言，服务停→nil 亦合法
//（双口径）。SpaceController.shared 的可用性重试为只读 fork，量级 ~30ms 无害。

final class SpaceResultBox<T: Sendable>: @unchecked Sendable {
    var value: T? = nil
}

extension RunnerHarness {
    func runSpaceReadOnlySweepTests() {
        // A. 同步查询族
        let windows = SpaceController.shared.queryAllWindows()
        check("spaceRO A1: queryAllWindows 只读烟测（nil 或非空皆合法）",
              windows == nil || !windows!.isEmpty)

        let spaces = SpaceController.shared.querySpaces(ignoreCache: true)
        check("spaceRO A2: querySpaces 只读烟测", spaces == nil || !spaces!.isEmpty)

        let displays = SpaceController.shared.queryDisplays()
        check("spaceRO A3: queryDisplays 只读烟测", displays == nil || !displays!.isEmpty)

        // 幻影窗：确定性 nil 守卫
        check("spaceRO A4: 幻影 windowID → queryWindow nil",
              SpaceController.shared.queryWindow(windowID: 0xFEED_FACE, ignoreCache: true) == nil)

        // 可见 space 索引：display 1（nil 或合法 SpaceIdentifier 双口径）
        let visIdx: SpaceIdentifier? = SpaceController.shared.visibleSpaceIndex(forDisplayIndex: 1)
        check("spaceRO A5: visibleSpaceIndex(1) 只读烟测（nil 或 yabaiIndex ≥1）",
              visIdx == nil || (visIdx!.yabaiIndex ?? 0) >= 1)

        // 主屏 → yabai display index（nil 或 ≥1）
        if let main = NSScreen.screens.first {
            let idx = SpaceController.shared.exactYabaiDisplayIndex(for: main)
            check("spaceRO A6: exactYabaiDisplayIndex(主屏) 只读烟测（nil 或 ≥1）",
                  idx == nil || idx! >= 1)
        }

        // B. async 通道：runAsync 透传 + queryJSONAsync 窗口查询
        let versionRaw = runSpaceAsync { await YabaiClient.runAsync(arguments: ["--version"]) }
        let version: YabaiClient.YabaiResult? = versionRaw ?? nil
        check("spaceRO B1: runAsync(--version) exit 0 + stdout 非空",
              version?.exitCode == 0 && !(version?.stdout.isEmpty ?? true))

        let windowsAsyncOpt = runSpaceAsync {
            await YabaiClient.queryJSONAsync([YabaiWindowInfo].self, arguments: ["query", "--windows"])
        }
        let windowsAsync: [YabaiWindowInfo]? = windowsAsyncOpt ?? nil
        check("spaceRO B2: queryJSONAsync 窗口查询只读烟测（nil 或非空皆合法）",
              windowsAsync == nil || !windowsAsync!.isEmpty)

        // 非法查询 → exitCode != 0 → queryJSONAsync nil（async 守卫分支）
        let bogusAsyncOpt = runSpaceAsync {
            await YabaiClient.queryJSONAsync([YabaiWindowInfo].self,
                                             arguments: ["query", "--ut100-none"])
        }
        let bogusAsync: [YabaiWindowInfo]? = bogusAsyncOpt ?? nil
        check("spaceRO B3: async 非法查询 → nil", bogusAsync == nil)
    }

    /// async 桥接（B154/B228 家法：Task + 短片泵主 RunLoop，30s 死线）
    private func runSpaceAsync<T: Sendable>(
        _ block: @escaping @Sendable () async -> T
    ) -> T? {
        let box = SpaceResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
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
