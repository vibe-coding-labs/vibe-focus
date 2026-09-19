// Tests/Runner/RunnerOverlaySpaceQueryTests.swift
// B220 覆盖堆叠·Overlay 空间查询域：ScreenOverlayManager+SpaceQuery（yabai fork 只读层）。
// 不碰 om.preferences——其 didSet→save() 会落持久化（SQLite 路径疑生产库，宁可不测
// 自定义路径分支）；只测系统探测路与幻影 displayID 守卫路，全部只读 fork。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runOverlaySpaceQueryTests() {
        print("\n=== OverlaySpaceQuery (B220) ===")
        let om = ScreenOverlayManager.shared

        // getYabaiPath：Runner 域无自定义路径 → 系统 PATH 探测（本机装了 yabai → 非空且存在）
        let sysPath = om.getYabaiPath()
        check("overlayQuery: 系统 yabai 探测非空", sysPath != nil)
        if let p = sysPath {
            check("overlayQuery: 探测路径真实存在", FileManager.default.fileExists(atPath: p))
        }

        // getPerScreenSpaceIndexAsync：幻影 displayID → yabai 查询落空守卫
        final class Box: @unchecked Sendable {
            var result: (displayIndex: Int?, spaceIndex: Int?)? = nil
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.result = await om.getPerScreenSpaceIndexAsync(
                displayID: 0xB220,
                cachedDisplayIndex: nil,
                focusedSpaceIndex: nil
            )
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("overlayQuery: 幻影 displayID 查询按时返回不悬挂", box.result != nil)
    }
}
