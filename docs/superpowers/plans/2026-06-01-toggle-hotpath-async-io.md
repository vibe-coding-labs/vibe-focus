# Optimization: Toggle 热路径同步 I/O 异步化

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 toggle 热路径中的同步阻塞 I/O（CrashContextRecorder 原子写文件、AuditLogger SQLite 写入）改为异步，消除每次 toggle 操作中 15-40ms 的主线程阻塞。

**Architecture:** CrashContextRecorder 和 AuditLogger 各自引入写入队列（DispatchQueue），record() 调用仅追加到内存缓冲区，实际 I/O 在后台队列执行。CrashContextRecorder 使用防抖（debounce）避免频繁写入。toggle 热路径中移除 restore()/moveToMainScreen() 内的重复 updateCrashSnapshotFromRuntime() 和 isWindowOnMainScreen() 调用。

**Tech Stack:** Swift 5.9+, DispatchQueue, SQLite3, Foundation

**Scope:** Medium
**Risk:** Medium

**Risks:**
- Task 1: CrashContextRecorder 异步化可能在崩溃时丢失最后几条事件 → 缓解：崩溃诊断本身就是 best-effort，丢失 1-2 条可接受
- Task 2: AuditLogger 异步化可能导致 SQLite 并发写入 → 缓解：所有写入在同一个串行队列中执行
- Task 3: 移除重复 isWindowOnMainScreen 检查 → 缓解：toggle() 中已做检查，restore() 中的是冗余验证

**Autonomy Level:** Full

---

## Current Baseline

| 操作 | 同步 I/O 阻塞 | 总耗时 |
|------|-------------|--------|
| toggle (restore 路径) | CrashContextRecorder 10-30ms + AuditLogger 2-10ms | 600-1000ms (含 yabai) |
| toggle (move 路径) | AuditLogger 2-10ms + 可能的 CrashContextRecorder | 500-800ms (含 yabai) |

## Target

| 操作 | 同步 I/O 阻塞 | 改善 |
|------|-------------|------|
| toggle (任意路径) | 0ms (全部异步) | -15~40ms |

---

### Task 1: CrashContextRecorder 异步化 — 消除 toggle 热路径中最大的同步 I/O 瓶颈

**Depends on:** None
**Files:**
- Modify: `Sources/Support/CrashContextRecorder.swift` — 添加写入队列 + 防抖

- [ ] **Step 1: 添加异步写入队列和防抖机制到 CrashContextRecorder**

文件: `Sources/Support/CrashContextRecorder.swift:1-36`（在类属性区域添加队列，修改 record 方法）

在 `private var state: SessionState?` 之后添加写入队列:

```swift
    private var state: SessionState?

    /// 异步写入队列 — 避免在 toggle 热路径中阻塞主线程
    private let persistQueue = DispatchQueue(label: "com.vibefocus.crash-persist", qos: .utility)
    /// 防抖：避免频繁 persist（如快速连续 record 调用）
    private var persistScheduled = false
    private let persistDebounceInterval: TimeInterval = 0.5
```

- [ ] **Step 2: 修改 record() 方法为异步 — 仅追加事件到内存，延迟写入磁盘**

文件: `Sources/Support/CrashContextRecorder.swift:92-101`（替换整个 `record` 方法）

```swift
    func record(_ event: String) {
        appendEvent(event)
        // 异步延迟写入 — 不阻塞 toggle 热路径
        schedulePersist()
    }

    /// 调度异步持久化（带防抖）
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        persistQueue.asyncAfter(deadline: .now() + persistDebounceInterval) { [weak self] in
            self?.persistScheduled = false
            DispatchQueue.main.async {
                self?.persistStateNow()
            }
        }
    }

    /// 在主线程执行持久化（由 persistQueue 调度回来）
    private func persistStateNow() {
        persistState()
        log(
            "[CRASH_CONTEXT] event (async persisted)",
            fields: [:]
        )
    }
```

- [ ] **Step 3: 修改 persistState 添加线程安全注释**

