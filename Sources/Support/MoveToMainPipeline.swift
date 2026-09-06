import AppKit
import ApplicationServices.HIServices
import Foundation

/// move_to_main 阶段管线（Batch 7）：阶段顺序 + 提前返回契约的唯一执行体。
///
/// ## 为什么存在
/// `moveWindowToMainScreen` 的六段混排（capture→解析→origFrame 快照→skip 检查→
/// settable→apply→post-check→save）此前全部内联在 WindowManager，顺序契约只活在
/// 注释——历史上 a049a86（origFrame 在 space move 之后才读、被 yabai re-tile 污染，
/// 副屏单窗口 restore 尺寸错乱）正是快照时机违规的真实事故。本管线把「谁先谁后、
/// 失败短路、双路径各自只 float 一次」变成 Runner 假 IO 可断言的调用序列，与
/// FrameWriteExecutor（段内写入编排）衔接成本管线的完整执行骨架。
///
/// ## 序列契约（Tests/Runner 场景 A~J 锁定）
/// 1. captureSpaceContext 先于一切写操作（sourceSpace = 移动前 space，restore 回位依据）；
/// 2. origFrame 快照：knownOrigFrame 优先，否则 AX 读——恒发生在任何 apply 之前；
/// 3. 双路径各只 float 一次：P2 路径（knownWindowAX == nil）= 主屏 visible space 解析
///    → FloatSettle 脱管 → resolveWindow，apply 段跳过 float；AX 路径 = apply 前
///    FloatSettle 脱管（先脱管再写，防 yabai re-tile 覆盖）；
/// 4. 已在主屏跳过（仅 AX 路径判定）：上报 alreadyOnMain，不进 apply/post-check/save；
/// 5. 任一 guard 失败上报 failed(stage:)，其后所有阶段短路（stage 值即失败日志锚点）；
/// 6. apply 成功才进 post-check 与 save，save 恒最后。
///
/// 编排属执行域：不做 standalone 镜像（决策部分 isAlreadyMaximizedOnMain 例外，
/// 纯函数镜像锁定）；其内嵌的浮窗序列/写序/补发决策分别由 FloatSettle、
/// FrameConvergence 的既有双锁覆盖。
struct MoveToMainPipeline {

