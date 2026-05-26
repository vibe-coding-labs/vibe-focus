# Unit Test Coverage Expansion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 扩展 standalone 单元测试覆盖，补全 4 个关键模块的纯逻辑测试：数据模型序列化、坐标数学、偏好编解码、QuartzRect 几何运算。

**Architecture:** 测试以 standalone Swift 脚本形式存在（`Tests/Standalone/*.swift`），每个文件镜像对应源码的纯逻辑部分（不含 AppKit 依赖），用 `print/exit` 驱动。通过 `bash Tests/run_all_tests.sh` 统一运行。

**Tech Stack:** Swift 5.9, macOS 13+, Foundation + CoreGraphics（无 XCTest 框架依赖）

**Scope:** Small
**Risk:** Low

**Risks:**
- 测试中镜像的模型代码可能与源码不同步 → 缓解：每个测试文件头部注释标注镜像源码路径和行号
- Codable roundtrip 依赖 JSONEncoder/JSONDecoder 行为 → 缓解：测试实际编码解码而非假设行为

**Autonomy Level:** Full

---

### Task 1: TerminalContext & WindowState Data Model Tests

**Depends on:** None
**Files:**
- Create: `Tests/Standalone/DataModelTests.swift`

- [ ] **Step 1: 创建 DataModelTests.swift — 测试 TerminalContext.hasUsefulContext、isRemote、WindowState.hasToggleState、originalFrame、targetFrame、isCorrupted**

测试覆盖：
- `hasUsefulContext`: 有 TTY → true，有 termSessionID → true，空对象 → false，ppid=1 → false，ppid=1234 → true
- `isRemote`: 有 machineLabel → true，无 machineLabel → false，空 machineLabel → false
- `hasToggleState`: origX+targetX 都有 → true，缺一个 → false
- `originalFrame/targetFrame`: 四个字段齐全 → 正确 CGRect，缺字段 → nil
- `isCorrupted`: orig 和 target 都在主屏 → true，orig 在副屏 → false

