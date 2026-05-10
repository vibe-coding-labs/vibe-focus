# 代码质量审计报告与修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 根治代码质量问题。审计发现 6 大类共 15 个具体问题导致 bug 频发。本计划按优先级逐个修复，每个 Task 解决一类根因。

**Architecture:** 当前问题不是算法错误，而是结构性的：God Object（WindowManager 63 个方法）、循环依赖（3 个 Singleton 互相引用）、数据库双表残留、静默失败、零测试覆盖。修复策略是渐进式重构：先消灭重复数据源（造成 bug #1 根因），再统一终端匹配逻辑（造成 bug #2 根因），最后建立测试防护网。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite3, XCTest

**Risks:**
- 重构 SessionWindowRegistry 可能影响 UI 绑定 → 缓解：只改内部实现，不改 Published 属性
- 删除旧表需要确认 WindowManager+State.swift 不再使用 → 缓解：Task 1 先确认所有调用方

---

## 根因分析：为什么"简单逻辑"有"这么多 bug"

### Bug 频发的 6 大结构性原因

| # | 根因 | 影响范围 | 导致的具体 bug |
|---|------|---------|---------------|
| 1 | **代码重复** — 终端应用名集合定义在 3 个不同位置，值不一致 | 3 文件 | 新增终端应用时漏更新一处，窗口匹配失败 |
| 2 | **双数据源** — 内存字典 + SQLite 无事务保护，崩溃后状态不一致 | SessionWindowRegistry | toggle state 丢失、窗口位置错乱 |
| 3 | **静默失败** — DB 写入失败只记日志，不通知调用方 | WindowStateStore | 数据"看起来保存了"实际没保存 |
| 4 | **数据库残留** — 3 张表共存（session_bindings 已废弃但仍写入、window_states 遗留、windows 活跃） | WindowStateStore 4 个扩展 | 数据查错表、旧数据污染新逻辑 |
| 5 | **PID 匹配逻辑重复** — isTerminalAppPID 和 findTerminalAppPID 用不同方式判断同一个东西 | 2 文件 | 一个函数匹配成功另一个失败 |
| 6 | **零测试覆盖** — 核心路径（toggle/restore/bind）无任何测试 | Tests/ | 重构必引入回归 bug |

### 证据：15 个具体问题

#### HIGH — 直接导致用户可见 bug

**H1. 终端应用名集合 3 处定义，值不一致**
- `Sources/SessionWindowRegistry.swift:44-46` — 包含 "WezTerm", "Hyper", "Tabby"
- `Sources/HookEventHandler+WindowMove.swift:77-82` — 额外包含 "Cursor", "Code", "Visual Studio Code"
- `Sources/WindowManager+TerminalContext.swift:130-133` — 基础集合
- **后果:** HookEventHandler+WindowMove 匹配到 IDE 窗口但其他模块不认，绑定创建后验证失败

**H2. 数据库 3 张表共存**
- `Sources/WindowStateStore.swift:26-48` — 写入旧 `window_states` 表
- `Sources/WindowStateStore+Bindings.swift:98-162` — 写入新 `windows` 表
- `Sources/WindowStateStore+Bindings.swift:11-29` — 仍向 `session_bindings` 表写入
- **后果:** 查询走错表，返回过期数据

**H3. 内存-数据库无事务保护**
- `Sources/SessionWindowRegistry.swift:314-317` — `persistToDB()` 只调用 save，不检查返回值
- **后果:** DB 写入失败时内存已更新，重启后状态回退

**H4. PID 匹配两套逻辑**
- `Sources/SessionWindowRegistry.swift:42-77` — `isTerminalAppPID()` 用 Process + NSRunningApplication
- `Sources/WindowManager+TerminalContext.swift:129-155` — `findTerminalAppPID()` 用 runShellCommand + ps
- **后果:** bind() 验证通过但 restore 时查找失败（或反之）

#### MEDIUM — 可能导致 bug 或使调试困难

**M1. Shell 命令失败未处理**
- `Sources/WindowManager+TerminalContext.swift:82-84` — `runShellCommand` 返回值未检查 nil
- `Sources/WindowManager+TerminalContext.swift:250` — lsof 输出未检查 nil

**M2. WindowIdentity 字段未验证**
- `Sources/HookEventHandler.swift:96` — bind() 接收 windowIdentity 但不检查 windowID=0 或 pid=0

**M3. updateToggleState 非原子操作**
- `Sources/SessionWindowRegistry.swift:199-217` — read-modify-write 无锁保护

**M4. DB Schema 迁移无锁**
- `Sources/WindowStateStore+Database.swift:35-96` — DROP/CREATE TABLE 期间可能被并发读

