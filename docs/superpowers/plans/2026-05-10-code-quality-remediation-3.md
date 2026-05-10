# Code Quality Remediation Round 3 — Log Noise, Silent Failures, Magic Numbers

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 三轮审计剩余问题：清理 moveWindowToMainScreen 和高频文件的 debug 日志噪音、修复数据库层静默 guard 失败、提取魔法数字为命名常量。

**Architecture:** 三个独立修复：moveWindowToMainScreen 10 条 debug 日志精简为关键节点日志 → WindowStateStore 20+ 个静默 guard 添加日志 → WindowManager 魔法数字提取为常量。每个 Task 独立编译验证。

**Tech Stack:** Swift 5.9, macOS 13+

**Risks:**
- Task 1 日志精简不会删除 error/warn 级别日志，只删除 debug 步骤叙述 → 低风险
- Task 2 数据库层 guard 只添加日志不改变逻辑 → 零风险

---

### Task 1: 精简 moveWindowToMainScreen debug 日志噪音 — 从 10 条减至 2 条

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift:80-441`

`moveWindowToMainScreen` 有 10 条 `.debug` 日志，详细叙述每一步（"AX permission OK"、"resolved window AX element"、"read current frame"、"checking if window already on main screen"、"got window handle, checking settable attributes"、"computed target frame"、"calling apply()"、"apply() returned"、"move succeeded, capturing state"）。这些步骤叙述在生产日志中制造大量噪音，对调试帮助有限（关键失败点已有 error/warn 日志）。保留入口和出口日志，删除中间步骤叙述。

- [ ] **Step 1: 删除 moveWindowToMainScreen 中的步骤叙述 debug 日志**

在 `Sources/WindowManager+MoveWindow.swift` 中，删除以下 8 个 debug 日志块（保留入口日志 `moveWindowToMainScreen started` 和出口日志 `moveWindowToMainScreen finished`）：

删除块 1（~line 112-120）：`"[moveWindowToMainScreen] AX permission OK, resolving window"`

删除块 2（~line 133-140）：`"[moveWindowToMainScreen] resolved window AX element"`

删除块 3（~line 153-160）：`"[moveWindowToMainScreen] read current frame"`

删除块 4（~line 165-169）：`"[moveWindowToMainScreen] checking if window already on main screen"`

删除块 5（~line 199-203）：`"[moveWindowToMainScreen] window not on main screen, getting window handle"`

删除块 6（~line 247-256）：`"[moveWindowToMainScreen] got window handle, checking settable attributes"`

删除块 7（~line 284-293）：`"[moveWindowToMainScreen] computed target frame and display"`

删除块 8（~line 297-313）：`"[moveWindowToMainScreen] calling apply() to set frame"` + `"[moveWindowToMainScreen] apply() returned"`

删除块 9（~line 353-361）：`"[moveWindowToMainScreen] move succeeded, capturing state for persistence"`

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowManager+MoveWindow.swift && git commit -m "refactor(move-window): remove step-narration debug logs from moveWindowToMainScreen"`

---

### Task 2: 修复 WindowStateStore 静默 guard 失败 — 添加数据库操作日志

**Depends on:** None
**Files:**
- Modify: `Sources/WindowStateStore.swift`
- Modify: `Sources/WindowStateStore+Bindings.swift`

WindowStateStore 有 20+ 个 `guard let db else { return }` / `guard sqlite3_prepare_v2(...) == SQLITE_OK else { return }` 模式，全部静默返回。数据库操作失败时没有任何日志，使问题无法追踪。

修复策略：在关键的 `guard` 失败点添加一行 `log()` 调用。不改变任何返回值或逻辑。

- [ ] **Step 1: 在 WindowStateStore.swift 的关键方法中添加失败日志**

在以下方法中，将 `guard let db else { return }` 改为带日志版本：

`saveState` (~line 27) — `guard let db, let data = try? JSONEncoder().encode(state) else { return }` → 拆分为两个 guard，`db` 失败时 log error

`loadStates` (~line 51) — `guard let db else { return [] }` → 添加 log

`deleteState` (~line 71) — `guard let db else { return }` → 添加 log

`evictStatesOlderThan` (~line 171) — `guard let db else { return 0 }` → 添加 log

`cleanupStaleStates` (~line 183) — `guard let db else { return 0 }` → 添加 log

每个 guard 改为：
```swift
guard let db else {
    log("[WindowStateStore] method_name: db not available", level: .warn)
    return /* original value */
}
```

- [ ] **Step 2: 在 WindowStateStore+Bindings.swift 的关键方法中添加失败日志**

同样模式修复以下方法的 `guard let db else`：

`saveWindowState` (~line 99)

`findWindowState` (~line 165)

`findWindowStateBySession` (~line 178)

`deleteWindowState` (~line 262)

`loadAllWindowStates` (~line 246)

每个改为：
```swift
guard let db else {
    log("[WindowStateStore] method_name: db not available", level: .warn)
    return /* original value */
}
```

- [ ] **Step 3: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/WindowStateStore.swift Sources/WindowStateStore+Bindings.swift && git commit -m "fix(storage): add warn logs to WindowStateStore silent guard failures"`

---

### Task 3: 提取魔法数字为命名常量 — 改善可读性

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+MoveWindow.swift:330`
- Modify: `Sources/WindowManager+MoveWindow.swift:473`
- Modify: `Sources/WindowManager.swift:27`

- [ ] **Step 1: 在 WindowManager+MoveWindow.swift 提取超时常量**
文件: `Sources/WindowManager+MoveWindow.swift:330`

替换前：
```swift
                timeout: 80_000,
```

替换后：
```swift
                timeout: Self.cgPollTimeoutMs,
```

在 `WindowManager+MoveWindow.swift` 的 extension 开头（class 方法区域前）添加常量：
```swift
    private static let cgPollTimeoutMs: Int = 80_000
    private static let heightTolerance: CGFloat = 100
```

文件: `Sources/WindowManager+MoveWindow.swift:473` — 同文件中 `height` 容差魔法数字：

替换前：
```swift
                           abs(actualFrame.height - targetFrame.height) <= 100
```

替换后：
```swift
                           abs(actualFrame.height - targetFrame.height) <= Self.heightTolerance
```

- [ ] **Step 2: 验证编译**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/WindowManager+MoveWindow.swift && git commit -m "refactor(move-window): extract magic numbers to named constants"`

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks |
| 2 | Dependencies? | PASS | 3 个 Task 全部独立 |
| 3 | File paths? | PASS | 精确到行号和函数名 |
| 4 | 3-8 Steps/Task? | PASS | Task 1: 3, Task 2: 4, Task 3: 3 |
| 5 | New file complete code? | N/A | 无新文件 |
| 6 | Modify complete function? | PASS | 标注了文件:行号 + 替换模式 |
| 7 | Code block size? | PASS | 最大 ~5 行 |
| 8 | No dangling references? | PASS | 所有引用均存在 |
| 9 | Validation commands? | PASS | 每个 Task 有 swift build |
| 10 | Coverage complete? | PASS | 覆盖日志/静默失败/魔法数字 |
| 11 | Independent verification? | PASS | 每个 Task 独立编译 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 所有 Step 有具体代码 |
| 14 | Cross-task consistency? | PASS | 无跨 Task 引用 |
| 15 | Save location? | PASS | docs/superpowers/plans/ |

**Status:** ✅ ALL PASS

---

## Execution Selection

**Tasks:** 3
**Dependencies:** 无
**User Preference:** none
**Decision:** Inline
**Reasoning:** 3 个 Task 修改量小且全部独立，inline 执行更快

**Auto-invoking:** 直接执行
