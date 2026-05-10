# VibeFocus 日志 Bug 修复 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 VibeFocus 日志中发现的 3 类问题：1) 每次启动的 schema 重复列错误，2) AX 查询失败导致 restore 完全放弃，3) Space 移动验证超时过短 + NativeSpaceBridge 全局失败缓存过于激进。

**Architecture:** 三组独立修复：数据库 schema 用 PRAGMA table_info 检测列是否存在 → WindowManager restore 在 AX 失败时回退到 System Events → SpaceController 增加超时并将 NativeSpaceBridge 失败缓存从全局改为按窗口。

**Tech Stack:** Swift 5.9, macOS 14+, SQLite3, CGS Private API (NativeSpaceBridge)

**Risks:**
- Task 3 修改 SpaceController 超时参数，move 操作延迟会增加 100-200ms → 缓解：仅增加必要超时，不影响成功路径
- Task 2 在 AX 失败时调用 restoreViaSystemEvents，该路径之前仅在权限拒绝时触发 → 缓解：restoreViaSystemEvents 已有成熟实现，只是扩大触发条件
- NativeSpaceBridge 按窗口缓存改为 Dictionary，极低内存开销 → 无风险

---

### Task 1: 修复 Schema 重复列错误

**Depends on:** None
**Files:**
- Modify: `Sources/WindowStateStore+Database.swift:88-89`

**Root Cause:** `createTables()` 中 CREATE TABLE 已包含 `completed_at REAL` 列（line 82），但 line 89 无条件执行 `ALTER TABLE windows ADD COLUMN completed_at REAL`。当表已存在时，ALTER TABLE 失败报 `duplicate column name`。

- [ ] **Step 1: 修改 createTables() — 用列存在检测替换无条件 ALTER TABLE**

文件: `Sources/WindowStateStore+Database.swift:88-89`（替换 line 88-89 的注释和 ALTER TABLE 语句）

```swift
        // Migration: add completed_at column if missing (existing databases)
        if !columnExists(db: db, table: "windows", column: "completed_at") {
            runSchema("ALTER TABLE windows ADD COLUMN completed_at REAL;")
        }
```

- [ ] **Step 2: 添加 columnExists 辅助方法 — 在 WindowStateStore+Database.swift 末尾添加**

文件: `Sources/WindowStateStore+Database.swift:215`（在文件末尾 `}` 之前添加）

```swift
    // MARK: - Schema Helpers

    /// 检查表中是否存在指定列（用于安全的 migration）
    private func columnExists(db: OpaquePointer?, table: String, column: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info('\(table)');"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) {
                if String(cString: name) == column { return true }
            }
        }
        return false
    }
```

- [ ] **Step 3: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowStateStore+Database.swift && git commit -m "fix(db): use column existence check before ALTER TABLE to avoid duplicate column error"`

---

### Task 2: 添加 AX 查询失败时的 Restore 回退路径

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+Restore.swift:102-111`

**Root Cause:** `restore()` 在 line 103 调用 `findWindowByPID` 获取 AX 元素。当 AX API 返回 -25204 (kAXErrorCannotComplete) 时返回 nil，restore 直接 `return` 放弃。但 `restoreViaSystemEvents()` 已有成熟的 CGWindowList + System Events 回退路径，仅在 accessibility 权限被拒绝时触发。AX 查询失败不等于权限拒绝，应该走 System Events 回退。

- [ ] **Step 1: 修改 restore() 函数 — AX 失败时回退到 System Events 而非直接放弃**

文件: `Sources/WindowManager+Restore.swift:102-111`（替换 line 102-111 整个 guard-let 块）

```swift
        // 4. 找到窗口 AX element
        guard let window = findWindowByPID(record.pid, windowID: currentWindowID) else {
            log(
                "[WindowManager] restore: AX query failed, falling back to System Events",
                level: .warn,
                fields: ["op": op, "windowID": String(currentWindowID), "pid": String(record.pid)]
            )
            restoreViaSystemEvents()
            return
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowManager+Restore.swift && git commit -m "fix(restore): fall back to System Events when AX query fails instead of giving up"`

---

### Task 3: 改进 Space 移动验证超时和 NativeSpaceBridge 失败缓存

**Depends on:** None
**Files:**
- Modify: `Sources/SpaceController+Move.swift:373-389`（verifyWindowMovedToSpaceWithRetry）
- Modify: `Sources/SpaceController+Move.swift:164`（NativeSpaceBridge fallback retry count）
- Modify: `Sources/NativeSpaceBridge.swift:51-91`（failure cache 改为按窗口）

