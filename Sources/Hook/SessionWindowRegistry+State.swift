// SessionWindowRegistry+State.swift
// VibeFocus — Session 窗口状态更新与批量操作
// 从 SessionWindowRegistry.swift 中提取

import Foundation

@MainActor
extension SessionWindowRegistry {

    // MARK: - State Updates

    func markCompleted(sessionID: String) {
        // B253：先取 alias 指向再摘除——alias 会话（同窗共享）结束时靠它定位窗口
        let aliasedWindowID = sessionAliasWindowID[sessionID]
        sessionAliasWindowID.removeValue(forKey: sessionID)
        guard let state = binding(for: sessionID) ?? aliasedWindowID.flatMap({ windowStates[$0] }) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        let wid = state.windowID

        // B253：同窗多会话（远程 SSH 多会话共享同一 iTerm 窗 = 用户真实形态）。
        // 窗口级状态代表「这窗在跑 Claude」（hasLiveSessionBinding/auto-show/绑定门
        // 都消费它），要等最后一个会话结束才落 completed——旧实现先结束的会话会把
        // 仍活跃的共窗会话的窗级信号一起掐死。
        let coTenants = sessionAliasWindowID.filter { $0.value == wid }.map(\.key)

        // 结束的是 alias 共享会话：窗口当前会话≠自己 → 窗口保持活跃，不动状态
        //（剩余会话由它们自己的 SessionEnd 走移交/收尾链）。
        if updated.sessionID != sessionID {
            lastEventDescription = coTenants.isEmpty
                ? "SessionEnd：共享会话结束，窗口直绑会话仍活跃"
                : "SessionEnd：共享会话结束，同窗仍有 \(coTenants.count) 个活跃会话"
            return
        }

        // 结束的是窗口当前会话：还有 alias 共窗会话 → 绑定移交给其中一个
        //（单行 schema 只能记一个 sessionID；移交后其 SessionEnd 才能正确收尾），
        // 其余 alias 保留继续共享。
        if let adopt = coTenants.sorted().first {
            sessionAliasWindowID.removeValue(forKey: adopt)
            updated.sessionID = adopt
            updated.updatedAt = Date()
            windowStates[wid] = updated
            persistToDB(windowID: wid)
            lastEventDescription = "SessionEnd：窗口绑定移交同窗会话 \(adopt.prefix(8))"
            log("[SessionWindowRegistry] markCompleted: binding adopted by co-tenant", fields: [
                "windowID": String(wid),
                "ended": String(sessionID.prefix(8)),
                "adopted": String(adopt.prefix(8)),
                "remainingCoTenants": String(coTenants.count - 1)
            ])
            return
        }

        updated.isCompleted = true
        updated.completedAt = Date()
        updated.updatedAt = Date()
        windowStates[wid] = updated
        lastEventDescription = "SessionEnd 已完成：\(updated.appName ?? "Unknown")"
        persistToDB(windowID: wid)
    }

    func reactivate(sessionID: String) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
    }

    func touch(sessionID: String, message: String? = nil) {
        guard let state = binding(for: sessionID) else { return }
        guard var updated = windowStates[state.windowID] else { return }
        updated.updatedAt = Date()
        windowStates[state.windowID] = updated
        persistToDB(windowID: state.windowID)
        if let message, !message.isEmpty {
            lastEventDescription = message
        }
    }

    func setLastEventDescription(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastEventDescription = message
    }

    /// 将旧 windowID 的绑定重映射到新 windowID（CGWindowNumber 变化时调用）
    func remapWindowID(oldWindowID: UInt32, newWindowID: UInt32) {
        guard oldWindowID != newWindowID else { return }
        guard var state = windowStates[oldWindowID] else {
            // 旧 windowID 不在内存缓存中 — 尝试从 DB 加载
            if let dbState = store.findWindowState(windowID: oldWindowID) {
                var remapped = dbState
                remapped.windowID = newWindowID
                windowStates[newWindowID] = remapped
                persistToDB(windowID: newWindowID)
                store.deleteWindowState(windowID: oldWindowID)
                windowStates.removeValue(forKey: oldWindowID)
                log("[SessionWindowRegistry] remapWindowID: DB remap", fields: [
                    "oldWindowID": String(oldWindowID),
                    "newWindowID": String(newWindowID)
                ])
            }
            return
        }
        state.windowID = newWindowID
        windowStates[newWindowID] = state
        windowStates.removeValue(forKey: oldWindowID)
        store.deleteWindowState(windowID: oldWindowID)
        persistToDB(windowID: newWindowID)
        log("[SessionWindowRegistry] remapWindowID: memory+DB remap", fields: [
            "oldWindowID": String(oldWindowID),
            "newWindowID": String(newWindowID)
        ])
    }

    // MARK: - Bulk Operations

    func clearAllBindings() {
        windowStates.removeAll()
        sessionAliasWindowID.removeAll()
        lastEventDescription = "所有绑定已清除"
        store.deleteAllWindowsStates()
    }

    func purgeClosedWindows() {
        PerfMonitor.shared.beginSection("registry.purge")
        defer { PerfMonitor.shared.endSection() }
        // P-INST-75: 周期性清理耗时（@MainActor 每 60s Timer 触发 AppDelegate:74；cgWindowListAll + N 次 deleteWindowState SQLite 写；主线程周期性 I/O 可造成微卡顿）。
        let startedAt = Date()
        let windows = windowsProvider()

        // B253：空快照守卫——本函数按「不在快照里 = 窗已关」做破坏性删除（内存+DB 行）。
        // windowsProvider 是全系统窗列表（裸系统也有 Finder 等窗），返回空只可能是
        // WindowServer 瞬态/快照失败——拿着空列表判活会把全部绑定一次性清光。
        // 跳过本轮，等下一个正常快照（有绑定要清的场景下快照不可能为空）。
        guard !windows.isEmpty else {
            log("[SessionWindowRegistry] purgeClosedWindows skipped: empty window snapshot (transient CG failure?)", level: .warn, fields: [
                "cachedStates": String(windowStates.count)
            ])
            return
        }
        let activeWindowIDs = Set(windows.map { $0.windowID })

        let keysToRemove = windowStates.filter { _, state in
            guard !state.isCompleted else { return false }
            return !activeWindowIDs.contains(state.windowID)
        }.map(\.key)

        for key in keysToRemove {
            if let state = windowStates[key] {
                log("[SessionWindowRegistry] purging closed window: wid=\(state.windowID) pid=\(state.pid) app=\(state.appName ?? "unknown")")
                store.deleteWindowState(windowID: state.windowID)
                // B132 补齐：窗口已清则其会话别名同步作废（stale 别名正是 B125 张冠李戴类事故的种子）
                if let sid = state.sessionID {
                    sessionAliasWindowID.removeValue(forKey: sid)
                }
            }
            windowStates.removeValue(forKey: key)
        }
        logOperationDuration("[SessionWindowRegistry] purgeClosedWindows finished", startedAt: startedAt, warnThresholdMs: 100, fields: ["purged": String(keysToRemove.count)])
    }
}