```swift
// Tests/Standalone/DataModelTests.swift
// Verification: TerminalContext, WindowState data model validation logic
// Mirrors: Sources/Hook/ClaudeHookModels.swift:47-117 (WindowState)
//          Sources/Hook/ClaudeHookModels.swift:157-203 (TerminalContext)
// Run: swift Tests/Standalone/DataModelTests.swift

import Foundation
import CoreGraphics

let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

// MARK: - TerminalContext (mirrors ClaudeHookModels.swift:157-203)

struct TestTerminalContext: Equatable {
    let termSessionID: String?
    let itermSessionID: String?
    let kittyWindowID: String?
    let weztermPane: String?
    let tty: String?
    let ppid: String?
    let claudeProjectDir: String?
    let windowID: String?
    let machineLabel: String?

    var hasUsefulContext: Bool {
        if let tty, !tty.isEmpty { return true }
        if let termSessionID, !termSessionID.isEmpty { return true }
        if let itermSessionID, !itermSessionID.isEmpty { return true }
        if let ppid, let pid = Int32(ppid), pid > 1 { return true }
        if let machineLabel, !machineLabel.isEmpty { return true }
        return false
    }

    var isRemote: Bool {
        guard let label = machineLabel, !label.isEmpty else { return false }
        return true
    }
}

// MARK: - WindowState (mirrors ClaudeHookModels.swift:47-118)

struct TestWindowState: Equatable {
    var origX: CGFloat?
    var origY: CGFloat?
    var origW: CGFloat?
    var origH: CGFloat?
    var targetX: CGFloat?
    var targetY: CGFloat?
    var targetW: CGFloat?
    var targetH: CGFloat?

    var hasToggleState: Bool {
        origX != nil && targetX != nil
    }

    var originalFrame: CGRect? {
        guard let x = origX, let y = origY, let w = origW, let h = origH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var targetFrame: CGRect? {
        guard let x = targetX, let y = targetY, let w = targetW, let h = targetH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func isCorrupted(mainScreenFrame: CGRect) -> Bool {
        guard let orig = originalFrame, let tgt = targetFrame else { return false }
        let origCenter = CGPoint(x: orig.midX, y: orig.midY)
        let tgtCenter = CGPoint(x: tgt.midX, y: tgt.midY)
        return mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }
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

// MARK: - TerminalContext.hasUsefulContext

print("1. TerminalContext.hasUsefulContext")
do {
    let ctx1 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: "/dev/ttys003", ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has TTY → useful", ctx1.hasUsefulContext)

    let ctx2 = TestTerminalContext(
        termSessionID: "ABC123", itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has termSessionID → useful", ctx2.hasUsefulContext)

    let ctx3 = TestTerminalContext(
        termSessionID: nil, itermSessionID: "I:session", kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has itermSessionID → useful", ctx3.hasUsefulContext)

    let ctx4 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "1234",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=1234 → useful", ctx4.hasUsefulContext)

    let ctx5 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "1",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=1 → NOT useful", !ctx5.hasUsefulContext)

    let ctx6 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: "", ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("empty TTY → NOT useful", !ctx6.hasUsefulContext)

    let ctx7 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("all nil → NOT useful", !ctx7.hasUsefulContext)

    let ctx8 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: "remote-mac"
    )
    check("has machineLabel → useful", ctx8.hasUsefulContext)

    let ctx9 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "invalid",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=invalid (non-numeric) → NOT useful", !ctx9.hasUsefulContext)
}

// MARK: - TerminalContext.isRemote

print("\n2. TerminalContext.isRemote")
do {
    let remote = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: "remote-mac"
    )
    check("has machineLabel → remote", remote.isRemote)

    let local = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("nil machineLabel → NOT remote", !local.isRemote)

    let empty = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: ""
    )
    check("empty machineLabel → NOT remote", !empty.isRemote)
}

// MARK: - WindowState.hasToggleState

print("\n3. WindowState.hasToggleState")
do {
    var ws1 = TestWindowState()
    ws1.origX = 100; ws1.targetX = 200
    check("both present → has toggle state", ws1.hasToggleState)

    var ws2 = TestWindowState()
    ws2.origX = 100; ws2.targetX = nil
    check("missing targetX → NO toggle state", !ws2.hasToggleState)

    var ws3 = TestWindowState()
    ws3.origX = nil; ws3.targetX = 200
    check("missing origX → NO toggle state", !ws3.hasToggleState)

    let ws4 = TestWindowState()
    check("all nil → NO toggle state", !ws4.hasToggleState)
}

// MARK: - WindowState.originalFrame / targetFrame

print("\n4. WindowState frame extraction")
do {
    var ws = TestWindowState()
    ws.origX = 1480; ws.origY = -710; ws.origW = 1145; ws.origH = 710
    ws.targetX = 75; ws.targetY = 38; ws.targetW = 1656; ws.targetH = 1070

    let origFrame = ws.originalFrame!
    checkEqual("origFrame.x", origFrame.origin.x, 1480.0)
    checkEqual("origFrame.y", origFrame.origin.y, -710.0)
    checkEqual("origFrame.width", origFrame.width, 1145.0)
    checkEqual("origFrame.height", origFrame.height, 710.0)

    let tgtFrame = ws.targetFrame!
    checkEqual("targetFrame.x", tgtFrame.origin.x, 75.0)
    checkEqual("targetFrame.y", tgtFrame.origin.y, 38.0)
}

print("\n5. WindowState frame extraction — missing fields")
do {
    var ws = TestWindowState()
    ws.origX = 100; ws.origY = nil; ws.origW = 500; ws.origH = 500
    check("missing origY → nil originalFrame", ws.originalFrame == nil)

    var ws2 = TestWindowState()
    ws2.targetX = 100; ws2.targetY = 200; ws2.targetW = nil; ws2.targetH = 500
    check("missing targetW → nil targetFrame", ws2.targetFrame == nil)
}

// MARK: - WindowState.isCorrupted

print("\n6. WindowState.isCorrupted")
do {
    var ws1 = TestWindowState()
    ws1.origX = 100; ws1.origY = 100; ws1.origW = 500; ws1.origH = 500
    ws1.targetX = 200; ws1.targetY = 200; ws1.targetW = 600; ws1.targetH = 600
    check("both on main screen → corrupted", ws1.isCorrupted(mainScreenFrame: mainScreenFrame))

    var ws2 = TestWindowState()
    ws2.origX = 1480; ws2.origY = -710; ws2.origW = 1145; ws2.origH = 710
    ws2.targetX = 75; ws2.targetY = 38; ws2.targetW = 1656; ws2.targetH = 1070
    check("orig off-screen → NOT corrupted", !ws2.isCorrupted(mainScreenFrame: mainScreenFrame))

    let ws3 = TestWindowState()
    check("no frames → NOT corrupted", !ws3.isCorrupted(mainScreenFrame: mainScreenFrame))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
```

