// Tests/Standalone/YabaiModelTests.swift
// Verification: YabaiSpaceInfo, YabaiWindowInfo, YabaiDisplayInfo, decodeSingleOrFirst,
//               decodeArray, formatErrorMessage
// Mirrors: Sources/Space/SpaceController+Types.swift（Yabai 数据类型 + decodeFlexibleBool）
//          及 Sources/Space/SpaceController.swift 的查询辅助函数
// Run: swift Tests/Standalone/YabaiModelTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored types

struct YabaiSpaceInfo: Decodable, Equatable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?
    enum CodingKeys: String, CodingKey {
        case id, index, display
        case isVisible = "is-visible"
    }
}

/// yabai 各版本布尔字段类型漂移防御（与 Sources/Space/SpaceController+Types.swift 同步维护）：
/// 同一字段既有 Bool 也有 Int(0/1) 两种形态；严格 Decodable 遇 `is-visible: 1` 会整体
/// 解码失败 → querySpaces 返回 nil → toggle/restore 核心路径全瘫。
func decodeFlexibleBool<K: CodingKey>(_ key: K, from c: KeyedDecodingContainer<K>) -> Bool? {
    guard c.contains(key) else { return nil }
    if let b = try? c.decode(Bool.self, forKey: key) { return b }
    if let i = try? c.decode(Int.self, forKey: key) { return i != 0 }
    return nil
}

struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
    let frame: Frame?
    let isFloatingRaw: Bool?
    let hasAXReferenceRaw: Bool?
    let isMinimizedRaw: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, space, display, frame
        case isFloatingRaw = "is-floating"
        case hasAXReferenceRaw = "has-ax-reference"
        // yabai v7.1.18 实测字段名为 is-minimized；旧版为 minimized，双键收做版本漂移防御。
        case isMinimizedRaw = "is-minimized"
        case isMinimizedLegacyRaw = "minimized"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        space = try? c.decodeIfPresent(Int.self, forKey: .space)
        display = try? c.decodeIfPresent(Int.self, forKey: .display)
        frame = try? c.decodeIfPresent(Frame.self, forKey: .frame)
        isFloatingRaw = decodeFlexibleBool(.isFloatingRaw, from: c)
        hasAXReferenceRaw = decodeFlexibleBool(.hasAXReferenceRaw, from: c)
        isMinimizedRaw = decodeFlexibleBool(.isMinimizedRaw, from: c) ?? decodeFlexibleBool(.isMinimizedLegacyRaw, from: c)
    }

    var isFloating: Bool { isFloatingRaw == true }
    var isMinimized: Bool { isMinimizedRaw == true }
    var isManageableByYabai: Bool { hasAXReferenceRaw == true }

    struct Frame: Decodable, Equatable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }
}

struct YabaiDisplayInfo: Decodable, Equatable {
    let index: Int?
    let frame: Frame?
    struct Frame: Decodable, Equatable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
}

func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
    let data = Data(text.utf8)
    if let single = try? JSONDecoder().decode(T.self, from: data) { return single }
    if let array = try? JSONDecoder().decode([T].self, from: data) { return array.first }
    return nil
}

func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
    let data = Data(text.utf8)
    return try? JSONDecoder().decode([T].self, from: data)
}

func formatErrorMessage(stdout: String, stderr: String) -> String {
    let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedStderr.isEmpty { return trimmedStderr }
    if !trimmedStdout.isEmpty { return trimmedStdout }
    return "yabai returned empty error output"
}

