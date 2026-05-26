# Unit Test Coverage Wave 3 — Edge Cases and Output Verification

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 补充 ToggleRecord.isValid 坐标转换边界测试、generateHooksJSON 输出结构验证、hookCommandExample 输出验证。

**Architecture:** 在现有 XCTest 测试文件中追加测试用例，不创建新文件。所有测试通过 `@testable import VibeFocusKit` 直接调用 internal 类型。

**Tech Stack:** Swift 5.9+ swift-testing framework (@Suite, @Test, #expect), macOS 13+

**Scope:** Tiny
**Risk:** Low

**Risks:**
- ToggleRecord.isValid 使用 Quartz→Cocoa 坐标翻转，需要正确理解 mainScreenHeight - y 转换
- generateHooksJSON 依赖 UserDefaults 状态，需要 .serialized 隔离

**Autonomy Level:** Full

---

### Task 1: ToggleRecord.isValid Edge Cases

**Depends on:** None
**Files:**
- Modify: `Tests/XCTest/ToggleLogicTests.swift:193` (append after existing isValid tests)

- [ ] **Step 1: 追加 ToggleRecord.isValid 边界测试到 ToggleLogicTests.swift**

文件: `Tests/XCTest/ToggleLogicTests.swift:193` (文件末尾 `}` 之前追加)

在现有 3 个 isValid 测试之后追加以下测试：

```swift
    @Test("ToggleRecord.isValid: orig at exact screen boundary")
    func toggleRecordOrigAtBoundary() {
        // origFrame center at (0, 540) → Cocoa y = 1080-540 = 540 → inside mainScreen
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 0, y: 0, width: 10, height: 1080),
            sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // orig center at (5, 540) → Cocoa (5, 540) → inside main screen
        // target center at (900, 600) → Cocoa (900, 480) → inside main screen
        // Both inside → NOT valid (orig should be off-screen)
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: orig just off-screen left")
    func toggleRecordOrigJustOffLeft() {
        // origFrame center at (-100, 300) → Cocoa y = 1080-300 = 780 → Cocoa (-100, 780)
        // Cocoa rect is (0,0,1920,1080) → (-100, 780) is outside → valid if target inside
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: -200, y: 0, width: 100, height: 600),
            sourceSpace: 2, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // orig center: Quartz (-150, 300) → Cocoa (-150, 780) → outside mainScreen
        // target center: Quartz (900, 600) → Cocoa (900, 480) → inside mainScreen
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: zero-size orig frame")
    func toggleRecordZeroSizeOrig() {
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 500, y: 500, width: 0, height: 0),
            sourceSpace: 1, sourceDisplay: 1,
            sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // orig center: Quartz (500, 500) → Cocoa (500, 580) → inside
        // target center: Quartz (900, 600) → Cocoa (900, 480) → inside
        // Both inside → NOT valid
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("ToggleRecord.isValid: orig off-screen above (negative y)")
    func toggleRecordOrigOffScreenAbove() {
        // Secondary screen above main: Quartz y < 0
        let record = ToggleRecord(
            windowID: 42, pid: 1234, bundleIdentifier: "com.test", appName: "App",
            origFrame: CGRect(x: 100, y: -800, width: 800, height: 600),
            sourceSpace: 2, sourceDisplay: 2,
            sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
            targetDisplay: 1, toggledAt: Date(), sessionID: "s1"
        )
        let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // orig center: Quartz (500, -500) → Cocoa (500, 1580) → outside (y > 1080)
        // target center: Quartz (900, 600) → Cocoa (900, 480) → inside
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }
```

- [ ] **Step 2: 验证 ToggleRecord.isValid 边界测试**
Run: `swift test 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Test run with" and "passed"
  - Test count increases by 4

- [ ] **Step 3: 质量门禁**
Run: `swift test 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - All tests pass

- [ ] **Step 4: 提交**
Run: `git add Tests/XCTest/ToggleLogicTests.swift && git commit -m "test: add ToggleRecord.isValid edge cases for coordinate conversion boundaries"`

---

### Task 2: generateHooksJSON Output Verification

**Depends on:** None
**Files:**
- Modify: `Tests/XCTest/HookPreferencesTests.swift` (append after existing tests)

- [ ] **Step 1: 追加 generateHooksJSON 输出验证测试**

文件: `Tests/XCTest/HookPreferencesTests.swift` (文件末尾 `}` 之前追加)

```swift
    @Test("generateHooksJSON produces valid JSON with hooks key")
    func generateHooksJSONStructure() throws {
        let json = ClaudeHookPreferences.generateHooksJSON()
        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
    }

    @Test("generateHooksJSON: each hook entry has matcher and hooks array")
    func generateHooksJSONEntryDetail() throws {
        let json = ClaudeHookPreferences.generateHooksJSON()
        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        let sessionStartEntries = try #require(hooks["SessionStart"] as? [[String: Any]])
        let entry = try #require(sessionStartEntries.first)
        #expect(entry["matcher"] as? String == "")
        let hookList = try #require(entry["hooks"] as? [[String: Any]])
        let hook = try #require(hookList.first)
        #expect(hook["type"] as? String == "command")
        #expect(hook["command"] as? String != nil)
    }
```

- [ ] **Step 2: 验证 generateHooksJSON 测试**
Run: `swift test 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Test count increases by 2

- [ ] **Step 3: 质量门禁**
Run: `swift test 2>&1 | tail -3`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Tests/XCTest/HookPreferencesTests.swift && git commit -m "test: add generateHooksJSON output structure verification"`
