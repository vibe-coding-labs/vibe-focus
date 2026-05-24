# Refactor: Window/ 目录 — 消除 ToggleRecord 行解析重复 + 精简日志

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除 WindowStateStore+ToggleRecord.swift 中 `loadToggleRecord` 和 `loadToggleRecordByPID` 的 ~25 行重复行解析代码；精简 WindowManager+Toggle.swift 中 `moveToMainScreen` 的冗余 debug 日志。

**Architecture:** 纯提取 — 提取共享的 `parseToggleRecord(stmt:)` 行解析方法；删除 debug 级别噪音日志。数据流不变。

**Safety Net:** `swift build` 编译验证
**Scope:** Small
**Risk:** Low

**Before/After:**
- Before: loadToggleRecord 和 loadToggleRecordByPID 各 ~25 行重复的列读取代码；moveToMainScreen 6+ 个 debug 日志
- After: 共享 parseToggleRecord 方法消除重复；moveToMainScreen 保留决策点日志

**Risks:**
- parseToggleRecord 提取时列索引可能对不上 → 缓解：保持与原代码完全相同的列序号

**Autonomy Level:** Full

---

### Task 1: Extract parseToggleRecord — 消除行解析重复

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowStateStore+ToggleRecord.swift`（提取共享行解析方法）

**问题分析：** `loadToggleRecord(windowID:)` (line 150-200) 和 `loadToggleRecordByPID(pid:)` (line 203-255) 有完全相同的 ~25 行行解析代码（从 stmt 读取 19 列并构造 ToggleRecord）。只有 WHERE 子句不同。

- [ ] **Step 1: 添加 parseToggleRecord 方法**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift`（在 `optionalStringCol` 方法之前添加）

```swift
    // MARK: - Toggle Record Row Parser

    private func parseToggleRecord(_ stmt: OpaquePointer) -> ToggleRecord? {
        let wID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let bundleID: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let appName: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

        let ox = CGFloat(sqlite3_column_double(stmt, 4))
        let oy = CGFloat(sqlite3_column_double(stmt, 5))
        let ow = CGFloat(sqlite3_column_double(stmt, 6))
        let oh = CGFloat(sqlite3_column_double(stmt, 7))
        let tx = CGFloat(sqlite3_column_double(stmt, 8))
        let ty = CGFloat(sqlite3_column_double(stmt, 9))
        let tw = CGFloat(sqlite3_column_double(stmt, 10))
        let th = CGFloat(sqlite3_column_double(stmt, 11))

        let sourceSpace = Int(sqlite3_column_int(stmt, 12))
        let sourceDisplay = Int(sqlite3_column_int(stmt, 13))
        let sourceYabaiDisp = Int(sqlite3_column_int(stmt, 14))
        let sourceDispSpace = Int(sqlite3_column_int(stmt, 15))
        let targetDisplay = Int(sqlite3_column_int(stmt, 16))
        let toggledAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let sessionID: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

        return ToggleRecord(
            windowID: wID, pid: pid,
            bundleIdentifier: bundleID, appName: appName,
            origFrame: CGRect(x: ox, y: oy, width: ow, height: oh),
            sourceSpace: sourceSpace, sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: sourceDispSpace,
            targetFrame: CGRect(x: tx, y: ty, width: tw, height: th),
            targetDisplay: targetDisplay,
            toggledAt: toggledAt, sessionID: sessionID
        )
    }
```

