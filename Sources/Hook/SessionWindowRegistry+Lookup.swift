// SessionWindowRegistry+Lookup.swift
// VibeFocus — Session 窗口绑定查找与 UI 支持
// 从 SessionWindowRegistry.swift 中提取

import Foundation

@MainActor
extension SessionWindowRegistry {

    // MARK: - Lookup

    /// 按 sessionID 查找窗口状态（扫描，低频操作）
    /// 优先返回 PID 有效的绑定，避免返回损坏数据
    func binding(for sessionID: String) -> WindowState? {
        // P-INST-158: sessionID→窗口绑定查找耗时（内存 windowStates.values.filter 扫描 + alias 查 + DB fallback findWindowStateBySession P-INST-68 + 损坏绑定 deleteWindowState；hook UserPromptSubmit/Stop/SessionEnd 路径主查找）。
        #if PERF_INSTRUMENT
        let bfsStart = Date()
        defer {
            log("[SessionWindowRegistry] binding(for:) finished", level: .debug, fields: [
                "sessionID": sessionID,
                "durationMs": String(elapsedMilliseconds(since: bfsStart))
            ])
        }
        #endif
        // 1. Direct lookup: binding has this sessionID
        let candidates = windowStates.values.filter { $0.sessionID == sessionID }
        if let valid = candidates.first(where: { TerminalRegistry.isTerminalPID($0.pid) }) {
            return valid
        }
        if let first = candidates.first {
            return first
        }

        // 2. Alias lookup: session shares a window with another session
        if let aliasWindowID = sessionAliasWindowID[sessionID],
           let state = windowStates[aliasWindowID] {
            log("[SessionWindowRegistry] binding(for:) resolved via alias", fields: [
                "sessionID": sessionID,
                "windowID": String(aliasWindowID),
                "boundSessionID": String(state.sessionID?.prefix(8) ?? "nil")
            ])
            return state
        }

        // 3. DB fallback
        if let state = store.findWindowStateBySession(sessionID: sessionID) {
            if !TerminalRegistry.isTerminalPID(state.pid) {
                log("[SessionWindowRegistry] binding(for:) loaded corrupt binding from DB, cleaning up", level: .warn, fields: [
                    "windowID": String(state.windowID),
                    "pid": String(state.pid),
                    "sessionID": sessionID
                ])
                store.deleteWindowState(windowID: state.windowID)
                return nil
            }
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    /// 按 windowID 查找窗口状态（O(1)，主查找路径）
    func findState(windowID: UInt32) -> WindowState? {
        // P-INST-159: windowID→窗口状态查找耗时（内存 O(1) windowStates 查 + DB fallback findWindowState P-INST-68；hook/restore 按 windowID 查询主路径，缓存命中应 <1ms）。
        #if PERF_INSTRUMENT
        let fswStart = Date()
        defer {
            log("[SessionWindowRegistry] findState finished", level: .debug, fields: [
                "windowID": String(windowID),
                "durationMs": String(elapsedMilliseconds(since: fswStart))
            ])
        }
        #endif
        if let state = windowStates[windowID] {
            return state
        }
        if let state = store.findWindowState(windowID: windowID) {
            windowStates[state.windowID] = state
            return state
        }
        return nil
    }

    // MARK: - UI Support

    /// B160：窗口是否有活跃（未结束）会话绑定——输入气泡聚焦自动弹出的闸门。
    /// 绑定随 hook（SessionStart/UPS）写入、随会话结束置 completed，天然反映「这窗在跑 Claude」。
    /// 内存未命中回落 DB（findWindowStateByWindowID）：app 重启后增量绑定不丢、外部写库即时生效。
    /// B247：DB 未命中/命中但无活跃绑定进负缓存（TTL 内不重复触 DB）——生产 tick
    /// 每秒对无绑定窗打一次主线程 SQLite 已实测崩过进程（2026-09-19 SIGSEGV）。TTL
    /// 只作用于「查无活跃绑定」的结论：外部新写/翻活的绑定最迟 TTL+1 拍生效（生产
    /// 绑定走 hook 进内存不受影响）；正命中（活跃）不缓存，completed 翻转下次查询可见。
    /// B250：「活跃绑定」必须 sessionID ≠ nil——windows 表同存 toggle 落账行
    /// （saveToggleRecord 兜底 INSERT：session_id=NULL、is_completed=0，任何被 ⌃Q 过
    /// 的窗都有），只看 isCompleted 会把这类行误判成活跃会话=绑定门恒真（B212 的
    /// 「userAction 挂会话才弹」自失效，无会话窗每次拉回都误弹=B211 主诉借尸还魂；
    /// 真机 E2E 12:00 实锤：UPS 绑定失败仍 summon，吃到的正是上一拍的 toggle 假行）。
    /// 内存路径同理：init 的 loadAllWindowStates 也把 toggle-only 行装进 windowStates。
    /// - Parameters:
    ///   - missCacheTTL: 未命中缓存有效期（测试注入小值做边界）。
    func hasLiveSessionBinding(
        windowID: UInt32,
        now: Date = Date(),
        missCacheTTL: TimeInterval = 5.0
    ) -> Bool {
        if let state = windowStates[windowID] {
            return state.sessionID != nil && !state.isCompleted
        }
        if let lastMiss = bindingLookupMissCache[windowID],
           now.timeIntervalSince(lastMiss) < missCacheTTL {
            return false
        }
        guard let state = store.findWindowStateByWindowID(windowID) else {
            recordBindingLookupMiss(windowID: windowID, at: now)
            return false
        }
        if state.sessionID == nil || state.isCompleted {
            recordBindingLookupMiss(windowID: windowID, at: now)
            return false
        }
        bindingLookupMissCache.removeValue(forKey: windowID)
        bindingLookupMissOrder.removeAll { $0 == windowID }
        return true
    }

    /// B247：落负缓存（容量 64 FIFO 淘汰，与 B184 基线表同款守恒模式）。
    private func recordBindingLookupMiss(windowID: UInt32, at: Date) {
        if bindingLookupMissCache[windowID] == nil {
            bindingLookupMissOrder.append(windowID)
            while bindingLookupMissOrder.count > 64 {
                let evict = bindingLookupMissOrder.removeFirst()
                bindingLookupMissCache.removeValue(forKey: evict)
            }
        }
        bindingLookupMissCache[windowID] = at
    }

    var activeBindingsForUI: [WindowState] {
        // B250：sessionID ≠ nil 过滤——内存表混有 toggle 落账行（session_id=NULL、
        // is_completed=0），不过滤会在设置页会话面板以「活跃会话」幽灵行出现。
        windowStates.values
            .filter { $0.sessionID != nil && !$0.isCompleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var recentCompletedBindings: [WindowState] {
        let now = Date()
        return windowStates.values
            .filter { $0.sessionID != nil && $0.isCompleted && $0.updatedAt.addingTimeInterval(30 * 60) > now }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
