// WindowManager+Toggle+Decision.swift
// VibeFocus — Toggle restore 决策逻辑
// 从 WindowManager+Toggle.swift 中提取

import AppKit
import Foundation

@MainActor
extension WindowManager {

    /// Restore decision — extracted for testability
    enum RestoreDecision: Equatable {
        case restore                // window on main + valid toggle record
        case moveToMain             // window on secondary screen
        case noRecord               // no toggle record found
        case corruptedClearWindowID(UInt32)  // record exists but invalid（判定方已 clear）
        case noFocusedWindow        // cannot identify focused window
        case noMainScreen           // cannot get main screen frame
    }

    /// Pure decision logic for shouldRestoreCurrentWindow.
    /// Separates the decision tree from system I/O for unit testing.
    static func decideRestore(
        focusedOnMain: Bool?,
        recordByWindowID: ToggleRecord?,
        mainScreenFrame: CGRect?
    ) -> RestoreDecision {
        guard let focusedOnMain else {
            return .noFocusedWindow
        }
        if !focusedOnMain {
            return .moveToMain
        }
        guard let record = recordByWindowID else {
            return .noRecord
        }
        guard let mainScreenFrame else {
            return .noMainScreen
        }
        if !record.isValid(mainScreenFrame: mainScreenFrame) {
            return .corruptedClearWindowID(record.windowID)
        }
        return .restore
    }

    func shouldRestoreCurrentWindow() -> Bool {
        return shouldRestoreCurrentWindow(windowID: nil, store: ToggleEngine.shared)
    }

    /// Testable overload that accepts an injected ToggleRecordStore.
    /// 不带 windowID → 走旧 AX 查询路径（测试 / 非 toggle 入口兼容）。
    func shouldRestoreCurrentWindow(store: ToggleRecordStore) -> Bool {
        return evaluateRestoreDecision(windowID: nil, store: store) == .restore
    }

    /// Bool 投影（兼容旧调用方/测试）：完整决策见 evaluateRestoreDecision。
    func shouldRestoreCurrentWindow(windowID: UInt32?, store: ToggleRecordStore) -> Bool {
        return evaluateRestoreDecision(windowID: windowID, store: store) == .restore
    }

    /// 主实现：返回完整决策枚举，toggle 入口按 case 路由（restore / stuck / move_to_main）。
    ///
    /// ## 场景
    /// - 仅 toggle 入口与上方 Bool 投影调用；每 toggle 一次，主线程同步。
    /// - 输入收集（AX 权限/焦点解析/CGWindowList 归属/SQLite load）在本函数，
    ///   决策树全部在纯函数 decideRestore —— 生产与测试守护同一棵决策树
    ///   （此前生产内联重写了一份、decideRestore 仅测试引用，两份顺序漂移）。
    ///
    /// ## 竞态约束
    /// - 不带 windowID → 走 AX 查询路径（副屏可阻塞 1-2s），仅测试/非 toggle 入口使用；
    ///   toggle 入口必须传 CGWindowList 已解析的 windowID。
    ///
    /// - Returns: 决策枚举；.corruptedClearWindowID 分支**已附带执行** store.clear
    ///   （历史行为：判定+清除一体，调用方无需重复清理）。
    func evaluateRestoreDecision(windowID: UInt32?, store: ToggleRecordStore) -> RestoreDecision {
        // P-INST-76: shouldRestore 决策总耗时（toggle 决策核心，plan P0.2 gap2 优化点；windowID 传入走 CGWindowList+SQLite 非阻塞，windowID==nil 走 AX focusedWindow/windowHandle 可阻塞；子调用 hasAccessibilityPermission P-INST-64 / isWindowOnMainScreen P-INST-61 / store.load P-INST-18 / store.clear P-INST-67 已埋，此为顶层聚合归因）。
        #if PERF_INSTRUMENT
        let srStart = Date()
        defer {
            log("[WindowManager] evaluateRestoreDecision finished", level: .debug, fields: [
                "hadWindowID": String(windowID != nil),
                "durationMs": String(elapsedMilliseconds(since: srStart))
            ])
        }
        #endif
        if !hasAccessibilityPermission() {
            log(
                "[WindowManager] evaluateRestoreDecision: no AX permission, cannot determine",
                level: .debug
            )
            return .noFocusedWindow
        }

        let currentWindowID: UInt32
        if let resolved = windowID {
            // toggle 入口已用 CGWindowList 解析的 windowID，直接复用，跳过 AX 查询。
            currentWindowID = resolved
        } else {
            guard let frontApp = NSWorkspace.shared.frontmostApplication,
                  let focusedWindow = focusedWindow(for: frontApp.processIdentifier),
                  let resolvedID = windowHandle(for: focusedWindow) else {
                log(
                    "[WindowManager] evaluateRestoreDecision: cannot identify focused window",
                    level: .debug,
                    fields: [
                        "hasFrontApp": String(NSWorkspace.shared.frontmostApplication != nil)
                    ]
                )
                return .noFocusedWindow
            }
            currentWindowID = resolvedID
        }

        let focusedOnMain = isWindowOnMainScreen(windowID: currentWindowID)
        log(
            "[WindowManager] evaluateRestoreDecision: focused window identified",
            level: .debug,
            fields: [
                "focusedWindowID": String(currentWindowID),
                "focusedOnMainScreen": String(focusedOnMain)
            ]
        )
        // 与旧实现一致：不在主屏时提前短路，不读 SQLite
        guard focusedOnMain else {
            log(
                "[WindowManager] evaluateRestoreDecision: focused window on secondary screen → move to main",
                fields: ["windowID": String(currentWindowID)]
            )
            return .moveToMain
        }

        let record = store.load(windowID: currentWindowID)
        let mainScreenFrame: CGRect? = (record != nil) ? getMainScreen()?.frame : nil
        let decision = Self.decideRestore(
            focusedOnMain: focusedOnMain,
            recordByWindowID: record,
            mainScreenFrame: mainScreenFrame
        )
        if case .corruptedClearWindowID(let clearedID) = decision {
            log(
                "[WindowManager] evaluateRestoreDecision: toggle record corrupted, clearing",
                level: .warn,
                fields: [
                    "windowID": String(currentWindowID),
                    "storedWindowID": String(clearedID)
                ]
            )
            store.clear(windowID: clearedID)
        } else if case .restore = decision {
            // isNearTarget 守卫已移除 — yabai tiling 引擎会移动窗口导致偏移，
            // 此时恰恰是需要 restore 的场景。isValid 检查已足够防止 corrupted data。
            log(
                "[WindowManager] evaluateRestoreDecision: focused window on main, has valid toggle record → restore",
                fields: [
                    "windowID": String(currentWindowID),
                    "pid": String(record?.pid ?? 0)
                ]
            )
        } else {
            log(
                "[WindowManager] evaluateRestoreDecision: no toggle record for window",
                level: .debug,
                fields: [
                    "windowID": String(currentWindowID),
                    "decision": String(describing: decision)
                ]
            )
        }
        return decision
    }
}
