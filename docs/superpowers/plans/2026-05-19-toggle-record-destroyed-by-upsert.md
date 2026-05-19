# Bug Fix: toggle record 被 INSERT OR REPLACE 覆盖

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 窗口在主屏幕按快捷键无法回退到副屏，反复出现
**Root Cause:** `saveWindowState` 的 `INSERT OR REPLACE` 完全覆盖行，将 `saveToggleRecord` 保存的 toggle 数据（origFrame, targetFrame, sourceSpace 等）覆盖为 NULL
**Impact:** 所有通过 Ctrl+Q toggle 的窗口，在 session 事件触发 `persistToDB` 后都会丢失 restore 记录

**Architecture:**

```
saveToggleRecord (UPDATE)          saveWindowState (INSERT OR REPLACE)
    ↓                                       ↓
windows 表:                              windows 表:
  window_id=1270                         window_id=1270
  orig_x=326, orig_y=-1055    ←覆盖→     orig_x=NULL, orig_y=NULL
  toggle_reason='manual_hotkey' ←覆盖→    toggle_reason=NULL
  source_space=2               ←覆盖→     source_space=NULL
```

修复：`saveWindowState` 改用 `INSERT ... ON CONFLICT DO UPDATE`，只更新非 toggle 字段，保留已有的 toggle 数据。

**Tech Stack:** Swift 5.9, SQLite3

**Risks:**
- 修改 SQL 可能影响其他调用方 → 缓解：`saveWindowState` 只被 `SessionWindowRegistry` 调用，影响范围可控
- `saveToggleRecord` 的 UPDATE 可能影响 0 行（行不存在）→ 缓解：添加 fallback INSERT

**Autonomy Level:** Full

---

## Type Detection

**Plan Type:** Bug Fix
**Scope:** Small
**Risk:** Medium
**Detection Reason:** INSERT OR REPLACE 覆盖 toggle 数据导致 restore 失败，涉及 2 个文件的 SQL 修改

---

## Pre-Planning Analysis

**Feature:** Toggle record 数据持久化修复
**Scope:** 单一子系统（数据库写入层）
**Files Modify:**
- `Sources/Window/WindowStateStore+Bindings.swift:14-24`（saveWindowState SQL 改为 ON CONFLICT）
- `Sources/Window/WindowStateStore+ToggleRecord.swift:8-79`（saveToggleRecord 添加 upsert fallback）
- `Sources/Window/WindowManager+Toggle.swift:415-423`（移除 isNearTarget 阻断守卫）

**Tasks:** 3 tasks
**Order:** Task 1（修复 saveWindowState 覆盖问题）→ Task 2（修复 saveToggleRecord 静默失败）→ Task 3（移除 isNearTarget 守卫）
**Risks:** Task 1 是关键修复，Task 2/3 是防御性加固

---

### Task 1: 修复 saveWindowState — 使用 ON CONFLICT 保留 toggle 字段

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowStateStore+Bindings.swift:14-24`

- [ ] **Step 1: 修改 saveWindowState SQL — INSERT ON CONFLICT 只更新非 toggle 字段**

文件: `Sources/Window/WindowStateStore+Bindings.swift:13-24`

将 `INSERT OR REPLACE INTO windows (...)` 替换为 `INSERT INTO windows (...) ON CONFLICT(window_id) DO UPDATE SET`，只更新窗口状态字段，不触碰 toggle 字段：

```swift
        let sql = """
            INSERT INTO windows (
                window_id, pid, tty, ax_window_number, app_name, bundle_id, title,
                term_session_id, iterm_session_id, kitty_window_id, wezterm_pane, env_window_id,
                session_id, cwd, model,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(window_id) DO UPDATE SET
                pid = excluded.pid,
                tty = excluded.tty,
                ax_window_number = excluded.ax_window_number,
                app_name = excluded.app_name,
                bundle_id = excluded.bundle_id,
                title = excluded.title,
                term_session_id = excluded.term_session_id,
                iterm_session_id = excluded.iterm_session_id,
                kitty_window_id = excluded.kitty_window_id,
                wezterm_pane = excluded.wezterm_pane,
                env_window_id = excluded.env_window_id,
                session_id = excluded.session_id,
                cwd = excluded.cwd,
                model = excluded.model,
                is_completed = excluded.is_completed,
                completed_at = excluded.completed_at,
                updated_at = excluded.updated_at;
            """