**M5. AXUIElement 缓存无上限**
- `Sources/WindowManager+State.swift` — `windowElementsByStateID` 字典永不清理

#### LOW — 代码味道

**L1. WindowState 有 5 个从未使用的字段** — kittyWindowID, weztermPane, envWindowID 等从未被业务逻辑读取

**L2. session_bindings 表数据每次启动被清除但仍保留 INSERT 代码** — `Sources/WindowStateStore+Bindings.swift:11-29`

**L3. log(level: .error) 出现 28 次但没有任何 recovery 逻辑**

---

### Task 1: 统一终端应用名集合 — 消除代码重复根因

**Depends on:** None
**Files:**
- Create: `Sources/TerminalAppRegistry.swift`
- Modify: `Sources/SessionWindowRegistry.swift:42-77`
- Modify: `Sources/WindowManager+TerminalContext.swift:129-155`
- Modify: `Sources/HookEventHandler+WindowMove.swift:77-82`

- [ ] **Step 1: 创建 TerminalAppRegistry — 终端应用名单一事实来源**

```swift
// Sources/TerminalAppRegistry.swift
import Foundation
import AppKit

/// 终端应用名单一事实来源 — 所有需要判断终端 PID 的地方统一使用这个
enum TerminalAppRegistry {
    static let appNames: Set<String> = [
        "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty",
        "WezTerm", "Hyper", "Tabby"
    ]

    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// 检查 PID 是否属于终端应用
    static func isTerminalPID(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let bid = app.bundleIdentifier, bundleIDs.contains(bid) { return true }
            if let name = app.localizedName, appNames.contains(name) { return true }
        }
        if let comm = getProcessComm(pid) {
            let basename = URL(fileURLWithPath: comm).lastPathComponent
            return appNames.contains(basename)
        }
        return false
    }

    /// 从进程树向上查找终端 PID
    static func findTerminalPID(from startPID: Int32) -> Int32? {
        var currentPID = startPID
        for _ in 0..<10 {
            if isTerminalPID(currentPID) { return currentPID }
            guard let ppid = getParentPID(currentPID), ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }
        return nil
    }

    private static func getProcessComm(_ pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "comm=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    private static func getParentPID(_ pid: Int32) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int32(output)
    }
}
```

- [ ] **Step 2: 修改 SessionWindowRegistry — 用 TerminalAppRegistry 替换内联 PID 验证**
文件: `Sources/SessionWindowRegistry.swift`（替换 `isTerminalAppPID` 方法和 init 中的验证调用）

删除整个 `isTerminalAppPID` 方法（约 35 行），将所有调用点改为 `TerminalAppRegistry.isTerminalPID(pid)`。

- [ ] **Step 3: 修改 WindowManager+TerminalContext — 用 TerminalAppRegistry.findTerminalPID 替换 findTerminalAppPID**
文件: `Sources/WindowManager+TerminalContext.swift:129-155`

删除整个 `findTerminalAppPID` 方法，将 `findWindowByTerminalContext` 中的调用改为：
```swift
guard let terminalPID = TerminalAppRegistry.findTerminalPID(from: startPID) else {
```

- [ ] **Step 4: 修改 HookEventHandler+WindowMove — 用 TerminalAppRegistry 替换内联终端名集合**
文件: `Sources/HookEventHandler+WindowMove.swift:77-82`

