import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceIdentityTests.swift — B70：Batch 42 清扫 IV 欠账清偿。
// 四函数均带「提取待测」标注却从未入任何直测通道（镜像 SpaceIndexResolutionSweepTests
// 为 runnersplit 期间先行锁定，本批转真身后退役）：
//   resolveNativeSpaceID = SA 直切通道的空间号翻译；
//   staticDecodeSingleOrFirst = 全部 yabai 查询解析的单一出口（decodeSingleOrFirst
//   实例包装委托于此）；UUID 两函数 = overlay 屏幕稳定身份（换显示排列不漂移的前提）。

extension RunnerHarness {
    func runSpaceIdentityTests() {
        // A. resolveNativeSpaceID：全局空间号 → 原生 space id。
        let spaces = [
            YabaiSpaceInfo(id: 101, index: 1, display: 1, isVisible: true),
            YabaiSpaceInfo(id: 205, index: 3, display: 2, isVisible: false),
        ]
        check("spaceIdentity: nativeID 命中 → id 转 Int64",
              SpaceController.resolveNativeSpaceID(yabaiIndex: 3, spaces: spaces) == 205)
        check("spaceIdentity: nativeID 未命中 / spaces 缺失双路 → nil",
              SpaceController.resolveNativeSpaceID(yabaiIndex: 9, spaces: spaces) == nil
              && SpaceController.resolveNativeSpaceID(yabaiIndex: 3, spaces: nil) == nil)

        // B. staticDecodeSingleOrFirst：单对象 / 数组首元素双形态。
        let single = SpaceController.staticDecodeSingleOrFirst(
            YabaiSpaceInfo.self, from: #"{"id":101,"index":1,"display":1,"is-visible":true}"#)
        check("spaceIdentity: decode 单对象形态直解",
              single == YabaiSpaceInfo(id: 101, index: 1, display: 1, isVisible: true))
        let firstOfArray = SpaceController.staticDecodeSingleOrFirst(
            YabaiSpaceInfo.self,
            from: #"[{"id":205,"index":3,"display":2,"is-visible":false},{"id":206,"index":4,"display":2,"is-visible":false}]"#)
        check("spaceIdentity: decode 数组形态取首元素",
              firstOfArray == YabaiSpaceInfo(id: 205, index: 3, display: 2, isVisible: false))
        check("spaceIdentity: decode 垃圾输入 / 空数组 → nil",
              SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "not json") == nil
              && SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "[]") == nil)
        check("spaceIdentity: decode 宽容语义——缺字段成功解码且全 nil（yabai 版本漂移防御）",
              SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "{}")
              == YabaiSpaceInfo(id: nil, index: nil, display: nil, isVisible: nil))

        // C. overlay UUID 装配：确定性 + 字节布局 + 哈希回退。
        check("spaceIdentity: uuidFromDisplayID 大端装配进前四字节（位布局锁定）",
              ScreenOverlayManager.uuidFromDisplayID(0x1122_3344)
              == UUID(uuid: (0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        check("spaceIdentity: uuidFromDisplayID 确定性 + 不同 displayID 不碰撞",
              ScreenOverlayManager.uuidFromDisplayID(1) == ScreenOverlayManager.uuidFromDisplayID(1)
              && ScreenOverlayManager.uuidFromDisplayID(1) != ScreenOverlayManager.uuidFromDisplayID(2))
        check("spaceIdentity: fallbackUUIDFromHash abs(%256) 落末字节 + 负值对称 + 零哈希全零",
              ScreenOverlayManager.fallbackUUIDFromHash(300)
              == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 44))
              && ScreenOverlayManager.fallbackUUIDFromHash(-300) == ScreenOverlayManager.fallbackUUIDFromHash(300)
              && ScreenOverlayManager.fallbackUUIDFromHash(0)
              == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    }
}