```

关键变化：`ON CONFLICT DO UPDATE SET` 只列出了窗口状态字段（pid, tty, session_id 等），**不包含** orig_x, orig_y, target_x, target_y, toggle_reason 等 toggle 字段。这样即使 `saveWindowState` 在 `saveToggleRecord` 之后执行，也不会覆盖已有的 toggle 数据。

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 2: 修复 saveToggleRecord — 添加 upsert fallback 处理行不存在

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowStateStore+ToggleRecord.swift:8-79`

- [ ] **Step 1: 修改 saveToggleRecord — 检测 UPDATE 影响行数，0 行时 fallback INSERT**

文件: `Sources/Window/WindowStateStore+ToggleRecord.swift:8-79`

将现有的 `UPDATE-only` 逻辑替换为 `UPDATE + fallback INSERT`：

```swift
    func saveToggleRecord(_ record: ToggleRecord) {
        guard let db else {
            log("saveToggleRecord: db is nil", level: .error)
            return
        }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?

        // 1. 尝试 UPDATE 已有行
        let updateSQL = """
            UPDATE windows SET
                orig_x = ?, orig_y = ?, orig_w = ?, orig_h = ?,
                target_x = ?, target_y = ?, target_w = ?, target_h = ?,
                source_space = ?, source_display = ?,
                source_yabai_disp = ?, source_disp_space = ?,
                target_display = ?,
                toggle_reason = 'manual_hotkey',
                toggled_at = ?,
                session_id = ?,
                updated_at = ?
            WHERE window_id = ?
        """

        guard sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK else {
            log("saveToggleRecord prepare failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db))
            ])
            return
        }

        sqlite3_bind_double(stmt, 1, Double(record.origFrame.origin.x))
        sqlite3_bind_double(stmt, 2, Double(record.origFrame.origin.y))
        sqlite3_bind_double(stmt, 3, Double(record.origFrame.size.width))
        sqlite3_bind_double(stmt, 4, Double(record.origFrame.size.height))
        sqlite3_bind_double(stmt, 5, Double(record.targetFrame.origin.x))
        sqlite3_bind_double(stmt, 6, Double(record.targetFrame.origin.y))
        sqlite3_bind_double(stmt, 7, Double(record.targetFrame.size.width))
        sqlite3_bind_double(stmt, 8, Double(record.targetFrame.size.height))
        sqlite3_bind_int(stmt, 9, Int32(record.sourceSpace))
        sqlite3_bind_int(stmt, 10, Int32(record.sourceDisplay))
        sqlite3_bind_int(stmt, 11, Int32(record.sourceYabaiDisp))
        sqlite3_bind_int(stmt, 12, Int32(record.sourceDispSpace))
        sqlite3_bind_int(stmt, 13, Int32(record.targetDisplay))
        sqlite3_bind_double(stmt, 14, record.toggledAt.timeIntervalSince1970)
        if let sid = record.sessionID, !sid.isEmpty {
            sqlite3_bind_text(stmt, 15, sid, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 15)
        }
        sqlite3_bind_double(stmt, 16, now)
        sqlite3_bind_int64(stmt, 17, Int64(record.windowID))

        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        if result != SQLITE_DONE {
            log("saveToggleRecord update failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        let changes = sqlite3_changes(db)
        if changes > 0 {
            log("saveToggleRecord saved", level: .info, fields: [
                "windowID": String(record.windowID),
                "sourceSpace": String(record.sourceSpace),
                "sourceDisplay": String(record.sourceDisplay),
                "sourceYabaiDisp": String(record.sourceYabaiDisp),
                "sourceDispSpace": String(record.sourceDispSpace),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
                "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
            ])
            return
        }

        // 2. UPDATE 影响 0 行 → 行不存在，fallback INSERT
        log("saveToggleRecord: no existing row, inserting new", level: .info, fields: [
            "windowID": String(record.windowID),
            "pid": String(record.pid)
        ])

        let insertSQL = """
            INSERT INTO windows (
                window_id, pid, tty, updated_at,
                orig_x, orig_y, orig_w, orig_h,
                target_x, target_y, target_w, target_h,
                source_space, source_display, source_yabai_disp, source_disp_space,
                target_display, toggle_reason, toggled_at,
                is_completed, created_at
            ) VALUES (?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'manual_hotkey', ?, 0, ?)
        """

        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            log("saveToggleRecord insert prepare failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db))
            ])
            return
        }

        sqlite3_bind_int64(stmt, 1, Int64(record.windowID))
        sqlite3_bind_int(stmt, 2, record.pid)
        sqlite3_bind_double(stmt, 3, now)
        sqlite3_bind_double(stmt, 4, Double(record.origFrame.origin.x))
        sqlite3_bind_double(stmt, 5, Double(record.origFrame.origin.y))
        sqlite3_bind_double(stmt, 6, Double(record.origFrame.size.width))
        sqlite3_bind_double(stmt, 7, Double(record.origFrame.size.height))
        sqlite3_bind_double(stmt, 8, Double(record.targetFrame.origin.x))
        sqlite3_bind_double(stmt, 9, Double(record.targetFrame.origin.y))
        sqlite3_bind_double(stmt, 10, Double(record.targetFrame.size.width))
        sqlite3_bind_double(stmt, 11, Double(record.targetFrame.size.height))
        sqlite3_bind_int(stmt, 12, Int32(record.sourceSpace))
        sqlite3_bind_int(stmt, 13, Int32(record.sourceDisplay))
        sqlite3_bind_int(stmt, 14, Int32(record.sourceYabaiDisp))
        sqlite3_bind_int(stmt, 15, Int32(record.sourceDispSpace))
        sqlite3_bind_int(stmt, 16, Int32(record.targetDisplay))
        sqlite3_bind_double(stmt, 17, record.toggledAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 18, now)

        let insertResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        if insertResult != SQLITE_DONE {
            log("saveToggleRecord insert failed", level: .error, fields: [
                "error": String(cString: sqlite3_errmsg(db)),
                "windowID": String(record.windowID)
            ])
            return
        }

        log("saveToggleRecord inserted new row", level: .info, fields: [
            "windowID": String(record.windowID),
            "sourceSpace": String(record.sourceSpace),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y))"
        ])
    }
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 3: 移除 isNearTarget 阻断守卫

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:415-423`

