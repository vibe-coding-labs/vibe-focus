import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceContextTests.swift — B77：SpaceContextLogicTests 漂移镜像退役转真身直测。
// 镜像三段中 headerValue 已死（真身零定义零调用，hook 头解析已改道）不移植；
// displayLocalSpaceIndex 语义经真身静态测试缝 resolveDisplayLocalSpaceIndex 锁定
// （实例包装=日志+活查询 IO，归 E2E）；preferredSourceSpace 经 SpaceController.shared
// 直调（纯判定+日志，B74 decodeArray 同法先例）。镜像的 YabaiSpaceInfo 副本缺
// isVisible 字段属旧形状——本文件全部直测真身类型。

extension RunnerHarness {
    func runSpaceContextTests() {
        // ===== A. resolveDisplayLocalSpaceIndex：全局 space 索引 → 屏内位次（restore 上下文唯一事实源） =====
        do {
            func space(_ id: Int, _ index: Int?, _ display: Int) -> YabaiSpaceInfo {
                YabaiSpaceInfo(id: id, index: index, display: display, isVisible: nil)
            }
            check("spaceCtx: 入参任一 nil → nil（四组合）",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: nil, displayIndex: 1, spaces: [space(1, 1, 1)]) == nil
                  && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: nil, spaces: [space(1, 1, 1)]) == nil
                  && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1, spaces: nil) == nil
                  && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: nil, displayIndex: nil, spaces: nil) == nil)
            check("spaceCtx: 单屏单 space → 位次 1",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1,
                                                                spaces: [space(1, 1, 1)]) == 1)
            check("spaceCtx: 多 space 取屏内位次（全局 3 在 [1,3,5] → 2）",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 1,
                                                                spaces: [space(1, 1, 1), space(2, 3, 1), space(3, 5, 1)]) == 2)
            check("spaceCtx: 多屏按 display 过滤（space 3 在屏 2 不算屏 1 的）",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 1,
                                                                spaces: [space(1, 1, 1), space(2, 3, 2)]) == nil
                  && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 2,
                                                                   spaces: [space(1, 1, 1), space(2, 3, 2)]) == 1)
            check("spaceCtx: 全局索引不存在 → nil",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 99, displayIndex: 1,
                                                                spaces: [space(1, 1, 1)]) == nil)
            check("spaceCtx: 乱序输入按 index 升序定位（yabai 不保证有序）",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1,
                                                                spaces: [space(3, 5, 1), space(2, 3, 1), space(1, 1, 1)]) == 1)
            check("spaceCtx: nil index 沉底（Int.max）不占位次",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 5, displayIndex: 1,
                                                                spaces: [space(2, nil, 1), space(1, 5, 1)]) == 1)
            check("spaceCtx: 空 spaces 数组 → nil",
                  SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 1, spaces: []) == nil)
        }

        // ===== B. preferredSourceSpace：restore 源 space 裁决（漂移防误还原） =====
        do {
            let sc = SpaceController.shared
            check("srcSpace: window≠visible → 采 windowSpace（窗口漂移时以窗口记录为准）",
                  sc.preferredSourceSpace(windowSpace: 5, visibleSpace: 3, fallbackSpace: 1) == 5)
            check("srcSpace: window==visible → 同值透传",
                  sc.preferredSourceSpace(windowSpace: 3, visibleSpace: 3, fallbackSpace: 1) == 3)
            check("srcSpace: 仅 window / 仅 visible 单值透传",
                  sc.preferredSourceSpace(windowSpace: 4, visibleSpace: nil, fallbackSpace: 1) == 4
                  && sc.preferredSourceSpace(windowSpace: nil, visibleSpace: 2, fallbackSpace: 1) == 2)
            check("srcSpace: 全缺失 → fallback；无 fallback → nil",
                  sc.preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: 7) == 7
                  && sc.preferredSourceSpace(windowSpace: nil, visibleSpace: nil, fallbackSpace: nil) == nil)
        }
    }
}

// MARK: - B135：SpaceController+Yabai 纯工具直测（单值/首元素解码 + 错误消息格式）

