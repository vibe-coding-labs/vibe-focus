import AppKit
import ApplicationServices.HIServices
import CoreGraphics
import Foundation

// MARK: - Rectangle 式摆位执行
/// 把焦点窗口摆到 LayoutAction 指定的布局位置。目标 frame 由 LayoutFrameCalculator
/// 计算（可见区扣 menu bar/Dock），写入复用既有两条路径：
/// 同屏 AX 双阶段写（apply） / 跨屏 float 脱管 + yabai frame 直写（与
/// moveWindowToMainScreen P2 路径同构；裸 AX 跨屏写会被 WindowServer 钳回源屏）。
///
/// 语义决策（docs/design-rectangle-integration.md §2）：
/// - 摆位动作不写、不清 toggle record——核心用户流 "⌃Q 聚焦 → ⌃⌥→ 摆半 → ⌃Q 恢复"
///   依赖 record 在摆位后仍存活；
/// - 不在此处检查 LayoutPreferences.isEnabled：该开关只管热键注册/匹配（共存策略），
///   菜单/设置入口是显式用户意图，始终放行。
@MainActor
extension WindowManager {

    @discardableResult
    func applyLayoutAction(
        _ action: LayoutAction,
        triggerSource: String = "menu",
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "layout-\(action.rawValue)")
        let startedAt = Date()
        defer {
            log("[WindowManager] applyLayoutAction finished", fields: [
                "op": op,
                "action": action.rawValue,
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ])
        }

        guard hasAccessibilityPermission() else {
            log("applyLayoutAction failed: accessibility not granted", level: .error, fields: ["op": op])
            notifyAccessibilityPermissionRequired()
            return false
        }

        var context: [String: String] = [
            "op": op,
            "source": triggerSource,
            "action": action.rawValue
        ]
        let resolution = resolveFocusedWindowForToggle(
            frontApp: NSWorkspace.shared.frontmostApplication,
            cachedMainScreen: getMainScreen(),
            toggleContext: &context
        )
        guard let windowID = resolution.windowID, let identity = resolution.identity else {
            log("applyLayoutAction: no focused window", level: .debug, fields: ["op": op])
            NSSound.beep()
            return false
        }

        guard let windowFrame = resolution.windowFrame ?? cgWindowFrame(forWindowID: windowID) else {
            log("applyLayoutAction: cannot read window frame", level: .error, fields: ["op": op, "windowID": String(windowID)])
            NSSound.beep()
            return false
        }

        if let ax = resolution.windowAX, isNativeFullscreen(ax) {
            log("applyLayoutAction: skip native fullscreen window", fields: ["op": op, "windowID": String(windowID)])
            NSSound.beep()
            return false
        }

        // 窗口当前屏：displayContext 判定（Quartz→Cocoa 变换后匹配 NSScreen）
        let sourceScreen = displayContext(for: windowFrame).displayID
            .flatMap { CoordinateKit.nsScreen(forCGDisplayID: $0) } ?? getMainScreen()
        guard let sourceScreen else {
            log("applyLayoutAction: cannot resolve source screen", level: .error, fields: ["op": op])
            return false
        }

        let targetScreen: NSScreen
        switch action {
        case .nextDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1, let currentIndex = screens.firstIndex(of: sourceScreen) else {
                log("applyLayoutAction: nextDisplay requires >1 screen", level: .debug, fields: ["op": op])
                NSSound.beep()
                return false
            }
            targetScreen = screens[(currentIndex + 1) % screens.count]
        default:
            targetScreen = sourceScreen
        }

        // 可用区：visibleFrame 扣已学习保留区（副屏菜单栏等隐形钳制——真机实证
        // P40UG visibleFrame 谎报整屏，窗口写不进顶部 25px；insets 由 TerminalGrid
        // 编排学习缓存，无缓存时行为不变）
        let visibleFrame = DisplayWorkArea.plannedFrame(
            visibleFrame: CoordinateKit.quartzVisibleFrame(of: targetScreen),
            insets: DisplayWorkArea.learnedInsets(displayID: CoordinateKit.cgDisplayID(for: targetScreen) ?? 0)
        )
        guard let targetFrame = LayoutFrameCalculator.frame(
            for: action,
            visibleFrame: visibleFrame,
            windowFrame: windowFrame,
            gap: LayoutPreferences.snapGap
        ) else {
            log("applyLayoutAction: frame calculation failed", level: .error, fields: ["op": op])
            return false
        }