- [ ] **Step 2: 验证 DataModelTests**
Run: `swift Tests/Standalone/DataModelTests.swift`
Expected:
  - Exit code: 0
  - Output contains: "passed" and does NOT contain: "FAIL"

- [ ] **Step 3: 提交**
Run: `git add Tests/Standalone/DataModelTests.swift && git commit -m "test: add DataModel tests for TerminalContext and WindowState"`

---

### Task 2: PreferenceValue Codable Roundtrip Tests

**Depends on:** None
**Files:**
- Create: `Tests/Standalone/PreferenceValueTests.swift`

- [ ] **Step 1: 创建 PreferenceValueTests.swift — 测试 PreferenceValue 编解码 roundtrip**

测试覆盖：
- `.bool(true)` / `.bool(false)` encode → decode → equal
- `.int(42)` / `.int(0)` / `.int(-1)` encode → decode → equal
- `.string("hello")` / `.string("")` / `.string("with\"quotes")` encode → decode → equal
- `.data(Data("test".utf8))` encode → decode → equal
- Unknown type "float" → decode throws error
- All four types in single dictionary encode → decode → equal

```swift
// Tests/Standalone/PreferenceValueTests.swift
// Verification: PreferenceValue Codable roundtrip
// Mirrors: Sources/Support/PreferencesSync.swift:164-211
// Run: swift Tests/Standalone/PreferenceValueTests.swift

import Foundation

// MARK: - PreferenceValue (mirrors PreferencesSync.swift:164-211)

enum PreferenceValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case data(Data)

    private enum CodingKeys: String, CodingKey { case type, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode("string", forKey: .type)
            try container.encode(v, forKey: .value)
        case .data(let v):
            try container.encode("data", forKey: .type)
            try container.encode(v.base64EncodedString(), forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "data":
            let base64 = try container.decode(String.self, forKey: .value)
            guard let d = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid base64 data")
            }
            self = .data(d)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func roundtrip(_ value: PreferenceValue) -> PreferenceValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(PreferenceValue.self, from: data)
}

// MARK: - Bool roundtrip

print("1. Bool roundtrip")
do {
    check("bool(true)", roundtrip(.bool(true)) == .bool(true))
    check("bool(false)", roundtrip(.bool(false)) == .bool(false))
}

// MARK: - Int roundtrip

print("\n2. Int roundtrip")
do {
    check("int(42)", roundtrip(.int(42)) == .int(42))
    check("int(0)", roundtrip(.int(0)) == .int(0))
    check("int(-1)", roundtrip(.int(-1)) == .int(-1))
    check("int(max)", roundtrip(.int(Int.max)) == .int(Int.max))
}

// MARK: - String roundtrip

print("\n3. String roundtrip")
do {
    check("string(hello)", roundtrip(.string("hello")) == .string("hello"))
    check("string(empty)", roundtrip(.string("")) == .string(""))
    check("string(unicode)", roundtrip(.string("日本語テスト 🎉")) == .string("日本語テスト 🎉"))
    check("string(special chars)", roundtrip(.string("a\\b\"c\nd")) == .string("a\\b\"c\nd"))
}

// MARK: - Data roundtrip

print("\n4. Data roundtrip")
do {
    let testData = Data("test data 123".utf8)
    check("data(utf8)", roundtrip(.data(testData)) == .data(testData))

    let emptyData = Data()
    check("data(empty)", roundtrip(.data(emptyData)) == .data(emptyData))

    let binaryData = Data([0x00, 0xFF, 0x80, 0x7F])
    check("data(binary)", roundtrip(.data(binaryData)) == .data(binaryData))
}

// MARK: - Dictionary roundtrip (full config scenario)

print("\n5. Full dictionary roundtrip")
do {
    let original: [String: PreferenceValue] = [
        "enabled": .bool(true),
        "port": .int(39277),
        "name": .string("VibeFocus"),
        "config": .data(Data("{\"key\":\"value\"}".utf8)),
    ]
    guard let encoded = try? JSONEncoder().encode(original),
          let decoded = try? JSONDecoder().decode([String: PreferenceValue].self, from: encoded) else {
        check("dictionary roundtrip encode/decode", false)
        print("  ERROR: failed to encode/decode dictionary")
    } else {
        check("dictionary count matches", decoded.count == original.count)
        check("dict[enabled]", decoded["enabled"] == .bool(true))
        check("dict[port]", decoded["port"] == .int(39277))
        check("dict[name]", decoded["name"] == .string("VibeFocus"))
        check("dict[config]", decoded["config"] == .data(Data("{\"key\":\"value\"}".utf8)))
    }
}

// MARK: - Unknown type rejection

print("\n6. Unknown type rejection")
do {
    let badJSON = """
    {"type": "float", "value": 3.14}
    """
    let data = badJSON.data(using: .utf8)!
    let result = try? JSONDecoder().decode(PreferenceValue.self, from: data)
    check("unknown type throws", result == nil)
}

// MARK: - Invalid base64 rejection

print("\n7. Invalid base64 rejection")
do {
    let badJSON = """
    {"type": "data", "value": "!!!not-base64!!!"}
    """
    let data = badJSON.data(using: .utf8)!
    let result = try? JSONDecoder().decode(PreferenceValue.self, from: data)
    check("invalid base64 throws", result == nil)
}

// MARK: - JSON structure verification

print("\n8. JSON structure is human-readable")
do {
    guard let encoded = try? JSONEncoder().encode(PreferenceValue.bool(true)),
          let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        check("JSON structure", false)
    } else {
        check("has type key", json["type"] as? String == "bool")
        check("has value key", json["value"] as? Bool == true)
    }
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
```