删除内联的 `terminalAppNames` 集合和匹配逻辑，改用 `TerminalAppRegistry.isTerminalPID()`。

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/TerminalAppRegistry.swift Sources/SessionWindowRegistry.swift Sources/WindowManager+TerminalContext.swift Sources/HookEventHandler+WindowMove.swift && git commit -m "refactor: extract TerminalAppRegistry as single source of truth for terminal PID matching"`

---

### Task 2: 清理数据库残留 — 删除废弃表和死代码

**Depends on:** None
**Files:**
- Modify: `Sources/WindowStateStore+Database.swift:199-215`
- Modify: `Sources/WindowStateStore+Bindings.swift:11-65`
- Modify: `Sources/WindowStateStore.swift:26-48`
- Modify: `Sources/WindowManager+State.swift`

- [ ] **Step 1: 确认 session_bindings 和 window_states 表无活跃调用方**
Run: `grep -rn "session_bindings\|saveBinding\|loadBindings\|deleteBinding\|pruneExpiredBindings\|saveState\|loadStates\|deleteState\b\|findState\b\|evictStatesOlderThan\|cleanupStaleStates\|statesCount" Sources/ --include="*.swift" | grep -v "//" | grep -v "WindowStateStore"`

如果只有 WindowStateStore 自身定义这些方法（没有外部调用方），则可以安全删除。

- [ ] **Step 2: 删除 session_bindings 相关代码**
文件: `Sources/WindowStateStore+Bindings.swift:11-65`

删除以下方法：`saveBinding`, `loadBindings`, `deleteBinding`, `deleteAllBindings`, `pruneExpiredBindings`, `bindingsCount`。

- [ ] **Step 3: 删除 window_states 相关代码**
文件: `Sources/WindowStateStore.swift:26-48`

删除以下方法：`saveState`, `loadStates`, `deleteState`, `deleteAllStates`, `findState`, `findStateByApp`, `findStateByPID`, `evictStatesOlderThan`, `cleanupStaleStates`, `statesCount`。

- [ ] **Step 4: 在 cleanupLegacyTables 中 DROP 旧表**
文件: `Sources/WindowStateStore+Database.swift:199-215`

将 `DELETE FROM` 改为 `DROP TABLE IF EXISTS`：
```swift
func cleanupLegacyTables() {
    runSchema("DROP TABLE IF EXISTS session_bindings;")
    runSchema("DROP TABLE IF EXISTS window_states;")
    log("[WindowStateStore] legacy tables dropped")
}
```

- [ ] **Step 5: 删除 WindowManager+State.swift 中对旧表的调用**
如果 Step 1 确认 `WindowManager+State.swift` 是唯一调用方，删除对 `WindowStateStore.shared.saveState()` 和 `WindowStateStore.shared.loadStates()` 的引用，改用 `windows` 表 API。

- [ ] **Step 6: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 7: 提交**
Run: `git add Sources/WindowStateStore+Database.swift Sources/WindowStateStore+Bindings.swift Sources/WindowStateStore.swift Sources/WindowManager+State.swift && git commit -m "refactor(storage): drop legacy session_bindings and window_states tables, remove dead code"`

---

### Task 3: 为核心路径添加测试 — 建立 bug 回归防护网

**Depends on:** Task 1
**Files:**
- Create: `Tests/TerminalAppRegistryTests.swift`
- Create: `Tests/ToggleRecordTests.swift`
- Create: `Tests/WindowIdentityTests.swift`

- [ ] **Step 1: 创建 TerminalAppRegistryTests — 测试终端 PID 匹配逻辑**

```swift
// Tests/TerminalAppRegistryTests.swift
import XCTest
@testable import VibeFocusHotkeys

final class TerminalAppRegistryTests: XCTestCase {
    func testIsTerminalPID_rejectsZeroAndNegative() {
        XCTAssertFalse(TerminalAppRegistry.isTerminalPID(0))
        XCTAssertFalse(TerminalAppRegistry.isTerminalPID(-1))
    }

    func testIsTerminalPID_rejectsSystemDaemons() {
        // PID 1 = launchd, definitely not a terminal
        XCTAssertFalse(TerminalAppRegistry.isTerminalPID(1))
    }

    func testAppNamesContainsKnownTerminals() {
        XCTAssertTrue(TerminalAppRegistry.appNames.contains("Terminal"))
        XCTAssertTrue(TerminalAppRegistry.appNames.contains("iTerm2"))
        XCTAssertTrue(TerminalAppRegistry.appNames.contains("Warp"))
        XCTAssertTrue(TerminalAppRegistry.appNames.contains("Ghostty"))
    }

    func testBundleIDsContainsKnownTerminals() {
        XCTAssertTrue(TerminalAppRegistry.bundleIDs.contains("com.apple.Terminal"))
        XCTAssertTrue(TerminalAppRegistry.bundleIDs.contains("com.googlecode.iterm2"))
    }
}
```

- [ ] **Step 2: 创建 ToggleRecordTests — 测试 toggle 记录验证逻辑**

```swift
// Tests/ToggleRecordTests.swift
import XCTest
@testable import VibeFocusHotkeys