        let crossing = targetScreen !== sourceScreen
        let ok = crossing
            ? moveCrossDisplay(
                windowID: windowID,
                identity: identity,
                resolution: resolution,
                sourceScreen: sourceScreen,
                targetFrame: targetFrame,
                op: op
            )
            : moveSameDisplay(
                identity: identity,
                resolution: resolution,
                targetFrame: targetFrame,
                op: op
            )

        log("[WindowManager] applyLayoutAction result", fields: [
            "op": op,
            "windowID": String(windowID),
            "crossing": String(crossing),
            "ok": String(ok),
            "targetFrame": QuartzRect(targetFrame).description
        ])
        CrashContextRecorder.shared.record("layout_apply op=\(op) action=\(action.rawValue) ok=\(ok)")
        if !ok {
            NSSound.beep()
        }
        return ok
    }

    private func moveSameDisplay(
        identity: WindowIdentity,
        resolution: ToggleWindowResolution,
        targetFrame: CGRect,
        op: String
    ) -> Bool {
        guard let ax = resolution.windowAX ?? resolveWindow(identity: identity) else {
            log("applyLayoutAction: cannot resolve AX", level: .error, fields: ["op": op])
            return false
        }
        return apply(frame: targetFrame, to: ax, operationID: op, stage: "layout_apply", windowID: identity.windowID)
    }

    /// 供 TerminalGrid 等编排方使用的"把窗口精确摆到指定 frame"原语：
    /// float 脱管 → yabai frame 直写。真机实证（2026-09-04）：Terminal.app 的
    /// AppleScript set bounds 是相对窗口当前屏的局部坐标语义，跨屏摆放必漂移，
    /// 由本原语纠偏（与 moveWindowToMainScreen P2 同一引擎）。
    @discardableResult
    func placeWindow(windowID: UInt32, frame: CGRect, operationID: String) -> Bool {
        floatAndWriteFrame(
            windowID: windowID,
            targetFrame: frame,
            op: operationID,
            sourceVisibleSize: nil
        )
    }

    /// 跨屏摆位：float 脱管 → settle → yabai frame 直写（窗口归属跟随物理位置）。
    private func moveCrossDisplay(
        windowID: UInt32,
        identity: WindowIdentity,
        resolution: ToggleWindowResolution,
        sourceScreen: NSScreen,
        targetFrame: CGRect,
        op: String
    ) -> Bool {
        let sourceVisibleSize = CoordinateKit.quartzVisibleFrame(of: sourceScreen).size
        return floatAndWriteFrame(
            windowID: windowID,
            targetFrame: targetFrame,
            op: op,
            sourceVisibleSize: sourceVisibleSize
        )
    }

    private func floatAndWriteFrame(
        windowID: UInt32,
        targetFrame: CGRect,
        op: String,
        sourceVisibleSize: CGSize?
    ) -> Bool {
        var floatToggled = false
        if let info = spaceController.queryWindow(windowID: windowID), !info.isFloating {
            let floatOutcome = spaceController.setWindowFloat(windowID, operationID: op, knownWindowInfo: info)
            floatToggled = floatOutcome.didToggle
        }
        if floatToggled {
            FrameConvergence.waitForRelayout(
                minSettleMicros: WindowSettle.floatRelayoutMinSettleMicros,
                intervalMs: WindowSettle.frameVerifyPollIntervalMs,
                budgetMs: WindowSettle.floatRelayoutSettleMicros,
                read: { cgWindowBounds(for: windowID) },
                isSame: { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: frameTolerance) }
            )
            spaceController.clearWindowQueryCache()
        }

        return moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: targetFrame,
            op: op,
            stage: "frame_direct",
            sourceVisibleSize: sourceVisibleSize
        )
    }

    /// 原生全屏探测：AX "AXFullScreen" 属性；读取失败一律 fail-open（不拦截摆位）。
    private func isNativeFullscreen(_ ax: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &rawValue)
        guard status == .success else { return false }
        return rawValue as? Bool ?? false
    }
}
