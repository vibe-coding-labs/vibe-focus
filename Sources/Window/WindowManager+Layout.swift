import AppKit
import ApplicationServices.HIServices
import CoreGraphics
import Foundation

// MARK: - 摆位宿主依赖缝
/// applyLayoutAction 的宿主依赖（权限/焦点窗解析/屏幕/可用区/AX 写入/跨屏写/
/// 提示音/审计）。默认 nil 走实例真实方法；Runner 注入假实现即可在 CLI 直测
/// 全部分支判定（零 AX 写入、零窗口移动、零提权弹框）。
struct LayoutApplyEnvironment {
    var hasAccessibilityPermission: @MainActor () -> Bool
    var notifyPermissionRequired: @MainActor () -> Void
    var frontmostApplication: @MainActor () -> NSRunningApplication?
    var mainScreen: @MainActor () -> NSScreen?
    /// 返回（焦点窗解析结果, 追加到日志 context 的探针字段）
    var resolveFocusedWindow: @MainActor (NSRunningApplication?, NSScreen?) -> (ToggleWindowResolution, [String: String])
    var cgWindowFrame: @MainActor (UInt32) -> CGRect?
    var isNativeFullscreen: @MainActor (AXUIElement) -> Bool
    var displayContextDisplayID: @MainActor (CGRect) -> UInt32?
    var nsScreenForDisplayID: @MainActor (UInt32) -> NSScreen?
    var screens: @MainActor () -> [NSScreen]
    var visibleFrame: @MainActor (NSScreen) -> CGRect
    var snapGap: @MainActor () -> CGFloat
    var resolveAX: @MainActor (WindowIdentity) -> AXUIElement?
    var applyFrame: @MainActor (CGRect, AXUIElement, String) -> Bool
    var floatWriteFrame: @MainActor (UInt32, CGRect, String) -> Bool
    var beep: @MainActor () -> Void
    var record: @MainActor (String) -> Void
}

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
        applyLayoutAction(action, triggerSource: triggerSource, operationID: operationID, environment: nil)
    }

    /// 带宿主依赖缝的实现体（environment 非 nil 时全部宿主点走注入，
    /// 供 Runner 在 CLI 直测分支判定；生产调用恒为 nil）。
    func applyLayoutAction(
        _ action: LayoutAction,
        triggerSource: String,
        operationID: String?,
        environment: LayoutApplyEnvironment?
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

        let trusted = environment?.hasAccessibilityPermission() ?? hasAccessibilityPermission()
        guard trusted else {
            log("applyLayoutAction failed: accessibility not granted", level: .error, fields: ["op": op])
            if let environment {
                environment.notifyPermissionRequired()
            } else {
                notifyAccessibilityPermissionRequired()
            }
            return false
        }

        var context: [String: String] = [
            "op": op,
            "source": triggerSource,
            "action": action.rawValue
        ]
        let resolution: ToggleWindowResolution
        if let environment {
            let (resolved, extraContext) = environment.resolveFocusedWindow(
                environment.frontmostApplication(), environment.mainScreen())
            resolution = resolved
            context.merge(extraContext) { _, new in new }
        } else {
            resolution = resolveFocusedWindowForToggle(
                frontApp: NSWorkspace.shared.frontmostApplication,
                cachedMainScreen: getMainScreen(),
                toggleContext: &context
            )
        }
        guard let windowID = resolution.windowID, let identity = resolution.identity else {
            log("applyLayoutAction: no focused window", level: .debug, fields: ["op": op])
            layoutBeep(environment)
            return false
        }

        let liveFrame: CGRect?
        if let environment {
            liveFrame = environment.cgWindowFrame(windowID)
        } else {
            liveFrame = cgWindowFrame(forWindowID: windowID)
        }
        guard let windowFrame = resolution.windowFrame ?? liveFrame else {
            log("applyLayoutAction: cannot read window frame", level: .error, fields: ["op": op, "windowID": String(windowID)])
            layoutBeep(environment)
            return false
        }

        if let ax = resolution.windowAX,
           environment?.isNativeFullscreen(ax) ?? isNativeFullscreen(ax) {
            log("applyLayoutAction: skip native fullscreen window", fields: ["op": op, "windowID": String(windowID)])
            layoutBeep(environment)
            return false
        }

        // 窗口当前屏：displayContext 判定（Quartz→Cocoa 变换后匹配 NSScreen）
        let sourceScreen: NSScreen?
        if let environment {
            sourceScreen = environment.displayContextDisplayID(windowFrame)
                .flatMap { environment.nsScreenForDisplayID($0) } ?? environment.mainScreen()
        } else {
            sourceScreen = displayContext(for: windowFrame).displayID
                .flatMap { CoordinateKit.nsScreen(forCGDisplayID: $0) } ?? getMainScreen()
        }
        guard let sourceScreen else {
            log("applyLayoutAction: cannot resolve source screen", level: .error, fields: ["op": op])
            return false
        }

        let targetScreen: NSScreen
        switch action {
        case .nextDisplay:
            let screens = environment?.screens() ?? NSScreen.screens
            guard screens.count > 1, let currentIndex = screens.firstIndex(of: sourceScreen) else {
                log("applyLayoutAction: nextDisplay requires >1 screen", level: .debug, fields: ["op": op])
                layoutBeep(environment)
                return false
            }
            targetScreen = screens[(currentIndex + 1) % screens.count]
        default:
            targetScreen = sourceScreen
        }

        // 可用区：visibleFrame 扣已学习保留区（副屏菜单栏等隐形钳制——真机实证
        // P40UG visibleFrame 谎报整屏，窗口写不进顶部 25px；insets 由 TerminalGrid
        // 编排学习缓存，无缓存时行为不变）。解算口径集中在 ScreenWorkArea，
        // 与网格编排共用同一事实源。
        let visibleFrame = environment?.visibleFrame(targetScreen)
            ?? ScreenWorkArea.plan(for: targetScreen).planningFrame
        guard let targetFrame = LayoutFrameCalculator.frame(
            for: action,
            visibleFrame: visibleFrame,
            windowFrame: windowFrame,
            gap: environment?.snapGap() ?? LayoutPreferences.snapGap
        ) else {
            log("applyLayoutAction: frame calculation failed", level: .error, fields: ["op": op])
            return false
        }

        let crossing = targetScreen !== sourceScreen
        let ok: Bool
        if crossing {
            ok = environment?.floatWriteFrame(windowID, targetFrame, op)
                ?? moveCrossDisplay(
                    windowID: windowID,
                    identity: identity,
                    resolution: resolution,
                    sourceScreen: sourceScreen,
                    targetFrame: targetFrame,
                    op: op
                )
        } else {
            ok = moveSameDisplay(
                identity: identity,
                resolution: resolution,
                targetFrame: targetFrame,
                op: op,
                environment: environment
            )
        }

        log("[WindowManager] applyLayoutAction result", fields: [
            "op": op,
            "windowID": String(windowID),
            "crossing": String(crossing),
            "ok": String(ok),
            "targetFrame": QuartzRect(targetFrame).description
        ])
        let audit = "layout_apply op=\(op) action=\(action.rawValue) ok=\(ok)"
        if let environment {
            environment.record(audit)
        } else {
            CrashContextRecorder.shared.record(audit)
        }
        if !ok {
            layoutBeep(environment)
        }
        return ok
    }

    private func layoutBeep(_ environment: LayoutApplyEnvironment?) {
        if let environment {
            environment.beep()
        } else {
            NSSound.beep()
        }
    }

    private func moveSameDisplay(
        identity: WindowIdentity,
        resolution: ToggleWindowResolution,
        targetFrame: CGRect,
        op: String,
        environment: LayoutApplyEnvironment?
    ) -> Bool {
        let ax: AXUIElement?
        if let environment {
            ax = resolution.windowAX ?? environment.resolveAX(identity)
        } else {
            ax = resolution.windowAX ?? resolveWindow(identity: identity)
        }
        guard let ax else {
            log("applyLayoutAction: cannot resolve AX", level: .error, fields: ["op": op])
            return false
        }
        if let environment {
            return environment.applyFrame(targetFrame, ax, op)
        }
        return apply(frame: targetFrame, to: ax, operationID: op, stage: "layout_apply", windowID: identity.windowID)
    }

    /// 供 TerminalGrid 等编排方使用的"把窗口精确摆到指定 frame"原语：
    /// float 脱管 → yabai frame 直写。真机实证（2026-09-04）：Terminal.app 的
    /// AppleScript set bounds 是相对窗口当前屏的局部坐标语义，跨屏摆放必漂移，
    /// 由本原语纠偏（与 moveWindowToMainScreen P2 同一引擎）。
    /// B313 nonisolated 化：链上仅 floatAndSettle（已 nonisolated）+
    /// moveWindowToFrameViaYabai（+MoveWindow 非 actor 扩展），零 NSApp/NSWindow
    /// 依赖（B191 探针同款结论）——grid 链经 WindowWorkExecutor 下放调用后，
    /// 本体不再被 @MainActor extension 钉住。
    @discardableResult
    nonisolated func placeWindow(windowID: UInt32, frame: CGRect, operationID: String) -> Bool {
        floatAndWriteFrame(
            windowID: windowID,
            targetFrame: frame,
            op: operationID,
            sourceVisibleFrame: nil
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
        let sourceVisibleFrame = CoordinateKit.quartzVisibleFrame(of: sourceScreen)
        return floatAndWriteFrame(
            windowID: windowID,
            targetFrame: targetFrame,
            op: op,
            sourceVisibleFrame: sourceVisibleFrame
        )
    }

    /// FloatSettle 唯一序列原语的 WindowManager 接线：通道 = spaceController 的
    /// float/缓存通道 + cgWindowBounds 读，容差 = frameTolerance。
    /// 全仓 float 脱管一律经此出口，禁止再手抄 float→settle 序列（Batch 6 收敛，
    /// 序列契约见 FloatSettle）。
    @discardableResult
    nonisolated func floatAndSettle(windowID: UInt32, operationID: String, knownWindowInfo: YabaiWindowInfo?) -> FloatSettle.Outcome {
        FloatSettle.floatAndSettle(
            windowID: windowID,
            operationID: operationID,
            knownWindowInfo: knownWindowInfo,
            tolerance: frameTolerance,
            setFloat: { self.spaceController.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
            read: { cgWindowBounds(for: $0) },
            clearCache: { self.spaceController.clearWindowQueryCache() }
        )
    }

    /// B313 nonisolated（随 placeWindow 下放，链上零 UI 依赖，见 placeWindow 注记）
    nonisolated private func floatAndWriteFrame(
        windowID: UInt32,
        targetFrame: CGRect,
        op: String,
        sourceVisibleFrame: CGRect?
    ) -> Bool {
        // float 脱管 + settle + 缓存失效统一走 FloatSettle（Batch 6 收敛，
        // 原 12 行手抄副本删除——已 float 零等待语义经通道内 floatToggleDecision 保持）。
        floatAndSettle(windowID: windowID, operationID: op, knownWindowInfo: nil)

        return moveWindowToFrameViaYabai(
            windowID: windowID,
            frame: targetFrame,
            op: op,
            stage: "frame_direct",
            sourceVisibleFrame: sourceVisibleFrame
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