    /// 已在主屏即视为已最大化（仅 AX 路径消费）：窗口 yabai display == 1 且 frame
    /// 中心落在主屏 frame 内。P2 路径不消费此判定（已主动改写窗口 space，但 size
    /// 仍可能是副屏尺寸，必须继续 apply 全屏 size）。
    static func isAlreadyMaximizedOnMain(displayYabaiIndex: Int?, mainScreenFrame: CGRect?, frame: CGRect) -> Bool {
        guard displayYabaiIndex == 1, let mainScreenFrame else { return false }
        return mainScreenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    struct Timings {
        var captureSpaceContextMs = 0
        var visibleSpaceIndexMs = 0
        var resolveWindowMs = 0
        var frameReadMs = 0
        var queryWindowMs = 0
        var settableCheckMs = 0
        /// float 脱管+settle 耗时（P2 = 预 float 段；AX = apply 前 float 实测耗时）
        var floatMs = 0
        /// P2 预 float 段耗时（诊断字段名兼容保留；AX 路径恒 0）
        var p2SpaceMoveMs = 0
        var applyMs = 0
        var postMoveCheckMs = 0
        var saveMs = 0
    }

    enum Outcome: Equatable {
        /// 全管线完成（post-check 已跑、record 已保存）。
        case moved(effectiveWindowID: UInt32)
        /// 已在主屏（AX 路径跳过判定命中），其余阶段短路。
        case alreadyOnMain
        /// guard 失败；stage 为失败日志锚点（与既有失败日志文本一一对应）。
        case failed(stage: String)
    }

    struct RunResult {
        let outcome: Outcome
        let timings: Timings
    }

    /// IO 通道全注入：生产实现由 WindowManager 接线，Runner 注入记录调用序列的假通道。
    struct Deps {
        let hasAX: () -> Bool
        /// AX 拒绝时的用户通知（原 guard 内 notifyAccessibilityPermissionRequired）
        let notifyAXRequired: () -> Void
        let captureSpaceContext: (_ windowID: UInt32, _ op: String) -> SpaceContext
        /// 主屏 visible space（spaceController.visibleSpaceIndex(forDisplayIndex: 1)）
        let visibleSpaceIndexOfMainDisplay: () -> SpaceIdentifier?
        let floatAndSettle: (_ windowID: UInt32, _ op: String, _ knownInfo: YabaiWindowInfo?) -> FloatSettle.Outcome
        let resolveWindow: (WindowIdentity) -> AXUIElement?
        let readAXFrame: (AXUIElement) -> CGRect?
        let queryWindow: (UInt32) -> YabaiWindowInfo?
        /// position + size 双属性可写检查（任一不可写 = false）
        let isSettable: (AXUIElement) -> Bool
        let mainScreen: () -> NSScreen?
        /// 主屏可视区 → AX 坐标目标 frame（axFrame(forVisibleFrameOf:)）
        let targetFrameFor: (NSScreen) -> CGRect
        let targetDisplayIndexOf: (NSScreen) -> Int?
        let windowHandleOf: (AXUIElement) -> UInt32?
        /// yabai display → 可视区（P2 sourceVisibleFrame；nil 入参 → nil）
        let visibleFrameOfYabaiDisplay: (Int?) -> CGRect?
        /// P2 段：yabai frame 直写（moveWindowToFrameViaYabai，stage 固定 "move_to_main"）
        let applyFrameDirect: (_ windowID: UInt32, _ frame: CGRect, _ op: String, _ sourceVisibleFrame: CGRect?) -> Bool
        /// AX 段：float 后 apply（position+size，maxAttempts 3）
        let applyAX: (_ ax: AXUIElement, _ frame: CGRect, _ op: String, _ windowID: UInt32) -> Bool
        let postCheck: (_ ax: AXUIElement, _ windowID: UInt32, _ target: CGRect, _ orig: CGRect, _ screen: NSScreen, _ op: String) -> Int
        /// record 落库（reason/sessionID 由生产闭包捕获，不在通道内）
        let save: (_ identity: WindowIdentity, _ windowID: UInt32, _ orig: CGRect, _ ctx: SpaceContext, _ target: CGRect, _ displayIndex: Int?, _ op: String) -> Int
    }

    static func run(
        identity: WindowIdentity,
        op: String,
        knownWindowAX: AXUIElement?,
        knownOrigFrame: CGRect?,
        deps: Deps
    ) -> RunResult {
        var timings = Timings()
        return RunResult(outcome: execute(identity: identity, op: op, knownWindowAX: knownWindowAX, knownOrigFrame: knownOrigFrame, deps: deps, timings: &timings), timings: timings)
    }

    private static func execute(
        identity: WindowIdentity,
        op: String,
        knownWindowAX: AXUIElement?,
        knownOrigFrame: CGRect?,
        deps: Deps,
        timings: inout Timings
    ) -> Outcome {
        // S1 AX guard：无授权不发起任何 yabai/AX 通道。
        guard deps.hasAX() else {
            log("moveWindowToMainScreen failed: accessibility not granted", level: .error, fields: ["op": op])
            deps.notifyAXRequired()
            return .failed(stage: "ax_denied")
        }

        // S2 captureSpaceContext：必须在任何写操作之前（sourceSpace = 移动前 space，
        // restore 回位依据；P2 路径的 float 脱管也会改窗口状态，同样排在其后）。
        let captureCtxStart = Date()
        let spaceContext = deps.captureSpaceContext(identity.windowID, op)
        timings.captureSpaceContextMs = elapsedMilliseconds(since: captureCtxStart)

        // S3 windowAX 解析：双路径（AX 直用 / P2 预 float 后 resolve）。
        let windowAX: AXUIElement
        var preFloatApplied = false
        if let knownAX = knownWindowAX {
            windowAX = knownAX
        } else {
            // 主屏 visible space 编号（restore record 需要；窗口归属由 frame 直写自动跟随）
            let visibleSpaceStart = Date()
            let mainScreenSpaceIndex = deps.visibleSpaceIndexOfMainDisplay()?.yabaiIndex
            timings.visibleSpaceIndexMs = elapsedMilliseconds(since: visibleSpaceStart)
            guard let mainScreenSpaceIndex else {
                log("moveWindowToMainScreen P2 failed: cannot resolve main screen visible space", level: .error, fields: ["op": op])
                return .failed(stage: "visible_space")
            }
            // P2 预 float 脱管（FloatSettle 唯一出口）：已 float 零等待，真 toggle 等
            // 稳定落定——之后 resolve + frame 直写不再重复 float（防二次 toggle）。
            preFloatApplied = true
            let preFloatStart = Date()
            let p2Float = deps.floatAndSettle(identity.windowID, op, nil)
            timings.p2SpaceMoveMs = elapsedMilliseconds(since: preFloatStart)
            timings.floatMs = timings.p2SpaceMoveMs
            log("[WindowManager] moveWindowToMainScreen P2: float + settle", fields: [
                "op": op, "windowID": String(identity.windowID),
                "mainScreenSpace": String(mainScreenSpaceIndex),
                "floatToggled": String(p2Float.didToggle),
                "durationMs": String(timings.p2SpaceMoveMs)
            ])
            // 窗口物理仍在源屏，AX resolveWindow 可能跨屏阻塞一次（~68ms，可接受）
            let resolveStart = Date()
            let resolvedAX = deps.resolveWindow(identity)
            timings.resolveWindowMs = elapsedMilliseconds(since: resolveStart)
            guard let resolvedAX else {
                log("moveWindowToMainScreen P2 failed: cannot resolve window", level: .error, fields: ["op": op])
                return .failed(stage: "resolve_window")
            }
            windowAX = resolvedAX
        }

        // S4 origFrame 快照：knownOrigFrame（toggle 入口 space move 前捕获）优先；
        // AX 读兜底。恒在 apply 之前——移动后再读会被 yabai re-tile 污染成主屏新值
        // （a049a86 副屏单窗口尺寸缩小的根因）。
        let frameReadStart = Date()
        let origFrame: CGRect?
        if let preCapturedFrame = knownOrigFrame {
            origFrame = preCapturedFrame
            log("[WindowManager] moveWindowToMainScreen: using pre-captured origFrame (P2 yabai path)", fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "origFrame": QuartzRect(preCapturedFrame).description,
                "source": "knownOrigFrame"
            ])
        } else {
            let axFrame = deps.readAXFrame(windowAX)
            origFrame = axFrame
            log("[WindowManager] moveWindowToMainScreen: using AX frame read", fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "origFrame": axFrame.map { "\($0.origin.x),\($0.origin.y) \($0.width)x\($0.height)" } ?? "nil",
                "source": "AX"
            ])
        }
        timings.frameReadMs = elapsedMilliseconds(since: frameReadStart)
        guard let origFrame else {
            log("moveWindowToMainScreen failed: cannot read current frame", level: .error, fields: ["op": op])
            return .failed(stage: "orig_frame")
        }

