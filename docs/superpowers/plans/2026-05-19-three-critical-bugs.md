# Bug Fix: windows 表数据流 3 个关键 Bug

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 windows 表写入/读取路径中的 3 个 bug，防止 toggle record 丢失、孤立行累积和窗口行分裂

**Architecture:** 数据流修复 — 修正 3 个写入/读取路径上的 windowID 不一致问题：(1) clear 操作使用了错误的 windowID，(2) 孤立 INSERT 行永远无法被清理，(3) session 绑定与 toggle 状态因 windowID 不同分散到两行

**Tech Stack:** Swift 5.9, SQLite3, macOS Accessibility API

**Scope:** Small
**Risk:** Medium — 修改共享的 WindowStateStore 和 ToggleEngine，影响 toggle/restore 核心路径

**Risks:**
- Bug #1 修改 `shouldRestoreCurrentWindow` 的 clear 路径，可能改变"清除失败 record"的行为 → 缓解：只是修正 clear 使用的 windowID，逻辑不变
- Bug #2 给 INSERT 行设置合理的 `created_at`，避免过期清理误删新行 → 缓解：只改 INSERT 的默认值，不改 UPDATE 路径
- Bug #3 改变 `saveWindowState` 的 ON CONFLICT 策略，需要在 restore 后也更新 session 绑定的 windowID → 缓解：在 `clearToggleRecord` 之后由 SessionWindowRegistry 同步 windowID

**Autonomy Level:** Full

---

## Bug Summary

| # | Symptom | Root Cause | Impact | File |
|---|---------|-----------|--------|------|
| 1 | PID fallback 找到的 invalid record 无法被清除 | `shouldRestoreCurrentWindow()` 用 `currentWindowID` 清除，但 record 实际存储在 `record.windowID` 下 | Corrupted record 永远不会被清理，每次 toggle 都会命中这个无效 record | `WindowManager+Toggle.swift:395` |
| 2 | `saveToggleRecord` fallback INSERT 创建的行永远不被 session registry 管理 | INSERT 只写 `window_id` + toggle 字段，没有 `bundle_id`、`session_id` 等，`init()` 过滤非 terminal PID 时不会清理这些行 | 孤立行在 DB 中累积（只有 `pruneExpiredWindowStates` 的 24h 过期能删，但 `updated_at` 被持续刷新） | `WindowStateStore+ToggleRecord.swift:91-127` |
| 3 | 同一窗口的 session 绑定和 toggle 状态分散在两行 | `saveWindowState` 用 Hook 时的 CGWindowNumber，`saveToggleRecord` 用移动后的 postMoveWindowID，两者可能不同 | `loadToggleRecord` 能找到 toggle 数据但 `findWindowState` 找不到 session 数据，导致 hook-driven restore 缺少 session 上下文 | `WindowStateStore+Bindings.swift:24-41`, `WindowManager+MoveWindow.swift:313` |

---

### Task 1: 修复 shouldRestoreCurrentWindow 的 clear 使用错误 windowID

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:389-396`

**Symptom:** PID fallback 找到了 invalid record，但 `clear(windowID: currentWindowID)` 用的是当前窗口的 CGWindowNumber，而 record 存储在 `record.windowID` 下（可能是旧的 CGWindowNumber）。清除操作命中 0 行，corrupted record 永远残留。

**Root Cause:** 第 395 行 `ToggleEngine.shared.clear(windowID: currentWindowID)` 应该使用 `record.windowID`。

- [ ] **Step 1: 修改 shouldRestoreCurrentWindow 的 clear 调用 — 使用 record.windowID 而非 currentWindowID**

文件: `Sources/Window/WindowManager+Toggle.swift:389-396`（替换 `guard let mainScreen` 区块中的 clear 逻辑）

```swift
        guard let mainScreen = getMainScreen() else { return false }
        if !record.isValid(mainScreenFrame: mainScreen.frame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: toggle record corrupted, clearing",
                level: .warn,
                fields: [
                    "windowID": String(currentWindowID),
                    "storedWindowID": String(record.windowID),
                    "usedPIDFallback": String(currentWindowID != record.windowID)
                ]
            )
            ToggleEngine.shared.clear(windowID: record.windowID)
            return false
        }
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "$(cat <<'EOF'
fix(toggle): use record.windowID for clear in shouldRestoreCurrentWindow — fixes PID fallback clear miss