extension RunnerHarness {
    func runYabaiUtilsTests() {
        struct Probe: Decodable, Equatable { let id: Int }

        // staticDecodeSingleOrFirst：单对象 / 数组首元素 / 垃圾输入 三态
        let single = SpaceController.staticDecodeSingleOrFirst(Probe.self, from: #"{"id":7}"#)
        check("yabaiUtil: 单对象 JSON 解码命中", single == Probe(id: 7))
        let array = SpaceController.staticDecodeSingleOrFirst(Probe.self, from: #"[{"id":1},{"id":2}]"#)
        check("yabaiUtil: 数组 JSON 取首元素", array == Probe(id: 1))
        check("yabaiUtil: 垃圾输入 → nil",
              SpaceController.staticDecodeSingleOrFirst(Probe.self, from: "not-json") == nil)

        // formatErrorMessage：stderr 优先 → stdout 兜底 → 双空常量
        check("yabaiFmt: stderr 非空优先",
              SpaceController.formatErrorMessage(stdout: "out", stderr: "  err  ") == "err")
        check("yabaiFmt: stderr 空退 stdout（trim）",
              SpaceController.formatErrorMessage(stdout: "\n  out \n", stderr: "") == "out")
        check("yabaiFmt: 双空 → 固定常量",
              SpaceController.formatErrorMessage(stdout: "  ", stderr: "\n")
              == "yabai returned empty error output")
    }
}

extension RunnerHarness {
    /// B235：Space 只读查询族形状断言（B 档第二批）——真机 yabai 在位时锁定
    /// 「查询→JSON 解码→缓存」管线的输出形状（space index 唯一性/窗口 id 正值/
    /// 二次查询走缓存形状稳定/焦点窗 ∈ 全量窗），yabai 不可用时 nil 亦为合法形状。
    /// 全部只读（无窗口移动/聚焦/浮动），不对桌面产生任何变更。
    func runSpaceQueryShapeTests() {
        print("\n=== SpaceQueryShape (B235) ===")
        let space = SpaceController.shared

        // --- querySpaces：解码形状 + 全局 index 唯一性 ---
        let spaces = space.querySpaces(caller: "b235")
        if let spaces {
            check("queryShape: spaces 非空时 index 全为正值",
                  spaces.allSatisfy { ($0.index ?? 0) >= 1 && ($0.display ?? 0) >= 1 })
            let indices = spaces.compactMap(\.index)
            check("queryShape: space 全局 index 唯一（yabai 契约）",
                  indices.count == Set(indices).count)
        } else {
            check("queryShape: yabai 不可用 → spaces nil 合法", true)
        }

        // --- queryFocusedWindow：命中则窗口 id 正值 ---
        let focused = space.queryFocusedWindow()
        check("queryShape: 焦点窗 nil 或 id 正值",
              focused == nil || (focused?.id ?? 0) > 0)

        // --- queryAllWindows：非空时与焦点窗对账 + 单窗回查互证 ---
        let all = space.queryAllWindows(caller: "b235")
        if let all {
            check("queryShape: 全量窗 id 全为正值", all.allSatisfy { ($0.id ?? 0) > 0 })
            if let focused, !all.isEmpty {
                check("queryShape: 焦点窗 ∈ 全量窗列表",
                      all.contains(where: { $0.id == focused.id }))
            }
            if let first = all.first, let firstID = first.id, firstID > 0,
               firstID <= Int(UInt32.max) {
                let again = space.queryWindow(windowID: UInt32(firstID))
                check("queryShape: 单窗回查命中同 id（缓存路径）",
                      again?.id == first.id)
            }
        } else {
            check("queryShape: yabai 不可用 → 全量窗 nil 合法", true)
        }

        // --- queryWindow 幽灵 id：nil 通道（真实探活失败路径） ---
        check("queryShape: 幽灵窗口 id → nil",
              space.queryWindow(windowID: 4_000_000_123) == nil)

        // --- currentSpaceIndex / visibleSpaceIndex：nil 或正值形状 ---
        let cur = space.currentSpaceIndex()
        check("queryShape: 当前 space nil 或 ≥1", cur == nil || cur! >= 1)
        let vis = space.visibleSpaceIndex(forDisplayIndex: nil)
        check("queryShape: visibleSpaceIndex nil 或带正值 yabaiIndex",
              vis == nil || vis?.yabaiIndex ?? 0 >= 1)

        // --- 缓存失效幂等（不炸即契约） ---
        space.invalidateDisplayMatchTable()
        check("queryShape: invalidateDisplayMatchTable 幂等不崩", true)
    }
}

extension RunnerHarness {
    /// B237：Space 只读查询续批——queryWindowsOnSpace 形状（真实 space 有窗数组/
    /// 幽灵 space 双探 nil=重试路径）、nativeSpaceID 实例包装（真实 index 回译非 nil/
    /// 幽灵 index nil）。全部只读零桌面变更；yabai 不可用 nil 合法。
    func runSpaceSwitchQueryShapeTests() {
        print("\n=== SpaceSwitchQueryShape (B237) ===")
        let space = SpaceController.shared
        let spaces = space.querySpaces(caller: "b237")

        // --- 幽灵 space：两次查询全 nil（首次失败→重试一次→仍 nil 的路径） ---
        check("switchQuery: 幽灵 space 双探 nil",
              space.queryWindowsOnSpace(999_999, operationID: "b237") == nil)

        // --- 真实 space：形状 + 域一致性 ---
        if let spaces, let first = spaces.first, let idx = first.index {
            let windows = space.queryWindowsOnSpace(idx, operationID: "b237")
            check("switchQuery: 真实 space 查询 nil 或全正值 id 数组",
                  windows == nil || (windows?.allSatisfy { ($0.id ?? 0) > 0 }) == true)
            let native = space.nativeSpaceID(forYabaiIndex: idx)
            check("switchQuery: 真实 yabaiIndex → 原生 space id 非 nil",
                  native == nil || native! > 0)
            check("switchQuery: 幽灵 yabaiIndex → 原生 id nil",
                  space.nativeSpaceID(forYabaiIndex: 999_999) == nil)
        } else {
            check("switchQuery: yabai 不可用 → nil 形状合法", true)
        }
    }
}
