# Fix: UserPromptSubmit 自动恢复窗口失败

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复回车提交提示词后窗口无法从主屏幕切换回副屏幕原来位置的问题。根因：toggle 操作保存的 saved state 的 windowID 与 session binding 的 windowID 不一致，且 saved state 没有关联 sessionID，导致 UserPromptSubmit 查找时无法匹配。

**Architecture:** UserPromptSubmit 收到 hook → 获取 session binding → 用 binding 的 PID+appName 在 SQLite 中查找 saved state（而非只用 windowID） → 找到后执行 restore。核心变更：查找逻辑从"精确 windowID 匹配"改为"PID+appName+sessionID 多级匹配"，覆盖 toggle 保存的窗口和 binding 窗口不同的情况。

**Tech Stack:** Swift 5.9, macOS 13+, SQLite (via Csqlite3)

**Risks:**
- 按 PID+appName 查找可能匹配到同 app 的其他窗口 → 缓解：优先按 windowID 精确匹配，PID+appName 作为 fallback
- 多个 saved state 同 PID+appName 时可能恢复错误状态 → 缓解：优先选最近保存的 state，且要求窗口确实在主屏幕上

---

### Task 1: 修复 UserPromptSubmit 查找逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/HookEventHandler.swift:214-267`（替换 handleUserPromptSubmit 中 saved state 查找逻辑）

- [ ] **Step 1: 修改 handleUserPromptSubmit 的 saved state 查找逻辑 — 增加 PID+appName 多级匹配**

文件: `Sources/HookEventHandler.swift:214-267`（替换从 "优先级 1" 注释到函数末尾的查找逻辑）

```swift
        // === 多级匹配策略 ===
        // 问题：toggle 保存的 saved state 的 windowID 可能与 session binding 的 windowID 不同
        // （toggle 移动的是焦点窗口，binding 绑定的是 SessionStart 时的窗口）
        // 解决：从精确匹配逐步降级到模糊匹配

        // 优先级 1: windowID 精确匹配（同 session）
        if isOnMain {
            if let matchedState = store.findState(windowID: targetWindowID, sessionID: payload.sessionID) {
                if !wm.isSavedStateCorrupted(matchedState) {
                    return performRestore(
                        payload: payload, matchedState: matchedState,
                        matchLevel: "exact_windowid_session_scoped"
                    )
                } else {
                    wm.clearSavedWindowState(id: matchedState.id)
                }
            }
        }

        // 优先级 2: windowID 精确匹配（任意 session）— 同一个窗口可能被不同 session 的 toggle 保存过
        if isOnMain {
            if let matchedState = store.findState(windowID: targetWindowID, sessionID: nil) {
                if !wm.isSavedStateCorrupted(matchedState) {
                    return performRestore(
                        payload: payload, matchedState: matchedState,
                        matchLevel: "exact_windowid_any_session"
                    )
                } else {
                    wm.clearSavedWindowState(id: matchedState.id)
                }
            }
        }

        // 优先级 3: PID + appName 匹配（同 session）
        // toggle 保存的窗口可能和 binding 的窗口不同（同 app 不同窗口 ID）
        if isOnMain {
            if let matchedState = store.findStateByPID(
                pid: targetPID,
                sessionID: payload.sessionID
            ) {
                if !wm.isSavedStateCorrupted(matchedState) {
                    return performRestore(
                        payload: payload, matchedState: matchedState,
                        matchLevel: "pid_appname_session_scoped"
                    )
                } else {
                    wm.clearSavedWindowState(id: matchedState.id)
                }
            }
        }

        // 优先级 4: PID + appName 匹配（任意 session）
        if isOnMain {
            if let matchedState = store.findStateByPID(
                pid: targetPID,
                sessionID: nil
            ) {
                if !wm.isSavedStateCorrupted(matchedState) {
                    return performRestore(
                        payload: payload, matchedState: matchedState,
                        matchLevel: "pid_appname_any_session"
                    )
                } else {
                    wm.clearSavedWindowState(id: matchedState.id)
                }
            }
        }

        // 优先级 5: appName 匹配（同 session）— 终极 fallback
        if isOnMain {
            if let appState = store.findStateByApp(
                appName: identity.appName ?? "",
                sessionID: payload.sessionID
            ) {
                if !wm.isSavedStateCorrupted(appState) {
                    log(
                        "[HookEventHandler] UserPromptSubmit app-name fallback (SQLite)",
                        fields: [
                            "sessionID": payload.sessionID,
                            "stateApp": appState.appName ?? "unknown",
                            "bindingWindowID": String(targetWindowID)
                        ]
                    )
                    return performRestore(
                        payload: payload, matchedState: appState,
                        matchLevel: "appname_session_scoped"
                    )
                }
            }
        }

        // 优先级 6: appName 匹配（任意 session）
        if isOnMain {
            if let appState = store.findStateByApp(
                appName: identity.appName ?? "",
                sessionID: nil
            ) {
                if !wm.isSavedStateCorrupted(appState) {
                    log(
                        "[HookEventHandler] UserPromptSubmit app-name fallback any session (SQLite)",
                        fields: [
                            "sessionID": payload.sessionID,
                            "stateApp": appState.appName ?? "unknown",
                            "bindingWindowID": String(targetWindowID)
                        ]
                    )
                    return performRestore(
                        payload: payload, matchedState: appState,
                        matchLevel: "appname_any_session"
                    )
                }
            }
        }

        log(
            "[HookEventHandler] UserPromptSubmit no matching state in SQLite",
            fields: [
                "sessionID": payload.sessionID,
                "windowOnMainScreen": String(isOnMain),
                "bindingWindowID": String(targetWindowID),
                "bindingPID": String(targetPID),
                "bindingAppName": identity.appName ?? "nil"
            ]
        )
        return (
            200,
            ClaudeHookResponse(
                ok: true, code: "no_action_needed",
                message: "No matching saved state in SQLite",
                sessionID: payload.sessionID, handled: false
            )
        )
```

