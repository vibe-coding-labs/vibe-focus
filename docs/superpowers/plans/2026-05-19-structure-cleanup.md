# Refactor: 代码结构梳理 — 消除死代码与重复逻辑

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 清理 3 类结构性混乱：死代码（`window_states` 表全链路未使用）、重复方法（`clearToggleState` 存在 3 份）、过度日志（调试信息淹没了关键逻辑）

**Architecture:**
- 数据流：删除 `window_states` 表相关的写入/读取/清理路径（WindowStateStore.swift 中 ~190 行），只保留 `windows` 宽表作为唯一数据源
- 重复方法：`clearToggleState`（Bindings.swift）和 `clearToggleRecord`（ToggleRecord.swift）做相同的事 → 删除前者，统一用 `clearToggleRecord`
- 日志：将 `shouldRestoreCurrentWindow`、`restore`、`toggle` 中的 debug 级别冗余日志删除，保留 info/warn/error

**Tech Stack:** Swift 5.9, SQLite3

**Scope:** Small
**Risk:** Low（只删除，不改行为）

**Risks:**
- `window_states` 表可能有外部工具查询 → 缓解：该表是内部实现细节，无外部消费者
- 删除日志可能影响后续调试 → 缓解：只删 debug 级别，保留 info/warn/error
- `clearToggleState` 可能被其他地方调用 → 缓解：已 grep 确认只有 SessionWindowRegistry 调用

**Autonomy Level:** Full

**Safety Net:** `swift build` 编译验证 — 删除死代码不会引入新行为，编译通过即安全

**Before/After:**
- Before: 2 个 SQLite 表（`window_states` + `windows`），3 个 clear 方法，~50 行冗余日志
- After: 1 个 SQLite 表（`windows`），1 个 clear 方法，日志只保留关键路径

---

### Task 1: 删除 `window_states` 表全链路死代码

**Depends on:** None
**Files:**
- Delete: `Sources/Window/WindowManager+State.swift`（整个文件，唯一方法 `loadSavedWindowStates()` 无调用者）
- Modify: `Sources/Window/WindowStateStore.swift`（删除 `saveState`, `loadStates`, `deleteState`, `deleteAllStates`, `findState`, `findStateByApp`, `findStateByPID`, `evictStatesOlderThan`, `cleanupStaleStates`, `statesCount` — 约 190 行）
- Modify: `Sources/Window/WindowStateStore+Database.swift`（删除 `window_states` 建表语句和 `cleanupLegacyTables` 方法）
- Modify: `Sources/Window/WindowManager.swift`（删除 `SavedWindowState` struct 和 `ScriptWindowSnapshot` struct，更新 `cleanupStaleStatesWithGracePeriod`）

- [ ] **Step 1: 删除 `WindowManager+State.swift` 文件**

该文件只包含一个方法 `loadSavedWindowStates()`，grep 确认无任何调用者。

Run: `rm Sources/Window/WindowManager+State.swift`

- [ ] **Step 2: 清理 `WindowStateStore.swift` — 删除 `window_states` 表全部方法**

文件: `Sources/Window/WindowStateStore.swift`

删除以下方法（第 22-212 行，只保留 class 定义、init、db/dbPath 属性）：
- `saveState(_ state: WindowManager.SavedWindowState)`
- `loadStates() -> [WindowManager.SavedWindowState]`
- `deleteState(id: String)`
- `deleteAllStates()`
- `findState(windowID:sessionID:)`
- `findStateByApp(appName:sessionID:)`
- `findStateByPID(pid:sessionID:)`
- `evictStatesOlderThan(maxAge:)`
- `cleanupStaleStates(existingWindowIDs:gracePeriod:)`
- `statesCount` property

保留：
- class 声明 + `shared` singleton
- `db`, `dbPath` 属性
- `init()` (但删除 `cleanupLegacyTables()` 调用)

替换后的文件：

```swift
import Foundation
import Csqlite3

@MainActor
final class WindowStateStore {
    static let shared = WindowStateStore()

    var db: OpaquePointer?
    let dbPath: String

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        dbPath = (dir as NSString).appendingPathComponent("vibefocus.db")
        openDatabase()
        createTables()
    }
}
```

- [ ] **Step 3: 清理 `WindowStateStore+Database.swift` — 删除 `window_states` 建表和清理**

文件: `Sources/Window/WindowStateStore+Database.swift`

删除 `createTables()` 中的 `window_states` 建表语句（第 34-46 行）。
删除 `cleanupLegacyTables()` 方法（第 196-211 行）。

修改后的 `createTables()`：

```swift
    func createTables() {
        // windows 宽表：统一会话绑定 + toggle 状态
        runSchema("""
            CREATE TABLE IF NOT EXISTS windows (
                window_id INTEGER NOT NULL PRIMARY KEY,
                pid INTEGER NOT NULL,
                tty TEXT NOT NULL DEFAULT '',
                ax_window_number INTEGER,
                app_name TEXT,
                bundle_id TEXT,
                title TEXT,
                term_session_id TEXT,
                iterm_session_id TEXT,
                kitty_window_id TEXT,
                wezterm_pane TEXT,
                env_window_id TEXT,
                session_id TEXT,
                cwd TEXT,
                model TEXT,
                orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                source_space INTEGER,
                source_display INTEGER,
                source_yabai_disp INTEGER,
                source_disp_space INTEGER,
                target_display INTEGER,
                toggle_reason TEXT,
                toggled_at REAL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            );
            """)
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_session_id ON windows(session_id);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_pid_tty ON windows(pid, tty);")
        runSchema("CREATE INDEX IF NOT EXISTS idx_windows_last_seen ON windows(updated_at);")
        if !columnExists(table: "windows", column: "completed_at") {
            runSchema("ALTER TABLE windows ADD COLUMN completed_at REAL;")
        }
        migrateWindowsPKIfNeeded()
        log("[WindowStateStore] tables created/verified")
    }
```