When PID fallback finds an invalid toggle record, clear() was using
currentWindowID (current CGWindowNumber) instead of record.windowID
(stored CGWindowNumber). Since they differ after cross-display moves,
the clear hit 0 rows and the corrupted record persisted forever.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 修复 saveToggleRecord fallback INSERT 的孤立行问题

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowStateStore+ToggleRecord.swift:85-144`

**Symptom:** 当 `saveToggleRecord` 的 UPDATE 命中 0 行时，fallback INSERT 创建一行只有 `window_id` + `pid` + toggle 字段的记录。这行没有 `bundle_id`、`app_name`、`session_id` 等 session 字段。`SessionWindowRegistry.init()` 会检查 `TerminalAppRegistry.isTerminalPID(state.pid)` 并过滤非 terminal PID 的行，但由于 INSERT 时 `pid` 设置正确（是 terminal PID），这行不会被过滤。问题是这行永远不会被 `SessionWindowRegistry` 管理（因为从未调用 `bind()`），只有 24h 过期清理能删掉它。如果 toggle 频繁（用户反复按热键），这些孤立行会持续存在。

**Root Cause:** Fallback INSERT 是必要的设计（支持非 hook 触发的 toggle），但缺少 `bundle_id` 字段导致 `SessionWindowRegistry` 无法正确关联。修复方式：在 INSERT 时额外传入 `bundle_identifier` 和 `app_name`。

- [ ] **Step 1: 修改 ToggleEngine.save 传递 bundleIdentifier 和 appName 到 record**

`ToggleRecord` 已有 `bundleIdentifier` 和 `appName` 字段。检查 `saveToggleRecord` 的 INSERT SQL 是否使用了这些字段。

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift:91-99`（替换 INSERT SQL）

```sql
            INSERT INTO windows (
                window_id, pid, bundle_id, app_name, tty, updated_at,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at
            ) VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual_hotkey', ?, 0, ?)
```

- [ ] **Step 2: 修改 INSERT 的绑定参数 — 添加 bundle_id 和 app_name**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift:109-126`（替换 sqlite3_bind 区块）

```swift
        sqlite3_bind_int64(stmt, 1, Int64(record.windowID))
        sqlite3_bind_int(stmt, 2, record.pid)
        sqlite3_bind_text(stmt, 3, record.bundleIdentifier ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, record.appName ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, now)
        sqlite3_bind_double(stmt, 6, Double(record.origFrame.origin.x))
        sqlite3_bind_double(stmt, 7, Double(record.origFrame.origin.y))
        sqlite3_bind_double(stmt, 8, Double(record.origFrame.size.width))
        sqlite3_bind_double(stmt, 9, Double(record.origFrame.size.height))
        sqlite3_bind_double(stmt, 10, Double(record.targetFrame.origin.x))
        sqlite3_bind_double(stmt, 11, Double(record.targetFrame.origin.y))
        sqlite3_bind_double(stmt, 12, Double(record.targetFrame.size.width))
        sqlite3_bind_double(stmt, 13, Double(record.targetFrame.size.height))
        sqlite3_bind_int(stmt, 14, Int32(record.sourceSpace))
        sqlite3_bind_int(stmt, 15, Int32(record.sourceDisplay))
        sqlite3_bind_int(stmt, 16, Int32(record.sourceYabaiDisp))
        sqlite3_bind_int(stmt, 17, Int32(record.sourceDispSpace))
        sqlite3_bind_int(stmt, 18, Int32(record.targetDisplay))
        sqlite3_bind_double(stmt, 19, record.toggledAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 20, now)
```

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowStateStore+ToggleRecord.swift && git commit -m "$(cat <<'EOF'
fix(store): add bundle_id and app_name to saveToggleRecord fallback INSERT

When saveToggleRecord's UPDATE hits 0 rows (no existing session binding),
the fallback INSERT was only storing window_id + pid + toggle fields.
This created orphan rows without bundle_id, which SessionWindowRegistry
couldn't manage. Now includes bundle_id and app_name so the row can be
properly associated and cleaned up.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: 修复 toggle record 与 session 绑定因 windowID 不同导致的行分裂

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:313-326`（save 后同步 SessionWindowRegistry 的 windowID）
- Modify: `Sources/Window/SessionWindowRegistry.swift`（添加 windowID 重映射方法）

**Symptom:** Hook 在 SessionStart 时绑定 `windowID=A`，然后用户按热键移动窗口到主屏，`moveWindowToMainScreen` 读取到 `postMoveWindowID=B`（CGWindowNumber 因移动改变了），`saveToggleRecord` 写入 `windowID=B` 的行。此时 DB 中有两行：`A` 只有 session 数据，`B` 只有 toggle 数据。restore 时能通过 PID fallback 找到 toggle record，但 session 数据（tty, termSessionID 等）在 `A` 行上无法被关联。

