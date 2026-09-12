import AppKit
import Foundation

// MARK: - 自动弹出决策门（B160）
// 「焦点落到活跃 Claude 会话所在终端窗 → 气泡自动出现」的唯一判定点。
// 全部事实由 InputBubbleAutoShow 观察器采集注入，本门纯函数可穷尽直测。
// 判序：开关 → 气泡占用 → 是否终端 → 窗口变化 → 活跃会话绑定。

enum InputBubbleAutoShowGate {
    enum Outcome: Equatable {
        case summon                // 自动弹出（气泡目标=当前聚焦窗）
        case skipNotEnabled        // 自动弹出开关关闭（⌥⌘B 手动唤起不受影响）
        case skipBubbleActive      // 气泡开着/提交中：整体冻结（lastSeen 不动，防提交回焦死循环）
        case skipNotTerminal       // 前台非终端：清 lastSeen（回到会话窗时会重新弹出）
        case skipSameWindow        // 与上次弹出同一窗：不重复弹
        case skipNoLiveSession     // 窗口无活跃（未结束）会话绑定：不弹（⌥⌘B 仍可手动）
        case skipNoBaseline        // B180：本窗首次观测，无前值，无从谈跨越
        case skipStillOffMain      // B180：同窗仍在非主屏（屏内移动/移去别的副屏）
        case skipAlreadyOnMain     // B180：同窗已在主屏（无新跨越，防 Esc 后重弹循环）
    }

    static func decide(
        autoShowEnabled: Bool,
        phaseIdle: Bool,
        frontIsTerminal: Bool,
        windowChanged: Bool,
        hasLiveSessionBinding: Bool
    ) -> Outcome {
        guard autoShowEnabled else { return .skipNotEnabled }
        guard phaseIdle else { return .skipBubbleActive }
        guard frontIsTerminal else { return .skipNotTerminal }
        guard windowChanged else { return .skipSameWindow }
        guard hasLiveSessionBinding else { return .skipNoLiveSession }
        return .summon
    }

    /// B162：「窗口被移动到主屏（Stop hook 拉回成功等）→ 气泡自动出现」决策门。
    /// 调用方已保证目标窗身份（hook 绑定仅认终端窗），此处只看开关与气泡占用。
    static func decideMoveToMainAutoShow(autoShowEnabled: Bool, phaseIdle: Bool) -> Outcome {
        guard autoShowEnabled else { return .skipNotEnabled }
        guard phaseIdle else { return .skipBubbleActive }
        return .summon
    }

    /// B180：「同一终端窗从非主屏跨越到主屏 → 气泡自动出现」决策门（摆位热键/鼠标拖动/
    /// 会话结束拉回等一切移动方式统一覆盖；Stop hook 快路径另有 decideMoveToMainAutoShow）。
    /// 纯函数直测；AutoShow tick 负责「同一 CGWindowID 前后两次观测的主屏归属」事实采集。
    /// - lastSeenOnMain == nil：本窗首次观测，无前值，无从谈跨越。
    static func decideMoveToMainArrival(
        moveToMainEnabled: Bool,
        phaseIdle: Bool,
        sameWindowAsLastTick: Bool,
        lastSeenOnMain: Bool?,
        nowOnMain: Bool
    ) -> Outcome {
        guard moveToMainEnabled else { return .skipNotEnabled }
        guard phaseIdle else { return .skipBubbleActive }
        guard sameWindowAsLastTick else { return .skipSameWindow }
        guard let wasOnMain = lastSeenOnMain else { return .skipNoBaseline }
        guard !wasOnMain else { return .skipAlreadyOnMain }
        guard nowOnMain else { return .skipStillOffMain }
        return .summon
    }
}

// MARK: - 焦点观察器
// 事实采集：NSWorkspace 激活通知（跨 app 切换即时）+ 1s 轮询兜底（同 app 多窗切换无通知）。
// 热路径零 AX：前台非终端时只做清标记；终端前台时用 CGWindowList（非阻塞）取该 app 最顶层
// onscreen 窗口——与注册表键同源（windowHandle = _AXUIElementGetWindow = CGWindowID）。

@MainActor
final class InputBubbleAutoShow {
    static let shared = InputBubbleAutoShow()

    private var observer: Any?
    private var timer: Timer?
    /// 上次评估过的终端窗（CGWindowID）；离开终端域清空 → 回到会话窗自动重弹
    private var lastEvaluatedWindowID: UInt32?
    /// B180：lastEvaluatedWindowID 窗口上次观测时是否在主屏（nil=首次观测/已清域）。
    /// 同窗从前值 false 跨到 true = 「被移动到主屏」事实。
    private var lastEvaluatedWindowOnMain: Bool?

    private init() {}

