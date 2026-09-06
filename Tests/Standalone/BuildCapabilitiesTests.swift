// Tests/Standalone/BuildCapabilitiesTests.swift
// Verification: 构建能力标记自检（detect 二进制安全搜索 / summary 稳定格式 /
// missing 缺失清单 / runtimeAXFlipLine 运行期翻转摘要行）
// Mirrors: Sources/Support/BuildCapabilities.swift + Doctor.runtimeAXFlipLine
// Run: swift Tests/Standalone/BuildCapabilitiesTests.swift

import Foundation

// MARK: - Mirrored types（与 Sources/Support/BuildCapabilities.swift 同步）

struct Marker {
    let name: String
    let needle: String
}

let all: [Marker] = [
    Marker(name: "ax-resize-channel", needle: "resize channel"),
    Marker(name: "segment-timing", needle: "segment timing"),
    Marker(name: "stall-resend", needle: "stallResendCount"),
    Marker(name: "toggle-windowless-fallback", needle: "toggle fallback: no toggleable"),
    Marker(name: "grid-space-delivery", needle: "GRID_SPACE_E2E"),
    Marker(name: "sa-verdict-state-machine", needle: "saRecoveryVerdict"),
]

func detect(in data: Data) -> [String: Bool] {
    let bytes = [UInt8](data)
    var result: [String: Bool] = [:]
    for marker in all {
        result[marker.name] = contains(bytes, needle: Array(marker.needle.utf8))
    }
    return result
}

func summary(_ result: [String: Bool]) -> String {
    all.map { "\($0.name)=\(result[$0.name] == true ? 1 : 0)" }.joined(separator: " ")
}

func missing(_ result: [String: Bool]) -> [String] {
    all.filter { result[$0.name] != true }.map { $0.name }
}

func contains(_ data: [UInt8], needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, needle.count <= data.count else { return false }
    let lastStart = data.count - needle.count
    var i = 0
    while i <= lastStart {
        if data[i] == needle[0] {
            var j = 1
            while j < needle.count, data[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

func runtimeAXFlipLine(count: Int, direction: String?, lastAt: TimeInterval) -> String? {
    guard count > 0 else { return nil }
    let dir = direction ?? "?"
    let at = lastAt > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: lastAt)) : "?"
    return "  运行期翻转 \(count) 次（最近 \(dir) @ \(at)）"
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func fixtureData(_ chunks: [String]) -> Data {
    var d = Data([0x7F, 0x45, 0x4C, 0x46]) // ELF 魔数开头，模拟真二进制
    d.append(Data(repeating: 0x00, count: 64))
    for c in chunks {
        d.append(Data([0xDE, 0xAD]))
        d.append(c.data(using: .utf8)!)
    }
    d.append(Data(repeating: 0xFF, count: 32))
    return d
}

print("1. 登记表自洽（名字唯一 / needle 非空 / needle 互不重复）")
do {
    let names = all.map { $0.name }
    let needles = all.map { $0.needle }
    check("标记名唯一", Set(names).count == names.count)
    check("needle 全部非空", needles.allSatisfy { !$0.isEmpty })
    check("needle 互不相同", Set(needles).count == needles.count)
}

print("2. 全命中（各 needle 分布在头/中/尾）")
do {
    let data = fixtureData([
        "resize channel",               // 头部附近
        "segment timing stallResendCount", // 中部两个相邻
        "toggle fallback: no toggleable window in z-order",
        "GRID_SPACE_E2E",
        "saRecoveryVerdict",            // 尾部附近
    ])
    let r = detect(in: data)
    check("六个标记全部命中", all.allSatisfy { r[$0.name] == true })
    check("summary 全 1 且顺序稳定",
          summary(r) == "ax-resize-channel=1 segment-timing=1 stall-resend=1 toggle-windowless-fallback=1 grid-space-delivery=1 sa-verdict-state-machine=1")
    check("missing 为空", missing(r).isEmpty)
}

print("3. 空数据 / 无命中")
do {
    let r = detect(in: Data())
    check("空 Data → 全 false", all.allSatisfy { r[$0.name] == false })
    check("空 Data → missing 列全量 6 项", missing(r).count == 6)
    let junk = Data(repeating: 0xAB, count: 4096)
    let rj = detect(in: junk)
    check("纯二进制噪声 → 全 false", all.allSatisfy { rj[$0.name] == false })
    check("summary 对全 false 输出全 0", summary(rj).contains("segment-timing=0"))
}

print("4. 部分命中（缺谁报谁）")
do {
    let data = fixtureData(["segment timing", "saRecoveryVerdict"])
    let r = detect(in: data)
    let m = missing(r)
    check("命中 2 个", r["segment-timing"] == true && r["sa-verdict-state-machine"] == true)
    check("missing 恰为 4 个未命中项（按登记序）",
          m == ["ax-resize-channel", "stall-resend", "toggle-windowless-fallback", "grid-space-delivery"])
}

print("5. 近似串不误报（前缀重叠 / 大小写敏感）")
do {
    let data = fixtureData([
        "resize channelX",          // 超集串：包含 needle（命中，合理）
        "SEGMENT TIMING",           // 大小写不同：不命中
        "stallResendCounts",        // 后缀延伸：包含 needle（命中）
        "grid_space_e2e",           // 下划线变体：不命中
        "sarecoveryverdict",        // 小写变体：不命中
    ])
    let r = detect(in: data)
    check("大小写不同不命中（SEGMENT TIMING）", r["segment-timing"] == false)
    check("下划线变体不命中（grid_space_e2e）", r["grid-space-delivery"] == false)
    check("小写变体不命中（sarecoveryverdict）", r["sa-verdict-state-machine"] == false)
    check("needle 的超集串命中（resize channelX）", r["ax-resize-channel"] == true)
    check("needle 的后缀延伸命中（stallResendCounts）", r["stall-resend"] == true)
}

print("6. runtimeAXFlipLine")
do {
    check("count=0 → nil（无翻转不占版面）",
          runtimeAXFlipLine(count: 0, direction: "true→false", lastAt: 1_000) == nil)
    check("count<0 → nil（防御）",
          runtimeAXFlipLine(count: -3, direction: nil, lastAt: 0) == nil)
    let line = runtimeAXFlipLine(count: 2, direction: "false→true", lastAt: 1_788_695_000)
    check("有翻转 → 行含次数与方向", line != nil && line!.contains("2 次") && line!.contains("false→true"))
    check("direction=nil → 方向占位 ?",
          runtimeAXFlipLine(count: 1, direction: nil, lastAt: 1_788_695_000)?.contains("（最近 ? @ ") == true)
    check("lastAt=0 → 时间占位 ?",
          runtimeAXFlipLine(count: 1, direction: "true→false", lastAt: 0)?.contains("@ ?") == true)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