- [ ] **Step 2: 在 WindowStateStore 中添加 findStateByPID 方法 — 按 PID 查找 saved state**

文件: `Sources/WindowStateStore.swift:197`（在 `findStateByApp` 方法之后插入）

```swift
    func findStateByPID(pid: Int32, sessionID: String?) -> WindowManager.SavedWindowState? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql: String
        if let sessionID, !sessionID.isEmpty {
            sql = "SELECT data FROM window_states WHERE pid = ? AND session_id = ? ORDER BY saved_at DESC LIMIT 1;"
        } else {
            sql = "SELECT data FROM window_states WHERE pid = ? ORDER BY saved_at DESC LIMIT 1;"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int64(pid))
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        let jsonString = String(cString: cStr)
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowManager.SavedWindowState.self, from: data)
    }
```

- [ ] **Step 3: 修改 findStateByApp 以支持 sessionID 为 nil 时的查询 — 确保 fallback 查询正确工作**

文件: `Sources/WindowStateStore.swift:175-197`（验证现有逻辑，无需修改 — 现有代码已正确处理 sessionID 为 nil 的情况）

验证：读取当前 `findStateByApp` 方法，确认当 sessionID 为 nil 时使用不带 session_id 条件的 SQL 查询。

- [ ] **Step 4: 编译验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 5: 部署到本地应用**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/build-and-deploy.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "signed" or "deployed" or similar success indicator

- [ ] **Step 6: 重启 VibeFocus 并验证修复**
Run: `killall VibeFocus 2>/dev/null; sleep 1; open /Users/cc11001100/Applications/VibeFocus.app`
Expected:
  - VibeFocus app launches successfully
  - Log file shows new startup entries

- [ ] **Step 7: 提交**
Run: `git add Sources/HookEventHandler.swift Sources/WindowStateStore.swift && git commit -m "fix(hook): add multi-level matching for UserPromptSubmit restore — PID+appName fallback when windowID mismatch"`