struct ScriptWindowSnapshot: Codable, Equatable {
    let windowID: UInt32?
    let appName: String
    let title: String?
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - YabaiSpaceInfo

print("1. YabaiSpaceInfo — full decode")
do {
    let json = """
    {"id":123,"index":1,"display":1,"is-visible":true}
    """
    let data = json.data(using: .utf8)!
    let space = try! JSONDecoder().decode(YabaiSpaceInfo.self, from: data)
    checkEqual("id", space.id, 123)
    checkEqual("index", space.index, 1)
    checkEqual("display", space.display, 1)
    checkEqual("isVisible", space.isVisible, true)
}

print("\n2. YabaiSpaceInfo — all optionals nil")
do {
    let json = "{}"
    let data = json.data(using: .utf8)!
    let space = try! JSONDecoder().decode(YabaiSpaceInfo.self, from: data)
    check("id nil", space.id == nil)
    check("index nil", space.index == nil)
    check("isVisible nil", space.isVisible == nil)
}

print("\n3. YabaiSpaceInfo — snake_case key mapping")
do {
    let json = """
    {"is-visible": false}
    """
    let data = json.data(using: .utf8)!
    let space = try! JSONDecoder().decode(YabaiSpaceInfo.self, from: data)
    checkEqual("isVisible from is-visible key", space.isVisible, false)
}

// MARK: - YabaiWindowInfo

print("\n4. YabaiWindowInfo — full decode")
do {
    let json = """
    {"id":42,"pid":1234,"app":"Terminal","title":"bash","space":2,"display":1,"frame":{"x":0.0,"y":0.0,"w":800.0,"h":600.0},"is-floating":true}
    """
    let data = json.data(using: .utf8)!
    let win = try! JSONDecoder().decode(YabaiWindowInfo.self, from: data)
    checkEqual("id", win.id, 42)
    checkEqual("pid", win.pid, 1234)
    checkEqual("app", win.app, "Terminal")
    checkEqual("title", win.title, "bash")
    checkEqual("space", win.space, 2)
    checkEqual("display", win.display, 1)
    checkEqual("frame.x", win.frame!.x, 0.0)
    checkEqual("frame.w", win.frame!.w, 800.0)
    check("isFloating", win.isFloating)
}

print("\n5. YabaiWindowInfo — is-floating false and nil")
do {
    let jsonFalse = """
    {"is-floating": false}
    """
    let winFalse = try! JSONDecoder().decode(YabaiWindowInfo.self, from: jsonFalse.data(using: .utf8)!)
    check("is-floating=false → isFloating=false", !winFalse.isFloating)

    let jsonNil = """
    {}
    """
    let winNil = try! JSONDecoder().decode(YabaiWindowInfo.self, from: jsonNil.data(using: .utf8)!)
    check("missing is-floating → isFloating=false", !winNil.isFloating)
}

print("\n5b. YabaiWindowInfo — is-minimized 双键解码（v7 is-minimized + 旧版 minimized，P0-2）")
do {
    func decodeMin(_ json: String) -> Bool {
        (try? JSONDecoder().decode(YabaiWindowInfo.self, from: json.data(using: .utf8)!))?.isMinimized ?? false
    }
    check("v7 is-minimized bool true → 最小化", decodeMin(#"{"is-minimized": true}"#))
    check("v7 is-minimized int 1 → 最小化（int 形态）", decodeMin(#"{"is-minimized": 1}"#))
    check("v7 is-minimized int 0 → 未最小化", !decodeMin(#"{"is-minimized": 0}"#))
    check("旧版 minimized bool true → 最小化（版本漂移兜底）", decodeMin(#"{"minimized": true}"#))
    check("旧版 minimized int 1 → 最小化", decodeMin(#"{"minimized": 1}"#))
    check("双键并存 v7 优先（is-minimized=false 压过 minimized=true）",
          !decodeMin(#"{"is-minimized": false, "minimized": true}"#))
    check("字段缺失按未最小化（旧版 yabai 容错）", !decodeMin("{}"))
    check("非法值（字符串）按未最小化且不炸整体解码", !decodeMin(#"{"is-minimized": "yes"}"#))
}

print("\n5c. YabaiWindowInfo — has-ax-reference 与 isManageableByYabai")
do {
    func decodeAX(_ json: String) -> Bool {
        (try? JSONDecoder().decode(YabaiWindowInfo.self, from: json.data(using: .utf8)!))?.isManageableByYabai ?? false
    }
    check("has-ax-reference true → 可管理", decodeAX(#"{"has-ax-reference": true}"#))
    check("has-ax-reference int 1 → 可管理（int 形态）", decodeAX(#"{"has-ax-reference": 1}"#))
    check("has-ax-reference int 0 → 不可管理", !decodeAX(#"{"has-ax-reference": 0}"#))
    check("has-ax-reference 缺失 → 不可管理", !decodeAX("{}"))
}

print("\n5d. YabaiWindowInfo — is-floating int 形态（flexible bool 回归：合成 Decodable 遇 int 整体解码失败）")
do {
    let win = try! JSONDecoder().decode(YabaiWindowInfo.self, from: #"{"is-floating": 1}"#.data(using: .utf8)!)
    check("is-floating int 1 → isFloating=true", win.isFloating)
}

print("\n6. YabaiWindowInfo.Frame — cgRect conversion")
do {
    let frame = YabaiWindowInfo.Frame(x: 100, y: 200, w: 800, h: 600)
    let cg = frame.cgRect
    checkEqual("cgRect.origin.x", cg.origin.x, 100.0)
    checkEqual("cgRect.origin.y", cg.origin.y, 200.0)
    checkEqual("cgRect.width", cg.size.width, 800.0)
    checkEqual("cgRect.height", cg.size.height, 600.0)
}

// MARK: - YabaiDisplayInfo

print("\n7. YabaiDisplayInfo — full decode")
do {
    let json = """
    {"index":1,"frame":{"x":0.0,"y":0.0,"w":1920.0,"h":1117.0}}
    """
    let data = json.data(using: .utf8)!
    let display = try! JSONDecoder().decode(YabaiDisplayInfo.self, from: data)
    checkEqual("index", display.index, 1)
    checkEqual("frame.x", display.frame!.x, 0.0)
    checkEqual("frame.w", display.frame!.w, 1920.0)
}

print("\n8. YabaiDisplayInfo — secondary display with negative Y")
do {
    let json = """
    {"index":2,"frame":{"x":0.0,"y":-1440.0,"w":2560.0,"h":1440.0}}
    """
    let data = json.data(using: .utf8)!
    let display = try! JSONDecoder().decode(YabaiDisplayInfo.self, from: data)
    checkEqual("secondary Y", display.frame!.y, -1440.0)
    checkEqual("secondary w", display.frame!.w, 2560.0)
}

// MARK: - decodeSingleOrFirst

print("\n9. decodeSingleOrFirst — single object")
do {
    let text = """
    {"id":1,"index":1,"display":1,"is-visible":true}
    """
    let result = decodeSingleOrFirst(YabaiSpaceInfo.self, from: text)
    check("single object decoded", result != nil)
    checkEqual("single index", result?.index, 1)
}

print("\n10. decodeSingleOrFirst — array returns first element")
do {
    let text = """
    [{"id":1,"index":1},{"id":2,"index":2}]
    """
    let result = decodeSingleOrFirst(YabaiSpaceInfo.self, from: text)
    check("array → first element", result != nil)
    checkEqual("first element id", result?.id, 1)
}

print("\n11. decodeSingleOrFirst — invalid JSON returns nil")
do {
    check("invalid → nil", decodeSingleOrFirst(YabaiSpaceInfo.self, from: "not json") == nil)
    check("empty → nil", decodeSingleOrFirst(YabaiSpaceInfo.self, from: "") == nil)
}

print("\n12. decodeSingleOrFirst — empty array returns nil")
do {
    check("empty array → nil", decodeSingleOrFirst(YabaiSpaceInfo.self, from: "[]") == nil)
}

// MARK: - decodeArray

print("\n13. decodeArray — multiple elements")
do {
    let text = """
    [{"id":1},{"id":2},{"id":3}]
    """
    let result = decodeArray(YabaiSpaceInfo.self, from: text)
    check("3 elements", result?.count == 3)
    checkEqual("first id", result?.first?.id, 1)
    checkEqual("last id", result?.last?.id, 3)
}

print("\n14. decodeArray — single object fails (expects array)")
do {
    let text = """
    {"id":1}
    """
    check("single object → nil", decodeArray(YabaiSpaceInfo.self, from: text) == nil)
}

print("\n15. decodeArray — empty array")
do {
    let result = decodeArray(YabaiSpaceInfo.self, from: "[]")
    check("empty array → empty array", result?.isEmpty == true)
}

// MARK: - formatErrorMessage

print("\n16. formatErrorMessage — stderr takes priority")
do {
    checkEqual("stderr present", formatErrorMessage(stdout: "ok output", stderr: "error msg"), "error msg")
}

print("\n17. formatErrorMessage — stdout fallback when stderr empty")
do {
    checkEqual("stderr empty, stdout present", formatErrorMessage(stdout: "some output", stderr: ""), "some output")
}

print("\n18. formatErrorMessage — both empty → default message")
do {
    checkEqual("both empty", formatErrorMessage(stdout: "", stderr: ""), "yabai returned empty error output")
    checkEqual("whitespace only", formatErrorMessage(stdout: "  ", stderr: "  "), "yabai returned empty error output")
}

print("\n19. formatErrorMessage — whitespace trimmed")
do {
    checkEqual("stderr trimmed", formatErrorMessage(stdout: "", stderr: "  actual error  "), "actual error")
}

// MARK: - ScriptWindowSnapshot

print("\n20. ScriptWindowSnapshot — Codable roundtrip")
do {
    let snapshot = ScriptWindowSnapshot(windowID: 42, appName: "Terminal", title: "bash", x: 100, y: 200, width: 800, height: 600)
    let encoded = try! JSONEncoder().encode(snapshot)
    let decoded = try! JSONDecoder().decode(ScriptWindowSnapshot.self, from: encoded)
    checkEqual("windowID", decoded.windowID, UInt32(42))
    checkEqual("appName", decoded.appName, "Terminal")
    checkEqual("title", decoded.title, "bash")
    checkEqual("x", decoded.x, 100.0)
    checkEqual("y", decoded.y, 200.0)
    checkEqual("width", decoded.width, 800.0)
    checkEqual("height", decoded.height, 600.0)
}

print("\n21. ScriptWindowSnapshot — frame computed property")
do {
    let snapshot = ScriptWindowSnapshot(windowID: nil, appName: "App", title: nil, x: 50, y: 75, width: 640, height: 480)
    let frame = snapshot.frame
    checkEqual("frame.origin.x", frame.origin.x, 50.0)
    checkEqual("frame.origin.y", frame.origin.y, 75.0)
    checkEqual("frame.width", frame.size.width, 640.0)
    checkEqual("frame.height", frame.size.height, 480.0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