**Root Cause A:** `verifyWindowMovedToSpaceWithRetry` 的 poll 超时仅 100ms（6 次检查），yabai 报成功后窗口物理移动需要更多时间。NativeSpaceBridge fallback 仅重试 5×100ms = 500ms。

**Root Cause B:** NativeSpaceBridge 使用全局 `_moveWindowFailedAt` 缓存失败。一个窗口移动失败后，**所有**窗口在 5 分钟内都被禁止使用 NativeSpaceBridge。过于激进 — 不同窗口的失败不应该互相影响。

- [ ] **Step 1: 增加 verifyWindowMovedToSpaceWithRetry 超时**

文件: `Sources/SpaceController+Move.swift:373-389`（替换整个 verifyWindowMovedToSpaceWithRetry 函数）

```swift
    func verifyWindowMovedToSpaceWithRetry(windowID: UInt32, targetSpace: Int, operationID: String) -> Bool {
        pollUntil(timeout: 300_000, interval: 20_000) { [weak self] in
            self?.verifyWindowMovedToSpace(windowID: windowID, targetSpace: targetSpace, operationID: operationID) ?? false
        }
    }
```

- [ ] **Step 2: 增加 NativeSpaceBridge fallback 重试次数和间隔**

文件: `Sources/SpaceController+Move.swift:162-175`（替换 for 循环部分，在 `if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {` 成功后的验证块）

```swift
                    if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                        // 等待更长时间让 CGS API 生效（最多 1200ms）
                        var verified = false
                        for attempt in 1...8 {
                            usleep(150_000) // 150ms per attempt
                            if verifyWindowMovedToSpace(windowID: windowID, targetSpace: spaceIndex, operationID: op) {
                                verified = true
                                break
                            }
                            log(
                                "[SpaceController] NativeSpaceBridge fallback verification attempt \(attempt) failed",
                                level: .debug,
                                fields: ["op": op, "windowID": String(windowID), "targetSpace": String(spaceIndex)]
                            )
                        }
                        if verified {
                            if focus {
                                _ = focusWindow(windowID, operationID: op)
                            }
```

- [ ] **Step 3: 修改 NativeSpaceBridge — 将全局失败缓存改为按窗口缓存**

文件: `Sources/NativeSpaceBridge.swift:51-91`（替换 _moveWindowFailedAt 相关代码和 moveWindow 函数）

```swift
    // 缓存每个窗口的 moveWindow 失败时间 — 避免对已失败的窗口反复调用
    private static var _moveWindowFailures: [UInt32: TimeInterval] = [:]
    private static let moveWindowFailureRetryInterval: TimeInterval = 300

    static func resetFailureCache() {
        _moveWindowFailures.removeAll()
    }

    static func moveWindow(_ windowID: CGWindowID, toSpaceID spaceID: Int64) -> Bool {
        // 检查该窗口是否有缓存失败
        if let failedAt = _moveWindowFailures[UInt32(windowID)] {
            let elapsed = Date().timeIntervalSince1970 - failedAt
            if elapsed < moveWindowFailureRetryInterval {
                log(
                    "[NativeSpaceBridge] moveWindow skipped: window \(windowID) recently failed",
                    level: .debug,
                    fields: ["windowID": String(windowID), "elapsed": String(Int(elapsed)) + "s"]
                )
                return false
            }
            _moveWindowFailures.removeValue(forKey: UInt32(windowID))
        }
        guard let cid = connectionID, let fn = fnMoveWindowsToManagedSpace else {
            log("[NativeSpaceBridge] moveWindow: API not available", level: .error, fields: [:])
            return false
        }
        guard windowID != 0 else {
            log("[NativeSpaceBridge] moveWindow: invalid windowID=0", level: .error, fields: [:])
            return false
        }
        let windowArray: NSArray = [NSNumber(value: UInt32(windowID))]
        let result = fn(cid, windowArray, 1, spaceID)
        if result != 0 {
            _moveWindowFailures[UInt32(windowID)] = Date().timeIntervalSince1970
        }
        log(
            "[NativeSpaceBridge] moveWindow",
            level: result == 0 ? .info : .warn,
            fields: [
                "windowID": String(windowID),
                "spaceID": String(spaceID),
                "result": String(result),
                "cached": String(_moveWindowFailures[UInt32(windowID)] != nil),
            ]
        )
        return result == 0
    }
```

- [ ] **Step 4: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/SpaceController+Move.swift Sources/NativeSpaceBridge.swift && git commit -m "fix(space): increase move verification timeout and use per-window failure cache in NativeSpaceBridge"`
