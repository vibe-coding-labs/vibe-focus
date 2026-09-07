// Tests/Standalone/SpaceIndexResolutionSweepTests.swift
// Verification: 零命中清扫 IV——NativeSpaceID 查找/单值或首元素解码/overlay UUID 装配
// Mirrors: Sources/Space/SpaceController+Context.swift resolveNativeSpaceID
//          Sources/Space/SpaceController+Yabai.swift staticDecodeSingleOrFirst
//          Sources/Overlay/ScreenOverlayManager+Display.swift uuidFromDisplayID / fallbackUUIDFromHash
// Run: swift Tests/Standalone/SpaceIndexResolutionSweepTests.swift
//
// 背景（2026-09-08）：四函数均为「提取待测」标注但从未入任何测试通道。
// resolveNativeSpaceID 是 SA 直切通道的空间号翻译；staticDecodeSingleOrFirst
// 是全部 yabai 查询解析的单一出口（单对象/数组首元素双形态）；UUID 两函数
// 决定 overlay 窗口的稳定身份（换显示排列不漂移的前提）。Runner 主文件
// runnersplit 拆分中，先行镜像锁定。

import CoreGraphics
import Foundation

// MARK: - Mirrors (与源码同步维护)

struct MirrorYabaiSpaceInfo: Decodable, Equatable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case id, index, display
        case isVisible = "is-visible"
    }
}

func resolveNativeSpaceID(yabaiIndex: Int, spaces: [MirrorYabaiSpaceInfo]?) -> Int64? {
    guard let spaces else { return nil }
    guard let id = spaces.first(where: { $0.index == yabaiIndex })?.id else { return nil }
    return Int64(id)
}

func staticDecodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
    let data = Data(text.utf8)
    let decoder = JSONDecoder()
    if let single = try? decoder.decode(T.self, from: data) {
        return single
    }
    if let array = try? decoder.decode([T].self, from: data) {
        return array.first
    }
    return nil
}

func uuidFromDisplayID(_ displayID: UInt32) -> UUID {
    var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    uuidBytes.0 = UInt8((displayID >> 24) & 0xFF)
    uuidBytes.1 = UInt8((displayID >> 16) & 0xFF)
    uuidBytes.2 = UInt8((displayID >> 8) & 0xFF)
    uuidBytes.3 = UInt8(displayID & 0xFF)
    return UUID(uuid: uuidBytes)
}

func fallbackUUIDFromHash(_ hashValue: Int) -> UUID {
    UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(abs(hashValue % 256))))
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Tests

// A. resolveNativeSpaceID：全局空间号 → 原生 space id（SA 直切通道翻译层）。
let spaces = [
    MirrorYabaiSpaceInfo(id: 101, index: 1, display: 1, isVisible: true),
    MirrorYabaiSpaceInfo(id: 205, index: 3, display: 2, isVisible: false),
]
check("nativeID A1: 命中 → id 转 Int64",
      resolveNativeSpaceID(yabaiIndex: 3, spaces: spaces) == 205)
check("nativeID A2: 未命中 / spaces 缺失 → nil",
      resolveNativeSpaceID(yabaiIndex: 9, spaces: spaces) == nil
      && resolveNativeSpaceID(yabaiIndex: 3, spaces: nil) == nil)

// B. staticDecodeSingleOrFirst：yabai 查询解析单一出口（单对象/数组首元素双形态）。
let singleJSON = #"{"id":101,"index":1,"display":1,"is-visible":true}"#
let arrayJSON = #"{"id":205,"index":3,"display":2,"is-visible":false}"# as String
let bothJSON = #"[{"id":205,"index":3,"display":2,"is-visible":false},{"id":206,"index":4,"display":2,"is-visible":false}]"#
check("decode B1: 单对象形态直解",
      staticDecodeSingleOrFirst(MirrorYabaiSpaceInfo.self, from: singleJSON) == MirrorYabaiSpaceInfo(id: 101, index: 1, display: 1, isVisible: true))
check("decode B2: 数组形态取首元素",
      staticDecodeSingleOrFirst(MirrorYabaiSpaceInfo.self, from: bothJSON) == MirrorYabaiSpaceInfo(id: 205, index: 3, display: 2, isVisible: false)
      && staticDecodeSingleOrFirst(MirrorYabaiSpaceInfo.self, from: arrayJSON) == MirrorYabaiSpaceInfo(id: 205, index: 3, display: 2, isVisible: false))
check("decode B3: 垃圾输入 / 空数组 → nil",
      staticDecodeSingleOrFirst(MirrorYabaiSpaceInfo.self, from: "not json") == nil
      && staticDecodeSingleOrFirst(MirrorYabaiSpaceInfo.self, from: "[]") == nil)

// C. overlay UUID 装配：确定性 + 字节布局 + 哈希回退。
check("uuid C1: displayID 大端装配进前四字节（位布局锁定）",
      uuidFromDisplayID(0x1122_3344) == UUID(uuid: (0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
check("uuid C2: 确定性 + 不同 displayID 不碰撞",
      uuidFromDisplayID(1) == uuidFromDisplayID(1)
      && uuidFromDisplayID(1) != uuidFromDisplayID(2))
check("uuid C3: 哈希回退取 abs(%256) 落末字节；负值对称；零哈希全零",
      fallbackUUIDFromHash(300) == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 44))
      && fallbackUUIDFromHash(-300) == fallbackUUIDFromHash(300)
      && fallbackUUIDFromHash(0) == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

// MARK: - Summary

print("\nSpaceIndexResolutionSweepTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