**Root Cause:** `moveWindowToMainScreen` 保存了 toggle record 到新的 `postMoveWindowID`，但没有更新 `SessionWindowRegistry` 中旧 `windowID` 的映射。当 Hook 后续通过 sessionID 查找窗口时，仍然找到旧的 `windowID=A`，找不到 toggle 数据。

**修复策略:** 在 `saveToggleRecord` 成功且 `postMoveWindowID != effectiveWindowID` 时，调用 `SessionWindowRegistry` 将旧 windowID 的绑定重映射到新 windowID。

- [ ] **Step 1: 给 SessionWindowRegistry 添加 remapWindowID 方法**

文件: `Sources/Window/SessionWindowRegistry.swift`（在 `clearToggleState` 方法之后添加）

```swift
    /// 将旧 windowID 的绑定重映射到新 windowID（CGWindowNumber 变化时调用）
    func remapWindowID(oldWindowID: UInt32, newWindowID: UInt32) {
        guard oldWindowID != newWindowID else { return }
        guard var state = windowStates[oldWindowID] else {
            // 旧 windowID 不在内存缓存中 — 尝试从 DB 加载
            if let dbState = WindowStateStore.shared.findWindowState(windowID: oldWindowID) {
                var remapped = dbState
                // 在 DB 中创建新行（以 newWindowID 为主键）
                remapped.windowID = newWindowID
                windowStates[newWindowID] = remapped
                persistToDB(windowID: newWindowID)
                // 删除旧行
                WindowStateStore.shared.deleteWindowState(windowID: oldWindowID)
                windowStates.removeValue(forKey: oldWindowID)
                log("[SessionWindowRegistry] remapWindowID: DB remap", fields: [
                    "oldWindowID": String(oldWindowID),
                    "newWindowID": String(newWindowID)
                ])
            }
            return
        }
        // 内存中有旧绑定 — 重映射到新 windowID
        state.windowID = newWindowID
        windowStates[newWindowID] = state
        windowStates.removeValue(forKey: oldWindowID)
        // 删除旧行，写入新行
        WindowStateStore.shared.deleteWindowState(windowID: oldWindowID)
        persistToDB(windowID: newWindowID)
        log("[SessionWindowRegistry] remapWindowID: memory+DB remap", fields: [
            "oldWindowID": String(oldWindowID),
            "newWindowID": String(newWindowID)
        ])
    }
```

- [ ] **Step 2: 在 moveWindowToMainScreen 中调用 remapWindowID**

文件: `Sources/Window/WindowManager+MoveWindow.swift:298-312`（在 CGWindowNumber changed 日志之后、ToggleEngine.shared.save 之前，添加 remap 调用）

找到这段代码（约 301-312 行）：
```swift
            let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
            if postMoveWindowID != effectiveWindowID {
                log(
                    "[WindowManager] moveWindowToMainScreen: CGWindowNumber changed after move",
                    level: .info,
                    fields: [
                        "op": op,
                        "beforeMoveWindowID": String(effectiveWindowID),
                        "afterMoveWindowID": String(postMoveWindowID)
                    ]
                )
            }
```

替换为：
```swift
            let postMoveWindowID = windowHandle(for: windowAX) ?? effectiveWindowID
            if postMoveWindowID != effectiveWindowID {
                log(
                    "[WindowManager] moveWindowToMainScreen: CGWindowNumber changed after move",
                    level: .info,
                    fields: [
                        "op": op,
                        "beforeMoveWindowID": String(effectiveWindowID),
                        "afterMoveWindowID": String(postMoveWindowID)
                    ]
                )
                // CGWindowNumber 变化 — 同步 SessionWindowRegistry 的 windowID 映射
                // 防止 session 绑定（旧 windowID）和 toggle record（新 windowID）分裂成两行
                SessionWindowRegistry.shared.remapWindowID(oldWindowID: effectiveWindowID, newWindowID: postMoveWindowID)
            }
```

- [ ] **Step 3: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 质量门禁 — 交付前多维检查**
Run: `swift build 2>&1 | grep -E "error:|warning:" | head -20`
Expected:
  - Exit code: 0
  - Output is empty (no errors or warnings)
  - 手工检查：无遗留 debug 语句、无 TODO、无 dead code

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/SessionWindowRegistry.swift Sources/Window/WindowManager+MoveWindow.swift && git commit -m "$(cat <<'EOF'
fix(toggle): remap SessionWindowRegistry windowID when CGWindowNumber changes after move

When a window is moved to the main screen, CGWindowNumber may change
(iTerm2). saveToggleRecord writes to the new windowID, but the session
binding still references the old windowID. This creates two split rows
in the DB: one with session data, one with toggle data.

Now when CGWindowNumber changes, SessionWindowRegistry.remapWindowID()
migrates the session binding from old to new windowID, keeping session
and toggle data on the same row.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