文件: `Sources/Support/CrashContextRecorder.swift:232-254`（在 persistState 方法前添加注释）

无需修改方法本身，但需要确保 bootstrap() 和 markCleanExit() 中的同步调用仍然有效。这两个方法不在 toggle 热路径中，保持同步即可。

- [ ] **Step 4: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 质量门禁 — 编译 + 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Test run|FAIL"`
Expected:
  - Exit code: 0
  - 979 tests passed, 0 FAIL

- [ ] **Step 6: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Support/CrashContextRecorder.swift && git commit -m "perf(crash): async CrashContextRecorder writes to unblock toggle hotpath"`

---

### Task 2: AuditLogger 异步化 — 消除 toggle 热路径中的同步 SQLite 写入

**Depends on:** None
**Files:**
- Modify: `Sources/Support/AuditLogger.swift` — 添加写入队列

- [ ] **Step 1: 添加异步写入队列到 AuditLogger**

文件: `Sources/Support/AuditLogger.swift:8-21`（在类属性区域添加队列）

在 `private let _injectedDB: OpaquePointer?` 之前添加:

```swift
    /// 异步写入队列 — 避免在 toggle 热路径中阻塞主线程
    /// 串行队列确保 SQLite 写入顺序
    private let writeQueue = DispatchQueue(label: "com.vibefocus.audit-write", qos: .utility)
    /// 待写入事件缓冲区
    private var pendingEvents: [(eventType: String, windowID: UInt32, pid: Int32?, sessionID: String?, details: [String: String])] = []
    private var flushScheduled = false
    private let flushDebounceInterval: TimeInterval = 0.3