删除整个 `cleanupLegacyTables()` 方法。

- [ ] **Step 4: 清理 `WindowManager.swift` — 删除死 struct 和清理逻辑**

文件: `Sources/Window/WindowManager.swift`

删除 `SavedWindowState` struct（第 48-68 行）。
删除 `ScriptWindowSnapshot` struct（第 70-82 行）。
删除 `cleanupStaleStatesWithGracePeriod()` 方法（第 88-101 行）。
修改 `init()` 删除 cleanup 调用。

替换后的 init：

```swift
    init() {}
```

- [ ] **Step 5: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 2: 删除重复的 `clearToggleState` 方法

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowStateStore+Bindings.swift`（删除 `clearToggleState` 方法）
- Modify: `Sources/Hook/SessionWindowRegistry.swift`（删除 `clearToggleState` 转发方法）

- [ ] **Step 1: 删除 `WindowStateStore+Bindings.swift` 中的 `clearToggleState`**

文件: `Sources/Window/WindowStateStore+Bindings.swift:139-160`

删除整个 `clearToggleState(windowID:)` 方法。`clearToggleRecord(windowID:)` 在 `WindowStateStore+ToggleRecord.swift` 中做完全相同的事情。

- [ ] **Step 2: 删除 `SessionWindowRegistry.swift` 中的 `clearToggleState` 转发**

文件: `Sources/Hook/SessionWindowRegistry.swift`

找到 `clearToggleState` 方法并删除。如果它的调用者存在，改为调用 `ToggleEngine.shared.clear(windowID:)` 或 `WindowStateStore.shared.clearToggleRecord(windowID:)`。

先 grep 确认调用者：
Run: `grep -rn "clearToggleState" Sources/ --include="*.swift"`

根据 grep 结果决定替换方案。

- [ ] **Step 3: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 3: 精简冗余日志

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift`
- Modify: `Sources/Window/WindowManager+Restore.swift`
- Modify: `Sources/Toggle/ToggleEngine.swift`

原则：
- 删除 `.debug` 级别的"开始/完成/分支"日志 — 它们记录了控制流但无调试价值
- 保留 `.info` 级别的关键决策日志（如 "toggle branching to restore"）
- 保留所有 `.warn` 和 `.error` 日志
- 保留 `CrashContextRecorder` 调用（用于崩溃诊断）

- [ ] **Step 1: 精简 `WindowManager+Toggle.swift` 日志**

文件: `Sources/Window/WindowManager+Toggle.swift`

删除以下 debug 日志：
- 第 52-53 行：`"toggle shouldRestoreCurrentWindow returned"` — 下一行 decision log 已包含
- 第 83-86 行：`"toggle branching to restore"` — decision log 已包含
- 第 113-116 行：`"toggle branching to moveToMainScreen"` — decision log 已包含
- 第 128-131 行：`"toggle branch completed, checking frontmost app"` — 无调试价值
- 第 159-166 行：`"toggle checking slow threshold"` — crash recorder 已覆盖
- 第 353-356 行：`"shouldRestoreCurrentWindow called"` — 方法名已表明

保留所有 `.info` 和 `.warn` 级别的日志。保留 crash recorder 调用。

- [ ] **Step 2: 精简 `WindowManager+Restore.swift` 日志**

文件: `Sources/Window/WindowManager+Restore.swift`

删除无价值的 debug 日志：
- `"restore: record already cleared"` — 正常流程，不需要记录

保留所有 info/warn/error 日志和 crash recorder。

- [ ] **Step 3: 精简 `ToggleEngine.swift` 日志**

文件: `Sources/Toggle/ToggleEngine.swift`

删除过度详细的 coordinate context 日志（第 126-134 行）— 已被 restore 的 origFrame 验证日志覆盖。
删除 `"restore: coordinate context"` 日志块。

保留所有 info/warn/error 日志。

- [ ] **Step 4: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 4: 验证 + 提交

**Depends on:** Task 3
**Files:** None (verification only)

- [ ] **Step 1: 全量编译验证**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: 确认改动范围**

Run: `git diff --stat`
Expected:
  - 删除行数 > 新增行数（净减少代码）
  - 涉及文件 ≤ 9 个
  - 无新增文件

- [ ] **Step 3: 提交**

Run: `git add -A && git commit -m "refactor: remove dead window_states table, deduplicate clear methods, trim verbose logging

Remove ~250 lines of dead code:
- window_states table + SavedWindowState struct (no callers)
- WindowManager+State.swift (entire file, only method unused)
- Duplicate clearToggleState in Bindings.swift (identical to clearToggleRecord)
- SessionWindowRegistry.clearToggleState forwarding method
- ScriptWindowSnapshot struct (unused)
- Debug-level logs that duplicate information from nearby info/warn logs"`

