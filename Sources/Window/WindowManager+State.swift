import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window State Management
// 窗口状态持久化：save、load、persist、clear、hydrate
@MainActor
extension WindowManager {

    func saveWindowState(_ state: SavedWindowState, window: AXUIElement? = nil) -> SavedWindowState {
        let removed = WindowStateStore.shared.evictStatesOlderThan(maxAge: 3600)
        if removed > 0 {
            log("Evicted \(removed) expired state(s) from SQLite")
        }

        // 限制内存数组最多 10 条，避免无限增长
        while savedWindowStates.count >= 10 {
            let oldest = savedWindowStates.removeFirst()
            WindowStateStore.shared.deleteState(id: oldest.id)
        }

        if let window {
            windowElementsByStateID[state.id] = window
        }

        // 保持内存数组与 SQLite 同步
        if let idx = savedWindowStates.firstIndex(where: { $0.id == state.id }) {
            savedWindowStates[idx] = state
        } else {
            savedWindowStates.append(state)
        }

        WindowStateStore.shared.saveState(state)
        log(
            "Saved window state to SQLite: \(state.id)",
            fields: [
                "windowID": String(describing: state.windowID),
                "app": state.appName ?? "unknown"
            ]
        )
        return state
    }

    func loadSavedWindowStates() -> [SavedWindowState] {
        let states = WindowStateStore.shared.loadStates()
        log("Loaded \(states.count) window state(s) from SQLite")
        return states
    }

    func persistSavedWindowStates() {
        // SQLite 的 saveWindowState 已经逐条写入，无需批量持久化
    }

    func clearSavedWindowState(id: String?) {
        guard let id else { return }
        WindowStateStore.shared.deleteState(id: id)
        windowElementsByStateID.removeValue(forKey: id)
        savedWindowStates.removeAll { $0.id == id }
        log("Cleared window state from SQLite: \(id)")
    }

    func resetActiveWindowContext(removeState: Bool) {
        let activeStateID = lastWindowToken?.stateID
        lastWindowElement = nil
        lastWindowToken = nil
        lastWindowFrame = nil
        lastTargetFrame = nil
        lastSourceSpaceIndex = nil
        lastTargetSpaceIndex = nil
        lastSourceYabaiDisplayIndex = nil
        lastSourceDisplaySpaceIndex = nil
        if removeState {
            clearSavedWindowState(id: activeStateID)
        }
    }

    func hydrateMemory(from state: SavedWindowState, window: AXUIElement?) {
        let cachedElement = windowElementsByStateID[state.id]
        let resolvedWindow = window ?? cachedElement

        // 验证缓存的 AX 元素是否仍然有效
        var effectiveWindow: AXUIElement? = resolvedWindow
        if let resolvedWindow {
            if !isValidAXElement(resolvedWindow) {
                log(
                    "hydrateMemory: cached AX element is stale, clearing",
                    level: .warn,
                    fields: [
                        "stateID": state.id,
                        "expectedWindowID": String(describing: state.windowID)
                    ]
                )
                windowElementsByStateID.removeValue(forKey: state.id)
                effectiveWindow = nil
            }
        }

        // 如果没有有效 AX 元素，尝试按 PID + windowID 主动查找
        if effectiveWindow == nil, let windowID = state.windowID {
            effectiveWindow = findWindowByPID(state.pid, windowID: windowID)
            if let found = effectiveWindow {
                log(
                    "hydrateMemory: re-resolved window by PID enumeration",
                    fields: [
                        "stateID": state.id,
                        "windowID": String(windowID)
                    ]
                )
                windowElementsByStateID[state.id] = found
            }
        }

        lastWindowElement = effectiveWindow
        lastWindowToken = WindowToken(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowID: state.windowID,
            windowNumber: state.windowNumber,
            title: state.title
        )
        lastWindowFrame = state.originalFrame.cgRect
        lastTargetFrame = state.targetFrame.cgRect
        lastSourceSpaceIndex = state.sourceSpaceIndex
        lastTargetSpaceIndex = state.targetSpaceIndex
        lastSourceYabaiDisplayIndex = state.sourceYabaiDisplayIndex
        lastSourceDisplaySpaceIndex = state.sourceDisplaySpaceIndex
    }

    func shouldReplaceSavedState(
        _ existing: SavedWindowState,
        with incoming: SavedWindowState,
        currentWindow: AXUIElement?
    ) -> Bool {
        if existing.id == incoming.id {
            return true
        }

        if let currentWindow,
           let cachedWindow = windowElementsByStateID[existing.id],
           CFEqual(cachedWindow, currentWindow) {
            return true
        }

        guard let existingID = existing.windowID,
              let incomingID = incoming.windowID else {
            return false
        }

        return existingID == incomingID
    }

}
