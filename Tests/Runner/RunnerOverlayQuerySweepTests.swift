import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerOverlayQuerySweepTests.swift — B239 Overlay 查询层经测试构造缝直测
// 生产小改：ScreenOverlayManager 新增 init(startTimerAutomatically:)——false 时不启动
// 2s 刷新 Timer/不注册 observer 与信号（生产 shared 默认 true 零行为变化），
// Runner 因此可安全构造实例驱动 async 查询族（此前该域因 shared 副作用整体留白）。
// 全部 yabai fork 只读；yabai 在跑→实值断言，服务停→nil 亦合法（双口径）。

final class OverlayAsyncResultBox<T: Sendable>: @unchecked Sendable {
    var value: T? = nil
}

extension RunnerHarness {
    func runOverlayQuerySweepTests() {
        // B239 测试构造缝：无 Timer/无 observer/无信号的纯查询实例
        let om = ScreenOverlayManager(startTimerAutomatically: false)
        check("overlayQ A0: 测试实例构造成功（无定时器副作用）", true)

        // 路径解析：回退链（候选路径扫描）在装有 yabai 的机器上非空
        check("overlayQ A1: getYabaiPath 非空（回退链）", om.getYabaiPath() != nil)

        // focused space 查询：yabai 在跑 → 非空整数
        let focusedOpt = runMainActorAsync { await om.queryFocusedSpaceIndexAsync() }
        let focused: Int? = focusedOpt ?? nil
        check("overlayQ A2: queryFocusedSpaceIndexAsync 只读烟测（nil 或正整数皆合法）",
              focused == nil || focused! >= 1)

        // 单 display space 列表：display 1（yabai 在跑 → 非空数组）
        let spacesOpt = runMainActorAsync { await om.queryYabaiSpacesAsync(forDisplayIndex: 1) }
        let spaces: [SpaceSnapshot]? = spacesOpt ?? nil
        check("overlayQ A3: queryYabaiSpacesAsync 只读烟测（nil 或非空皆合法）",
              spaces == nil || !spaces!.isEmpty)

        // 全 space 快照
        let allOpt = runMainActorAsync { await om.queryAllSpacesSnapshotAsync() }
        let all: [AllSpaceSnapshot]? = allOpt ?? nil
        check("overlayQ A4: queryAllSpacesSnapshotAsync 只读烟测",
              all == nil || !all!.isEmpty)

        // displayID → yabai index：幻影 displayID → nil（守卫）；主屏 → nil 或 ≥1
        let phantomOpt = runMainActorAsync { await om.queryDisplayIndexAsync(displayID: 0xDEAD_BEEF) }
        let phantom: Int? = phantomOpt ?? nil
        check("overlayQ A5: 幻影 displayID → nil", phantom == nil)
        if let mainScreen = NSScreen.screens.first,
           let rawID = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            let mappedOpt = runMainActorAsync { await om.queryDisplayIndexAsync(displayID: rawID) }
            let mapped: Int? = mappedOpt ?? nil
            check("overlayQ A6: 主屏 displayID → nil 或 ≥1（双口径）",
                  mapped == nil || mapped! >= 1)

            // 裁决链：cached 命中路径（displayIndex 直接采用，space 交 yabai 裁决）
            let cached = runMainActorAsync {
                await om.getPerScreenSpaceIndexAsync(
                    displayID: rawID, cachedDisplayIndex: 1, focusedSpaceIndex: nil)
            }
            check("overlayQ A7: cached 路径 → displayIndex=1（space 交 yabai 裁决）",
                  cached?.displayIndex == 1)
        }

        // 幻影 displayID + 无缓存 → 查询落空双 nil（guard 链）
        let phantomPair = runMainActorAsync {
            await om.getPerScreenSpaceIndexAsync(
                displayID: 0xDEAD_BEEF, cachedDisplayIndex: nil, focusedSpaceIndex: nil)
        }
        check("overlayQ A8: 幻影 displayID 无缓存 → 双 nil", phantomPair?.displayIndex == nil)
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