- [ ] **Step 2: 验证 PreferenceValueTests**
Run: `swift Tests/Standalone/PreferenceValueTests.swift`
Expected:
  - Exit code: 0
  - Output contains: "passed" and does NOT contain: "FAIL"

- [ ] **Step 3: 提交**
Run: `git add Tests/Standalone/PreferenceValueTests.swift && git commit -m "test: add PreferenceValue Codable roundtrip tests"`

---

### Task 3: QuartzRect Geometry & CoordinateKit Math Tests

**Depends on:** None
**Files:**
- Create: `Tests/Standalone/QuartzRectTests.swift`

- [ ] **Step 1: 创建 QuartzRectTests.swift — 测试 QuartzRect 几何运算和 CoordinateKit 静态数学函数**

测试覆盖：
- QuartzRect: init, midX/midY/maxX/maxY, centerIsInside, description, cgRect conversion
- framesMatch: exact match, within tolerance, outside tolerance, heightTolerance
- CoordinateKit.cocoaY / quartzY 转换对称性

```swift
// Tests/Standalone/QuartzRectTests.swift
// Verification: QuartzRect geometry and CoordinateKit math functions
// Mirrors: Sources/Space/CoordinateKit.swift:61-91 (QuartzRect), 156-162 (coordinate conversion), 200-207 (framesMatch)
// Run: swift Tests/Standalone/QuartzRectTests.swift

import Foundation
import CoreGraphics

// MARK: - QuartzRect (mirrors CoordinateKit.swift:61-91)

struct QuartzRect: Equatable, CustomStringConvertible {
    let origin: CGPoint
    let size: CGSize

    var x: CGFloat { origin.x }
    var y: CGFloat { origin.y }
    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var midX: CGFloat { origin.x + size.width / 2 }
    var midY: CGFloat { origin.y + size.height / 2 }
    var maxX: CGFloat { origin.x + size.width }
    var maxY: CGFloat { origin.y + size.height }

    init(_ cgRect: CGRect) {
        self.origin = cgRect.origin
        self.size = cgRect.size
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    var cgRect: CGRect { CGRect(origin: origin, size: size) }

    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }

    func centerIsInside(_ screenFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: midX, y: midY))
    }
}

// MARK: - framesMatch (mirrors CoordinateKit.swift:200-207)

func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10, heightTolerance: CGFloat? = nil) -> Bool {
    let ht = heightTolerance ?? tolerance * 2
    let positionMatches = abs(a.origin.x - b.origin.x) <= tolerance &&
                         abs(a.origin.y - b.origin.y) <= tolerance
    let sizeMatches = abs(a.width - b.width) <= tolerance * 2 &&
                     abs(a.height - b.height) <= ht
    return positionMatches && sizeMatches
}

// MARK: - Coordinate conversion (mirrors CoordinateKit.swift:156-162)

func cocoaY(fromQuartzY quartzY: CGFloat, mainScreenHeight: CGFloat) -> CGFloat {
    mainScreenHeight - quartzY
}

func quartzY(fromCocoaY cocoaY: CGFloat, mainScreenHeight: CGFloat) -> CGFloat {
    mainScreenHeight - cocoaY
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

let mainScreenHeight: CGFloat = 1117

// MARK: - QuartzRect basics

print("1. QuartzRect init and properties")
do {
    let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
    checkEqual("x", r.x, 100.0)
    checkEqual("y", r.y, 200.0)
    checkEqual("width", r.width, 800.0)
    checkEqual("height", r.height, 600.0)
    checkEqual("midX", r.midX, 500.0)
    checkEqual("midY", r.midY, 500.0)
    checkEqual("maxX", r.maxX, 900.0)
    checkEqual("maxY", r.maxY, 800.0)
}

print("\n2. QuartzRect from CGRect")
do {
    let cg = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let r = QuartzRect(cg)
    checkEqual("cgRect roundtrip", r.cgColor, cg)
    checkEqual("midX of main screen", r.midX, 864.0)
    checkEqual("midY of main screen", r.midY, 558.5)
}

print("\n3. QuartzRect description")
do {
    let r = QuartzRect(x: 1480, y: -707, width: 1146, height: 707)
    checkEqual("description", r.description, "1480,-707 1146x707")
}

// MARK: - centerIsInside

print("\n4. QuartzRect.centerIsInside")
do {
    let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    let onMain = QuartzRect(x: 500, y: 300, width: 800, height: 600)
    check("center on main screen", onMain.centerIsInside(mainScreen))

    let offScreen = QuartzRect(x: 1480, y: -710, width: 1145, height: 710)
    check("center off-screen (secondary above)", !offScreen.centerIsInside(mainScreen))

    let edgeCase = QuartzRect(x: 0, y: 0, width: 1, height: 1)
    check("1x1 at origin on main screen", edgeCase.centerIsInside(mainScreen))
}

// MARK: - framesMatch

print("\n5. framesMatch — exact match")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    check("exact match", framesMatch(a, a))
}

print("\n6. framesMatch — within tolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 105, y: 205, width: 815, height: 615)
    check("5px offset within 10px tolerance", framesMatch(a, b))
    check("reversed", framesMatch(b, a))
}

print("\n7. framesMatch — outside tolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 115, y: 200, width: 800, height: 600)
    check("15px x-offset outside 10px tolerance", !framesMatch(a, b))
}

print("\n8. framesMatch — heightTolerance")
do {
    let a = CGRect(x: 100, y: 200, width: 800, height: 600)
    let b = CGRect(x: 100, y: 200, width: 800, height: 615)
    // Default heightTolerance = tolerance * 2 = 20
    check("15px height diff within 20px heightTolerance", framesMatch(a, b))

    let c = CGRect(x: 100, y: 200, width: 800, height: 625)
    check("25px height diff outside 20px heightTolerance", !framesMatch(a, c))

    // Custom heightTolerance
    check("25px height within 30px custom heightTolerance", framesMatch(a, c, heightTolerance: 30))
}

// MARK: - Coordinate conversion symmetry

print("\n9. Coordinate conversion symmetry")
do {
    let testYValues: [CGFloat] = [0, 1117, 558.5, -720, 1500, -10000, 100000]
    for y in testYValues {
        let cocoa = cocoaY(fromQuartzY: y, mainScreenHeight: mainScreenHeight)
        let back = quartzY(fromCocoaY: cocoa, mainScreenHeight: mainScreenHeight)
        checkEqual("quartzY(\(y)) → cocoaY(\(cocoa)) → quartzY roundtrip", back, y)
    }
}

print("\n10. Coordinate conversion known values")
do {
    checkEqual("quartzY=0 → cocoaY=1117", cocoaY(fromQuartzY: 0, mainScreenHeight: mainScreenHeight), 1117.0)
    checkEqual("quartzY=1117 → cocoaY=0", cocoaY(fromQuartzY: 1117, mainScreenHeight: mainScreenHeight), 0.0)
    checkEqual("quartzY=-720 → cocoaY=1837", cocoaY(fromQuartzY: -720, mainScreenHeight: mainScreenHeight), 1837.0)
    checkEqual("cocoaY=0 → quartzY=1117", quartzY(fromCocoaY: 0, mainScreenHeight: mainScreenHeight), 1117.0)
    checkEqual("cocoaY=1117 → quartzY=0", quartzY(fromCocoaY: 1117, mainScreenHeight: mainScreenHeight), 0.0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
```