- [ ] **Step 1: 移除 shouldRestoreCurrentWindow 中的 isNearTarget 检查**

文件: `Sources/Window/WindowManager+Toggle.swift:414-423`

当前代码：
```swift
        // AX-safe: focused window is always visible
        if let currentFrame = self.frame(of: focusedWindow),
           !record.isNearTarget(currentFrame: currentFrame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: window not at target position",
                level: .warn,
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }
```

替换为：
```swift
        // isNearTarget 守卫已移除 — yabai tiling 引擎会移动窗口导致偏移，
        // 此时恰恰是需要 restore 的场景。isValid 检查已足够防止 corrupted data。
```

- [ ] **Step 2: 修复决策日志中的 String(describing: Optional) 问题**

文件: `Sources/Window/WindowManager+Toggle.swift:26`

当前代码：
```swift
            toggleContext["windowID"] = String(describing: winID)
```

替换为：
```swift
            if let id = winID {
                toggleContext["windowID"] = String(id)
            }
```

- [ ] **Step 3: 验证编译 + 部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Build succeeds
  - App signed and installed

- [ ] **Step 4: 提交**

Run: `git add Sources/Window/WindowStateStore+Bindings.swift Sources/Window/WindowStateStore+ToggleRecord.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "fix(toggle): prevent saveWindowState from overwriting toggle records with NULL

Root cause: INSERT OR REPLACE in saveWindowState completely replaces the row,
destroying toggle data saved by saveToggleRecord. Fix by using ON CONFLICT DO
UPDATE that only touches window state fields, preserving toggle fields.

Also adds upsert fallback in saveToggleRecord for missing rows, removes
isNearTarget guard that blocked legitimate restores after yabai window drift."`