- [ ] **Step 2: 替换 loadToggleRecord 中的行解析代码**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift`（loadToggleRecord 方法，约 line 168-200）

将以下代码：
```swift
        let wID = UInt32(sqlite3_column_int64(stmt, 0))
        let pid = sqlite3_column_int(stmt, 1)
        let bundleID: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let appName: String? = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

        let ox = CGFloat(sqlite3_column_double(stmt, 4))
        let oy = CGFloat(sqlite3_column_double(stmt, 5))
        let ow = CGFloat(sqlite3_column_double(stmt, 6))
        let oh = CGFloat(sqlite3_column_double(stmt, 7))
        let tx = CGFloat(sqlite3_column_double(stmt, 8))
        let ty = CGFloat(sqlite3_column_double(stmt, 9))
        let tw = CGFloat(sqlite3_column_double(stmt, 10))
        let th = CGFloat(sqlite3_column_double(stmt, 11))

        let sourceSpace = Int(sqlite3_column_int(stmt, 12))
        let sourceDisplay = Int(sqlite3_column_int(stmt, 13))
        let sourceYabaiDisp = Int(sqlite3_column_int(stmt, 14))
        let sourceDispSpace = Int(sqlite3_column_int(stmt, 15))
        let targetDisplay = Int(sqlite3_column_int(stmt, 16))
        let toggledAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let sessionID: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }

        return ToggleRecord(
            windowID: wID, pid: pid,
            bundleIdentifier: bundleID, appName: appName,
            origFrame: CGRect(x: ox, y: oy, width: ow, height: oh),
            sourceSpace: sourceSpace, sourceDisplay: sourceDisplay,
            sourceYabaiDisp: sourceYabaiDisp, sourceDispSpace: sourceDispSpace,
            targetFrame: CGRect(x: tx, y: ty, width: tw, height: th),
            targetDisplay: targetDisplay,
            toggledAt: toggledAt, sessionID: sessionID
        )
```

替换为：
```swift
        return parseToggleRecord(stmt)
```

- [ ] **Step 3: 替换 loadToggleRecordByPID 中的行解析代码**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift`（loadToggleRecordByPID 方法，约 line 223-255）

将同样的 ~25 行列读取代码替换为：
```swift
        return parseToggleRecord(stmt)
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowStateStore+ToggleRecord.swift && git commit -m "$(cat <<'EOF'
refactor(window): extract parseToggleRecord to eliminate duplicate row parsing

loadToggleRecord and loadToggleRecordByPID both had ~25 lines of
identical column-reading code. Extract into shared parseToggleRecord()
method. No behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Thin verbose debug logging in moveToMainScreen

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift`（精简 moveToMainScreen 中的冗余 debug 日志）

**问题分析：** `moveToMainScreen()` 有 6+ 个 `.debug` 级别日志，记录了 "AX OK, capturing..." / "captured identity" / "moveWindowToMainScreen returned" 等中间步骤。这些在正常操作中只是噪音。应保留决策点日志（accessibility denied、identity missing、move failed/succeeded）。

- [ ] **Step 1: 删除 moveToMainScreen 中的冗余 debug 日志**

文件: `Sources/Window/WindowManager+Toggle.swift`

删除以下 debug 日志块：

1. Line 257-261（"AX OK, capturing focused window identity"）：
```swift
        log(
            "[WindowManager] move_to_main AX OK, capturing focused window identity",
            level: .debug,
            fields: ["op": op]
        )
```

2. Line 273-281（"captured identity"）：
```swift
        log(
            "[WindowManager] move_to_main captured identity",
            level: .debug,
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid)
            ]
        )
```

3. Line 288-295（"moveWindowToMainScreen returned"）：
```swift
        log(
            "[WindowManager] move_to_main moveWindowToMainScreen returned",
            level: .debug,
            fields: [
                "op": op,
                "moved": String(moved)
            ]
        )
```

4. Line 236-242（accessibility check 结果，已被后面的 denied/error 日志覆盖）：
```swift
        log(
            "[WindowManager] accessibility check",
            fields: [
                "op": op,
                "axTrusted": String(axTrusted)
            ]
        )
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "$(cat <<'EOF'
refactor(window): thin verbose debug logging in moveToMainScreen

Remove 4 debug-level log calls that only recorded entry/exit of
intermediate steps. Keep error/warn logs at decision boundaries
(accessibility denied, identity missing, move result).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