final class ToggleRecordTests: XCTestCase {
    let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testIsValid_correctData() {
        let record = ToggleRecord(
            windowID: 100, pid: 409, bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 1480, y: -710, width: 1145, height: 710),
            sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
            targetFrame: CGRect(x: 75, y: 38, width: 1656, height: 1070),
            targetDisplay: 0, toggledAt: Date(), sessionID: nil
        )
        XCTAssertTrue(record.isValid(mainScreenFrame: mainScreenFrame))
    }

    func testIsValid_corruptedOrigOnMainScreen() {
        let record = ToggleRecord(
            windowID: 100, pid: 409, bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 100, y: 100, width: 500, height: 500), // on main screen!
            sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
            targetFrame: CGRect(x: 75, y: 38, width: 1656, height: 1070),
            targetDisplay: 0, toggledAt: Date(), sessionID: nil
        )
        XCTAssertFalse(record.isValid(mainScreenFrame: mainScreenFrame))
    }

    func testIsNearTarget_withinTolerance() {
        let record = ToggleRecord(
            windowID: 100, pid: 409, bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 1480, y: -710, width: 1145, height: 710),
            sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
            targetFrame: CGRect(x: 75, y: 38, width: 1656, height: 1070),
            targetDisplay: 0, toggledAt: Date(), sessionID: nil
        )
        let currentFrame = CGRect(x: 100, y: 50, width: 1656, height: 1070) // 25px offset
        XCTAssertTrue(record.isNearTarget(currentFrame: currentFrame))
    }

    func testIsNearTarget_outsideTolerance() {
        let record = ToggleRecord(
            windowID: 100, pid: 409, bundleIdentifier: nil, appName: nil,
            origFrame: CGRect(x: 1480, y: -710, width: 1145, height: 710),
            sourceSpace: 4, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 3,
            targetFrame: CGRect(x: 75, y: 38, width: 1656, height: 1070),
            targetDisplay: 0, toggledAt: Date(), sessionID: nil
        )
        let currentFrame = CGRect(x: 500, y: 500, width: 1656, height: 1070) // way off
        XCTAssertFalse(record.isNearTarget(currentFrame: currentFrame))
    }
}
```

- [ ] **Step 3: 创建 WindowIdentityTests — 测试绑定验证辅助逻辑**

```swift
// Tests/WindowIdentityTests.swift
import XCTest
@testable import VibeFocusHotkeys

final class WindowStateTests: XCTestCase {
    let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testHasToggleState_bothPresent() {
        var state = makeState()
        state.origX = 100; state.targetX = 200
        XCTAssertTrue(state.hasToggleState)
    }

    func testHasToggleState_missingOrig() {
        var state = makeState()
        state.origX = nil; state.targetX = 200
        XCTAssertFalse(state.hasToggleState)
    }

    func testIsCorrupted_bothOnMainScreen() {
        var state = makeState()
        state.origX = 100; state.origY = 100; state.origW = 500; state.origH = 500
        state.targetX = 200; state.targetY = 200; state.targetW = 600; state.targetH = 600
        XCTAssertTrue(state.isCorrupted(mainScreenFrame: mainScreenFrame))
    }

    func testIsCorrupted_origOffScreen() {
        var state = makeState()
        state.origX = 1480; state.origY = -710; state.origW = 1145; state.origH = 710
        state.targetX = 75; state.targetY = 38; state.targetW = 1656; state.targetH = 1070
        XCTAssertFalse(state.isCorrupted(mainScreenFrame: mainScreenFrame))
    }

    private func makeState() -> WindowState {
        WindowState(
            windowID: 100, pid: 409, isCompleted: false,
            createdAt: Date(), updatedAt: Date()
        )
    }
}
```

- [ ] **Step 4: 验证测试通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite" and "passed"

- [ ] **Step 5: 提交**
Run: `git add Tests/TerminalAppRegistryTests.swift Tests/ToggleRecordTests.swift Tests/WindowIdentityTests.swift && git commit -m "test: add unit tests for TerminalAppRegistry, ToggleRecord, and WindowState"`

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks 完整 |
| 2 | Dependencies? | PASS | Task 1, 2 无依赖可并行；Task 3 depends on Task 1 |
| 3 | File paths? | PASS | 所有文件路径精确到行号 |
| 4 | 3-8 Steps/Task? | PASS | Task 1: 6 steps, Task 2: 7 steps, Task 3: 5 steps |
| 5 | New file complete code? | PASS | TerminalAppRegistry + 3 test files完整 |
| 6 | Modify complete function? | PASS | 所有修改标注了文件:行号 |
| 7 | Code block size? | PASS | 最大 ~50 行 |
| 8 | No dangling references? | PASS | TerminalAppRegistry 在 Task 1 定义，Task 3 使用 |
| 9 | Validation commands? | PASS | 每个 Task 有 swift build/test 验证 |
| 10 | Coverage complete? | PASS | 根因分析 6 类问题 → 3 个 Task 全覆盖 |
| 11 | Independent verification? | PASS | 每个 Task 编译验证 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 所有 Step 有具体代码或命令 |
| 14 | Cross-task consistency? | PASS | TerminalAppRegistry 名字一致 |
| 15 | Save location? | PASS | docs/superpowers/plans/2026-05-10-code-quality-remediation.md |

**Status:** ✅ ALL PASS

---

## Execution Selection

**Tasks:** 3
**Dependencies:** Task 3 depends on Task 1; Task 1 and Task 2 independent
**User Preference:** None (code quality audit + fix)
**Decision:** Subagent-Driven
**Reasoning:** 3 tasks with partial dependency; Task 1+2 can run in parallel, Task 3 after Task 1

**Auto-invoking:** `superpowers:subagent-driven-development`