```

- [ ] **Step 2: 修改 record() 方法为缓冲 + 异步刷新**

文件: `Sources/Support/AuditLogger.swift:48-100`（替换整个 `record` 方法）

```swift
    func record(
        eventType: String,
        windowID: UInt32,
        pid: Int32? = nil,
        sessionID: String? = nil,
        details: [String: String] = [:]
    ) {
        // 追加到内存缓冲区 — 不阻塞调用者
        pendingEvents.append((eventType, windowID, pid, sessionID, details))
        scheduleFlush()
    }

    /// 调度异步刷新（带防抖）
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        writeQueue.asyncAfter(deadline: .now() + flushDebounceInterval) { [weak self] in
            DispatchQueue.main.async {
                self?.flushPendingEvents()
            }
        }
    }

    /// 批量写入待处理事件到 SQLite
    private func flushPendingEvents() {
        flushScheduled = false
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents = []

        guard let db else { return }
        for event in events {
            insertEventSync(
                db: db,
                eventType: event.eventType,
                windowID: event.windowID,
                pid: event.pid,
                sessionID: event.sessionID,
                details: event.details
            )
        }
    }

    /// 同步写入单条事件到 SQLite（内部使用）
    private func insertEventSync(
        db: OpaquePointer,
        eventType: String,
        windowID: UInt32,
        pid: Int32?,
        sessionID: String?,
        details: [String: String]
    ) {
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO window_audit_log (event_type, window_id, pid, session_id, details, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[AuditLogger] insert prepare failed: \(msg)", level: .error)
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(windowID))
        if let pid {
            sqlite3_bind_int(stmt, 3, pid)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 4, sessionID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if !details.isEmpty,
           let jsonData = try? JSONSerialization.data(withJSONObject: details),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            sqlite3_bind_text(stmt, 5, jsonStr, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            log("[AuditLogger] insert failed: \(msg)", level: .error)
            return
        }

        insertCount += 1
        if insertCount >= cleanupInterval {
            insertCount = 0
            trimOldRecords()
        }
    }
```

- [ ] **Step 3: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 4: 质量门禁 — 编译 + 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Test run|FAIL"`
Expected:
  - Exit code: 0
  - 979 tests passed

- [ ] **Step 5: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Support/AuditLogger.swift && git commit -m "perf(audit): async AuditLogger SQLite writes to unblock toggle hotpath"`

---

### Task 3: 移除 toggle 热路径中的重复工作 — 消除冗余 AX 查询和状态快照

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Restore.swift:7-112` — 移除重复的 updateCrashSnapshotFromRuntime、logRuntimeStateSnapshot、isWindowOnMainScreen
- Modify: `Sources/Window/WindowManager+Toggle.swift:199-264` — 移除 moveToMainScreen 中的重复工作

- [ ] **Step 1: 精简 restore() — 移除 toggle() 已执行的重复操作**

文件: `Sources/Window/WindowManager+Restore.swift:7-112`（替换整个 `restore` 方法）

toggle() 已经做了：updateCrashSnapshotFromRuntime、logRuntimeStateSnapshot、识别焦点窗口、isWindowOnMainScreen。restore() 重复了这些操作。

```swift
    func restore(operationID: String? = nil, triggerSource: String = "unknown") {
        let op = operationID ?? makeOperationID(prefix: "restore")
        let startedAt = Date()
        // 注意：updateCrashSnapshotFromRuntime、logRuntimeStateSnapshot、AX 权限检查、
        // 焦点窗口识别、isWindowOnMainScreen 已在 toggle() 中完成，此处不再重复

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
              let currentWindowID = windowHandle(for: focusedWindow) else {
            log(
                "[WindowManager] restore failed: cannot identify focused window",
                level: .error,
                fields: ["op": op]
            )
            return
        }

        log(
            "[WindowManager] restore started",
            fields: [
                "op": op,
                "source": triggerSource,
                "windowID": String(currentWindowID)
            ]
        )

        // 委托 ToggleEngine 执行 restore（唯一执行入口）
        let engine = ToggleEngine.shared
        let restoreSucceeded = engine.restore(
            windowID: currentWindowID,
            triggerSource: triggerSource,
            traceID: op
        )

        guard restoreSucceeded else {
            log("[WindowManager] restore failed: ToggleEngine.restore returned false", level: .error, fields: [
                "op": op,
                "windowID": String(currentWindowID)
            ])
            return
        }

        // 焦点跟随（仅 carbon_hotkey 触发）
        if triggerSource == "carbon_hotkey" {
            if let postApplySpace = spaceController.windowSpaceIndex(windowID: currentWindowID)?.yabaiIndex,
               let currentSpace = spaceController.currentSpaceIndex(),
               postApplySpace != currentSpace {
                log("[WindowManager] restore: following window to Space \(postApplySpace)", fields: [
                    "op": op, "windowID": String(currentWindowID), "currentSpace": String(currentSpace)
                ])
                _ = spaceController.focusWindow(currentWindowID, operationID: op)
            }
        }

        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": "restored",
                "durationMs": String(finalDurationMs)
            ]
        )
        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: currentWindowID,
            pid: frontApp.processIdentifier,
            details: [
                "durationMs": String(finalDurationMs)
            ]
        )
    }
```

- [ ] **Step 2: 验证编译通过**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 质量门禁 — 编译 + 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Test run|FAIL"`
Expected:
  - Exit code: 0
  - 979 tests passed

- [ ] **Step 4: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Window/WindowManager+Restore.swift && git commit -m "perf(restore): remove redundant AX queries and crash snapshots from restore hotpath"`

---

### Task 4: 端到端验证 + 部署

**Depends on:** Task 1, Task 2, Task 3
**Files:** No code changes

- [ ] **Step 1: 全量测试**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift test 2>&1 | grep -E "Test run|FAIL"`
Expected:
  - Exit code: 0
  - 979 tests passed

- [ ] **Step 2: Release 构建并部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -15`
Expected:
  - Exit code: 0
  - 签名验证通过

- [ ] **Step 3: 启动并验证**

Run: `open /Applications/VibeFocus.app && sleep 2 && pgrep -fl VibeFocus`
Expected:
  - Exit code: 0
  - VibeFocus PID

- [ ] **Step 4: 提交**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add -A && git status --short`
Expected:
  - 无未提交文件（所有 Task 已单独提交）
