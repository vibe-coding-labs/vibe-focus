// Tests/XCTest/SpaceSnapshotParsingTests.swift
// Verification: SpaceSnapshot.parse / AllSpaceSnapshot.parse / parseJSONArray —
//               yabai spaces JSON 解析纯函数（含 fixture 驱动的真实样例与防御性变体）
// Sources: Sources/Overlay/SpaceSnapshot.swift
// Fixtures: Tests/Fixtures/yabai-spaces-two-displays.json
//           Tests/Fixtures/yabai-spaces-defensive-variants.json
// Run: swift test --filter SpaceSnapshotParsingTests

import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpaceSnapshotParsing")
struct SpaceSnapshotParsingTests {

    // MARK: - Fixture 加载

    /// 从仓库根的 Tests/Fixtures/ 读取样例（#filePath 定位，不依赖 bundle resources）。
    private func loadFixture(_ name: String) throws -> Data {
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/XCTest/
            .deletingLastPathComponent()   // Tests/
            .appendingPathComponent("Fixtures")
        return try Data(contentsOf: fixtureDir.appendingPathComponent(name))
    }

    private func loadJSONArray(_ name: String) throws -> [[String: Any]] {
        let data = try loadFixture(name)
        guard let array = AllSpaceSnapshot.parseJSONArray(data) else {
            Issue.record("fixture \(name) is not a JSON object array")
            return []
        }
        return array
    }

    // MARK: - 真实样例（双 display）

    @Test("双 display 样例：AllSpaceSnapshot 全量解析条目数与归属")
    func parseAll_fromTwoDisplaysFixture() throws {
        let jsonArray = try loadJSONArray("yabai-spaces-two-displays.json")
        let parsed = AllSpaceSnapshot.parse(from: jsonArray)

        #expect(parsed.count == 5)
        let display1 = parsed.filter { $0.display == 1 }.map(\.index).sorted()
        let display2 = parsed.filter { $0.display == 2 }.map(\.index).sorted()
        #expect(display1 == [1, 2, 3])
        #expect(display2 == [4, 5])
    }

    @Test("双 display 样例：快速路径分组——display1 的 visible 是 1、display2 的 visible 是 4")
    func parseAll_visiblePerDisplay() throws {
        let jsonArray = try loadJSONArray("yabai-spaces-two-displays.json")
        let parsed = AllSpaceSnapshot.parse(from: jsonArray)

        let byDisplay = Dictionary(grouping: parsed, by: \.display)
        #expect(byDisplay[1]?.first(where: { $0.isVisible })?.index == 1)
        #expect(byDisplay[1]?.first(where: { $0.hasFocus })?.index == 1)
        #expect(byDisplay[2]?.first(where: { $0.isVisible })?.index == 4)
        // display2 的 has-focus 全为 false（主焦点在 display1 的 space 1——多屏常态：
        // 焦点屏唯一，另一屏只有 visible）
        #expect(byDisplay[2]?.first(where: { $0.hasFocus }) == nil)
    }

    @Test("双 display 样例：SpaceSnapshot.parse（单 display 过滤形态）忽略 display 字段")
    func parseSingle_fromTwoDisplaysFixture() throws {
        let jsonArray = try loadJSONArray("yabai-spaces-two-displays.json")
        let parsed = SpaceSnapshot.parse(from: jsonArray)

        // 单 display 查询形态下全部条目都收（display 字段不参与），is-visible/has-focus 保留
        #expect(parsed.count == 5)
        #expect(parsed.filter(\.isVisible).map(\.index).sorted() == [1, 4])
    }

    // MARK: - 防御性变体

    @Test("防御变体：缺 index 条目跳过、Int(0/1) 形态 is-visible/has-focus 正确解析")
    func parse_defensiveVariants() throws {
        let jsonArray = try loadJSONArray("yabai-spaces-defensive-variants.json")

        let single = SpaceSnapshot.parse(from: jsonArray)
        // 3 条输入：缺 index 跳过 → 剩 2 条；index 7 用 Int 形态（visible=1, focus=0）
        #expect(single.count == 2)
        #expect(single.first { $0.index == 7 }?.isVisible == true)
        #expect(single.first { $0.index == 7 }?.hasFocus == false)

        // AllSpaceSnapshot 额外要求 display：index 8 缺 display → 跳过
        let all = AllSpaceSnapshot.parse(from: jsonArray)
        #expect(all.map(\.index) == [7])
    }

    // MARK: - 边界

    @Test("空数组 → 返回空数组（合法稳态，非失败）")
    func parse_emptyArray() {
        #expect(SpaceSnapshot.parse(from: []).isEmpty)
        #expect(AllSpaceSnapshot.parse(from: []).isEmpty)
    }

    @Test("parseJSONArray：非法 JSON / 形状不符 → nil")
    func parseJSONArray_malformed() {
        #expect(AllSpaceSnapshot.parseJSONArray(Data("not json".utf8)) == nil)
        // 顶层是对象而非数组 → nil
        #expect(AllSpaceSnapshot.parseJSONArray(Data(#"{"index":1}"#.utf8)) == nil)
        // 数组元素是标量而非对象 → nil
        #expect(AllSpaceSnapshot.parseJSONArray(Data("[1,2,3]".utf8)) == nil)
    }

    @Test("parseJSONArray：空字符串（yabai 超时输出）→ nil")
    func parseJSONArray_emptyOutput() {
        #expect(AllSpaceSnapshot.parseJSONArray(Data()) == nil)
    }
}
