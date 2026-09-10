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