- [ ] **Step 2: 验证 QuartzRectTests**
Run: `swift Tests/Standalone/QuartzRectTests.swift`
Expected:
  - Exit code: 0
  - Output contains: "passed" and does NOT contain: "FAIL"

- [ ] **Step 3: 提交**
Run: `git add Tests/Standalone/QuartzRectTests.swift && git commit -m "test: add QuartzRect geometry and coordinate conversion tests"`

---

### Task 4: Update run_all_tests.sh and verify full suite

**Depends on:** Task 1, Task 2, Task 3
**Files:**
- Modify: `Tests/run_all_tests.sh` (no changes needed, already globs *.swift)
- Verify: All test files pass via the runner

- [ ] **Step 1: 运行全部测试验证**
Run: `bash Tests/run_all_tests.sh`
Expected:
  - Exit code: 0
  - Output contains: "All tests passed"
  - Output does NOT contain: "FAIL" or "FAILED"

- [ ] **Step 2: 提交 — 如果 run_all_tests.sh 有改动**

Run: `git status`
如果只有新测试文件（已在前序 Task 提交），无需额外提交。

- [ ] **Step 3: 质量门禁 — 交付前多维检查**
Run: `bash Tests/run_all_tests.sh`
Expected:
  - Exit code: 0
  - 所有测试文件全部通过
  - 无遗留 debug 语句