        log("[WindowManager] moveWindowToMainScreen: space context captured", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "sourceSpaceIndex": spaceContext.sourceSpaceIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplayIndex": spaceContext.sourceDisplayIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplaySpaceIndex": String(spaceContext.sourceDisplaySpaceIndex ?? -1),
            "origFrame": QuartzRect(origFrame).description
        ])

        // S5 已在主屏跳过（仅 AX 路径）：P2 已主动改写 space，不能跳。
        let queryWindowStart = Date()
        let windowInfo = deps.queryWindow(identity.windowID)
        timings.queryWindowMs = elapsedMilliseconds(since: queryWindowStart)
        if knownWindowAX != nil {
            let displayYabaiIndex = windowInfo?.display.map { DisplayIdentifier.yabai($0) }.flatMap { $0.yabaiIndex }
            // 短路序保真：mainScreen 只在 display==1 时才查询（与拆分前 getMainScreen 惰性一致）。
            if displayYabaiIndex == 1,
               let mainScreenFrame = deps.mainScreen()?.frame,
               Self.isAlreadyMaximizedOnMain(displayYabaiIndex: displayYabaiIndex, mainScreenFrame: mainScreenFrame, frame: origFrame) {
                log("[WindowManager] moveWindowToMainScreen skipped: already on main screen", fields: [
                    "op": op, "windowID": String(identity.windowID)
                ])
                return .alreadyOnMain
            }
        }

        // S6 settable 检查 + 主屏解析。
        let settableStart = Date()
        let settable = deps.isSettable(windowAX)
        timings.settableCheckMs = elapsedMilliseconds(since: settableStart)
        guard settable else {
            log("moveWindowToMainScreen failed: window attributes not settable", level: .error, fields: ["op": op])
            return .failed(stage: "settable")
        }
        guard let mainScreen = deps.mainScreen() else {
            log("moveWindowToMainScreen failed: cannot determine main screen", level: .error, fields: ["op": op])
            return .failed(stage: "main_screen")
        }

        let targetFrame = deps.targetFrameFor(mainScreen)
        let targetDisplayIndex = deps.targetDisplayIndexOf(mainScreen)

        // CGWindowID 跨屏移动后不变，提前计算并复用给 post-check/save。
        let effectiveWindowID = deps.windowHandleOf(windowAX) ?? identity.windowID

        // S7 apply：双路径各只 float 一次（P2 已在 S3 预 float；AX 在此 float）。
        let applyStart = Date()
        if preFloatApplied {
            // P2：yabai frame 直写（跨 display 唯一可靠通道）。sourceVisibleFrame =
            // 窗口当前所在副屏可视区——供写序判定避开 clamp + 放大序源屏先行判定
            // （2026-09-06 水波修复：resize 源屏先行，窗口以终态落主屏）。
            let sourceVisibleFrame = deps.visibleFrameOfYabaiDisplay(windowInfo?.display)
            guard deps.applyFrameDirect(identity.windowID, targetFrame, op, sourceVisibleFrame) else {
                log("moveWindowToMainScreen failed: yabai frame move did not converge", level: .error, fields: [
                    "op": op, "targetFrame": String(describing: targetFrame)
                ])
                return .failed(stage: "apply_p2")
            }
        } else {
            // AX：窗口已在主屏 display（同屏 AX 写有效）。先 float 脱离 yabai 管理
            // 再写（tiled 时 AX size write 会被 re-tile 覆盖）；FloatSettle 等重摆落定。
            let floatKnownInfo = (effectiveWindowID == identity.windowID) ? windowInfo : nil
            let axFloat = deps.floatAndSettle(effectiveWindowID, op, floatKnownInfo)
            timings.floatMs = axFloat.durationMs
            guard deps.applyAX(windowAX, targetFrame, op, effectiveWindowID) else {
                log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                    "op": op, "targetFrame": String(describing: targetFrame)
                ])
                return .failed(stage: "apply_ax")
            }
        }
        timings.applyMs = elapsedMilliseconds(since: applyStart)

        // S8 post-check：size 漂移校验重写兜底（+MoveWindow+PostMove.swift）。
        timings.postMoveCheckMs = deps.postCheck(windowAX, effectiveWindowID, targetFrame, origFrame, mainScreen, op)

        // S9 save：toggle record 落库（restore 回位依据），恒最后。
        timings.saveMs = deps.save(identity, effectiveWindowID, origFrame, spaceContext, targetFrame, targetDisplayIndex, op)

        return .moved(effectiveWindowID: effectiveWindowID)
    }
}