    func start() {
        guard observer == nil else { return }
        let autoshow = InputBubbleAutoShow.shared
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            // queue: .main 保证主线程；显式 assumeIsolated 满足 Sendable 检查（UsageTracker 同款）
            MainActor.assumeIsolated {
                autoshow.tick()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    autoshow.tick()
                }
            }
        }
        log("[InputBubble] auto-show started")
    }

    func tick() {
        let controller = InputBubbleController.shared
        let front = NSWorkspace.shared.frontmostApplication
        let frontIsTerminal = front.map {
            TerminalRegistry.isTerminalOrIDEApp(appName: $0.localizedName, bundleIdentifier: $0.bundleIdentifier)
        } ?? false

        var topWindowID: UInt32?
        var topWindowOnMain: Bool?
        if frontIsTerminal, let frontApp = front,
           let entry = topmostOnscreenWindowEntry(pid: frontApp.processIdentifier) {
            topWindowID = entry.windowID
            // B180：CG bounds（Quartz 系）→ 主屏归属（中心点判据，CoordinateKit 唯一事实源）。
            if let bounds = entry.bounds {
                topWindowOnMain = CoordinateKit.isOnMainScreen(bounds)
            }
        }
        let windowChanged = topWindowID != nil && topWindowID != lastEvaluatedWindowID
        let hasLive = topWindowID.map { SessionWindowRegistry.shared.hasLiveSessionBinding(windowID: $0) } ?? false
        // B180：焦点门 skip 分支会就地改写 lastEvaluated*，跨屏门的事实必须取改写前快照
        let sameWindowAsLastTick = topWindowID != nil && topWindowID == lastEvaluatedWindowID
        let lastSeenOnMainBeforeUpdate = lastEvaluatedWindowOnMain

        let outcome = InputBubbleAutoShowGate.decide(
            autoShowEnabled: InputBubblePreferences.autoShowOnFocus,
            phaseIdle: controller.isIdle,
            frontIsTerminal: frontIsTerminal,
            windowChanged: windowChanged,
            hasLiveSessionBinding: hasLive
        )

        switch outcome {
        case .summon:
            lastEvaluatedWindowID = topWindowID
            if topWindowID != nil { lastEvaluatedWindowOnMain = topWindowOnMain ?? lastEvaluatedWindowOnMain }
            log("[InputBubble] auto-show summon", fields: [
                "windowID": topWindowID.map(String.init) ?? "nil",
                "bundleID": front?.bundleIdentifier ?? "nil"
            ])
            CrashContextRecorder.shared.record("input_bubble_autoshow windowID=\(topWindowID.map(String.init) ?? "nil")")
            controller.summon()
            return
        case .skipNotTerminal:
            lastEvaluatedWindowID = nil
            lastEvaluatedWindowOnMain = nil
        case .skipSameWindow, .skipNoLiveSession:
            if let top = topWindowID { lastEvaluatedWindowID = top }
        // B180 三个新 case 仅由跨屏门产生，焦点门不会返回；列此仅为穷举。
        case .skipNoBaseline, .skipStillOffMain, .skipAlreadyOnMain, .skipNotEnabled, .skipBubbleActive:
            break
        }

        // B180：焦点门未弹出时评估「同窗跨到主屏」门——覆盖摆位热键/鼠标拖动/离屏救援等
        // 一切移动方式（Stop hook 拉回走 HookEventHandler 里的快路径门，不经此处）。
        // 与焦点门互斥：焦点门要求 windowChanged，本门要求 !windowChanged，同拍不会双弹。
        let moveOutcome = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: InputBubblePreferences.autoShowOnMoveToMain,
            phaseIdle: controller.isIdle,
            sameWindowAsLastTick: sameWindowAsLastTick,
            lastSeenOnMain: lastSeenOnMainBeforeUpdate,
            nowOnMain: topWindowOnMain ?? false
        )
        switch moveOutcome {
        case .summon:
            guard let tid = topWindowID, let frontApp = front else { return }
            lastEvaluatedWindowOnMain = true
            log("[InputBubble] move-to-main auto-show summon", fields: [
                "windowID": String(tid),
                "bundleID": frontApp.bundleIdentifier ?? "nil"
            ])
            CrashContextRecorder.shared.record("input_bubble_autoshow_move windowID=\(tid)")
            controller.summonForMovedWindow(
                windowID: tid,
                pid: frontApp.processIdentifier,
                appName: frontApp.localizedName
            )
        case .skipNoBaseline, .skipStillOffMain, .skipAlreadyOnMain, .skipSameWindow, .skipNoLiveSession:
            // 簿记：跟踪同窗的主屏归属基线（nil bounds 不覆盖旧值）
            if topWindowID != nil, let onMain = topWindowOnMain {
                lastEvaluatedWindowOnMain = onMain
            }
        // skipNotTerminal 仅由焦点门产生，跨屏门不会返回；列此仅为穷举。
        case .skipNotTerminal, .skipNotEnabled, .skipBubbleActive:
            break
        }
        // B160 诊断：终端前台且未弹出时落一行（归因 tick 链路；summon 分支已有专属日志）。
        // B165 降 debug：此行终端前台稳态下每秒一条（skipSameWindow 常态），INFO 级
        // 意味着生产日志每天 8.6 万行同值洪水、淹没真信号——与 P-INST-119 日志自激同病。
        if frontIsTerminal, outcome != .summon, controller.isIdle {
            log("[InputBubble] auto-show tick skip", level: .debug, fields: [
                "outcome": String(describing: outcome),
                "topWindowID": topWindowID.map(String.init) ?? "nil",
                "last": lastEvaluatedWindowID.map(String.init) ?? "nil"
            ])
        }
    }

    /// 前台终端 app 的最顶层 onscreen 常规窗（CGWindowList 顺序即 z 序，非阻塞）。
    /// B180：返回完整 entry，跨屏检测需要 bounds 判主屏归属。
    private func topmostOnscreenWindowEntry(pid: pid_t) -> CGWindowEntry? {
        let entries: [CGWindowEntry] = cgWindowListAll()
        for entry in entries where entry.ownerPID == pid && entry.layer == 0 && entry.isOnScreen {
            return entry
        }
        return nil
    }
}
