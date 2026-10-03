// WindowManager+Toggle+Decision.swift
// VibeFocus — Toggle restore 决策逻辑
// 从 WindowManager+Toggle.swift 中提取
// B191：@MainActor 摘除——决策只读 CGWindowList + SQLite（ToggleEngine.load）
// + NSWorkspace 快照读，无主线程专属依赖；调用者 performToggleCore 已下放
// WindowWorkExecutor（B191）。

import AppKit
import Foundation

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
    /// displayCount 默认 2 = 历史双屏语义（既有调用方/测试零改动）；生产入口传
    /// ToggleEngine.displayCount 真值，单屏机走单屏 record 有效性规则。
    static func decideRestore(
        focusedOnMain: Bool?,
        recordByWindowID: ToggleRecord?,
        mainScreenFrame: CGRect?,
        displayCount: Int = 2
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
        if !record.isValid(mainScreenFrame: mainScreenFrame, displayCount: displayCount) {
            return .corruptedClearWindowID(record.windowID)
        }
        return .restore
    }

    // MARK: - 执行路由（Batch 5：mode 日志与执行分支的唯一映射）

    /// toggle 实际执行的分支。
    enum ToggleRoute: Equatable {
        case restore
        case moveToMain
        case moveSecondaryStuck
        /// 单屏机（displayCount ≤ 1）：无跨屏可去，无 record → 同屏最大化
        /// （有 record 的 restore 分支在前已短路）。
        case singleDisplayMaximize

        /// 日志 mode 字段名（与审计 eventType 的 mode 值一致）。
        var logName: String {
            switch self {
            case .restore: return "restore"
            case .moveToMain: return "move_to_main"
            case .moveSecondaryStuck: return "move_to_secondary_stuck"
            case .singleDisplayMaximize: return "single_display_maximize"
            }
        }
    }

    /// 路由决策唯一映射（纯函数，ToggleRouteTests 分支穷尽锁定）。
    ///
    /// ## 场景（Batch 5）
    /// 此前 `(decision, onMainScreen) → 分支` 的映射以两份表示散在 toggle() 里：
    /// mode 字符串 switch 与执行 switch 内联 if——在 (decision=.moveToMain,
    /// onMainScreen=true) 组合下 mode 记 "move_to_main" 而执行走 stuck（日志失真，
    /// 2026-09-06 已注释承认过一次同类失真）。本函数是该映射的唯一事实源：
    /// mode 字符串、执行分支、审计 mode 全部由它派生。
    ///
    /// 语义：
    /// - .restore → 回原位；
    /// - 其余决策按解析层归属（resolution.onMainScreen，与决策层的
    ///   isWindowOnMainScreen 是不同来源，可能不一致——以解析层为准执行）：
    ///   在主屏 → stuck 解堵（移副屏）；不在主屏或归属未知（nil）→ move_to_main。
    ///
    /// ## 单屏机（displayCount ≤ 1，2026-10-03）
    /// 只有一块屏时「移副屏解堵」「跨屏拉主屏」都无处可去——历史上 ⌃Q 在单屏机
    /// 是纯 no-op（stuck 找不到副屏 warn 后 return）。新语义：除 restore 外一律
    /// 同屏最大化（网格中选中的窗充满主屏可视区，记录 orig=原网格单元帧；
    /// 下一次 ⌃Q 经 restore 分支回退原尺寸，与双屏「拉上⇄送回」节奏对齐）。
    /// 旧双参签名保留委托（displayCount=2 双屏语义），既有测试零改动。
    static func route(for decision: RestoreDecision, onMainScreen: Bool?) -> ToggleRoute {
        route(for: decision, onMainScreen: onMainScreen, displayCount: 2)
    }

    static func route(for decision: RestoreDecision, onMainScreen: Bool?, displayCount: Int) -> ToggleRoute {
        if case .restore = decision { return .restore }
        if displayCount <= 1 { return .singleDisplayMaximize }
        return onMainScreen == true ? .moveSecondaryStuck : .moveToMain
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
        // 单屏机判据：displayCount 真值进决策（record 有效性单/双屏规则分流，
        // P-INST-267 注释里「toggle 入口判断单屏/多屏」的既定消费点）。
        let displayCount = ToggleEngine.shared.displayCount
        let decision = Self.decideRestore(
            focusedOnMain: focusedOnMain,
            recordByWindowID: record,
            mainScreenFrame: mainScreenFrame,
            displayCount: displayCount
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
