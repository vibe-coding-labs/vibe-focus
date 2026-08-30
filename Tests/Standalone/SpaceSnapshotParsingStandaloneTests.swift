// Tests/Standalone/SpaceSnapshotParsingStandaloneTests.swift
// Verification: SpaceSnapshot.parse / AllSpaceSnapshot.parse / parseJSONArray —
//               yabai spaces JSON 解析纯函数（fixture 驱动；镜像 Sources/Overlay/SpaceSnapshot.swift）
// Mirrors: Sources/Overlay/SpaceSnapshot.swift 的两个 parse(from:) 与 parseJSONArray(_:)
// Fixtures: Tests/Fixtures/yabai-spaces-two-displays.json
//           Tests/Fixtures/yabai-spaces-defensive-variants.json
// Run: swift Tests/Standalone/SpaceSnapshotParsingStandaloneTests.swift
//
// 说明：swift test（SwiftPM + Swift Testing）在当前 CommandLineTools 6.2.3 工具链下
// 无法运行（TestingMacros-tool 链接失败 / 缺 _TestingInternals，见 docs/code-quality-playbook.md
// 台账），因此解析逻辑走 Standalone 镜像路径验证。Tests/XCTest/SpaceSnapshotParsingTests.swift
// 是同逻辑的 Swift Testing 版本，环境修复后可直接使用。

import Foundation

// MARK: - Mirrored types（与 Sources/Overlay/SpaceSnapshot.swift 保持逐字段一致）

struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool

    static func parse(from jsonArray: [[String: Any]]) -> [SpaceSnapshot] {
        jsonArray.compactMap { space in
            guard let index = space["index"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
        }
    }
}

struct AllSpaceSnapshot: Equatable {
    let index: Int
    let display: Int
    let isVisible: Bool
    let hasFocus: Bool

    static func parse(from jsonArray: [[String: Any]]) -> [AllSpaceSnapshot] {
        jsonArray.compactMap { space in
            guard let index = space["index"] as? Int,
                  let display = space["display"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return AllSpaceSnapshot(index: index, display: display, isVisible: visible, hasFocus: hasFocus)
        }
    }

    static func parseJSONArray(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}

// MARK: - Harness

var failures = 0
var checks = 0

func checkEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    } else {
        print("ok: \(label)")
    }
}

func loadJSONArray(_ name: String) -> [[String: Any]] {
    let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/Standalone/
        .deletingLastPathComponent()   // Tests/
        .appendingPathComponent("Fixtures")
    let url = fixtureDir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url),
          let array = AllSpaceSnapshot.parseJSONArray(data) else {
        fatalError("cannot load fixture \(url.path)")
    }
    return array
}

// MARK: - 双 display 真实样例

let twoDisplays = loadJSONArray("yabai-spaces-two-displays.json")

let allParsed = AllSpaceSnapshot.parse(from: twoDisplays)
checkEqual("AllSpaceSnapshot: 条目数", allParsed.count, 5)
checkEqual("AllSpaceSnapshot: display1 空间编号", allParsed.filter { $0.display == 1 }.map(\.index).sorted(), [1, 2, 3])
checkEqual("AllSpaceSnapshot: display2 空间编号", allParsed.filter { $0.display == 2 }.map(\.index).sorted(), [4, 5])

let byDisplay = Dictionary(grouping: allParsed, by: \.display)
checkEqual("快速路径: display1 visible", byDisplay[1]?.first(where: { $0.isVisible })?.index, 1)
checkEqual("快速路径: display1 focused", byDisplay[1]?.first(where: { $0.hasFocus })?.index, 1)
checkEqual("快速路径: display2 visible", byDisplay[2]?.first(where: { $0.isVisible })?.index, 4)
checkEqual("快速路径: display2 无焦点（焦点屏唯一）", byDisplay[2]?.first(where: { $0.hasFocus })?.index, nil)

let singleParsed = SpaceSnapshot.parse(from: twoDisplays)
checkEqual("SpaceSnapshot: 全条目收集（不依赖 display 字段）", singleParsed.count, 5)
checkEqual("SpaceSnapshot: visible 集合", singleParsed.filter(\.isVisible).map(\.index).sorted(), [1, 4])

// MARK: - 防御性变体

let variants = loadJSONArray("yabai-spaces-defensive-variants.json")

let singleFromVariants = SpaceSnapshot.parse(from: variants)
checkEqual("防御: 缺 index 跳过后剩余条目", singleFromVariants.count, 2)
checkEqual("防御: Int(0/1) 形态 is-visible", singleFromVariants.first { $0.index == 7 }?.isVisible, true)
checkEqual("防御: Int(0/1) 形态 has-focus", singleFromVariants.first { $0.index == 7 }?.hasFocus, false)

let allFromVariants = AllSpaceSnapshot.parse(from: variants)
checkEqual("防御: AllSpaceSnapshot 缺 display 跳过", allFromVariants.map(\.index), [7])

// MARK: - 边界

checkEqual("边界: 空数组 → 空结果（合法稳态）", SpaceSnapshot.parse(from: []).isEmpty, true)
checkEqual("边界: 非法 JSON → nil", AllSpaceSnapshot.parseJSONArray(Data("not json".utf8)) == nil, true)
checkEqual("边界: 顶层对象而非数组 → nil", AllSpaceSnapshot.parseJSONArray(Data(#"{"index":1}"#.utf8)) == nil, true)
checkEqual("边界: 元素为标量的数组 → nil", AllSpaceSnapshot.parseJSONArray(Data("[1,2,3]".utf8)) == nil, true)
checkEqual("边界: 空 Data（yabai 超时输出）→ nil", AllSpaceSnapshot.parseJSONArray(Data()) == nil, true)

// MARK: - Summary

print("")
print("checks=\(checks) failures=\(failures)")
if failures > 0 {
    exit(1)
}
print("ALL PASS")
