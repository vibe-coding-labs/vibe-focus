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
        if frontIsTerminal, let frontApp = front {
            topWindowID = topmostOnscreenWindowID(pid: frontApp.processIdentifier)
        }
        let windowChanged = topWindowID != nil && topWindowID != lastEvaluatedWindowID
        let hasLive = topWindowID.map { SessionWindowRegistry.shared.hasLiveSessionBinding(windowID: $0) } ?? false

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
            log("[InputBubble] auto-show summon", fields: [
                "windowID": topWindowID.map(String.init) ?? "nil",
                "bundleID": front?.bundleIdentifier ?? "nil"
            ])
            CrashContextRecorder.shared.record("input_bubble_autoshow windowID=\(topWindowID.map(String.init) ?? "nil")")
            controller.summon()
        case .skipNotTerminal:
            lastEvaluatedWindowID = nil
        case .skipSameWindow, .skipNoLiveSession:
            if let top = topWindowID { lastEvaluatedWindowID = top }
        case .skipNotEnabled, .skipBubbleActive:
            break
        }
        // B160 诊断：终端前台且未弹出时落一行（归因 tick 链路；summon 分支已有专属日志）
        if frontIsTerminal, outcome != .summon, controller.isIdle {
            log("[InputBubble] auto-show tick skip", fields: [
                "outcome": String(describing: outcome),
                "topWindowID": topWindowID.map(String.init) ?? "nil",
                "last": lastEvaluatedWindowID.map(String.init) ?? "nil"
            ])
        }
    }

    /// 前台终端 app 的最顶层 onscreen 常规窗（CGWindowList 顺序即 z 序，非阻塞）
    private func topmostOnscreenWindowID(pid: pid_t) -> UInt32? {
        let entries: [CGWindowEntry] = cgWindowListAll()
        for entry in entries where entry.ownerPID == pid && entry.layer == 0 && entry.isOnScreen {
            return entry.windowID
        }
        return nil
    }
}
