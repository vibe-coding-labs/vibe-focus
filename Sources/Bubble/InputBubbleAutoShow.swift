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
        case skipExternalMove      // B211：外部来源移动（并行会话 yabai/显示器重排）与输入无关，不弹
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

    /// B184：「同一终端窗从非主屏跨越到主屏 → 气泡自动出现」决策门 v2。
    /// B211 按移动者归因分流；B212 勘误恢复用户拉回弹出：用户 ⌃Q 拉回「挂着的会话窗」
    /// 正是工作流（拉窗→打字→提交归位），B211 误把「不精准」理解成「用户拉回也静默」，
    /// 装机后一早晨 21 次 skipUserMoved、用户复诉「不会自动弹了」。终案语义=「到主屏」
    /// 只对会话窗有意义：hookPull=agent 召唤直弹；userAction=用户拉回，窗挂活跃会话
    /// 才弹（B160 焦点门同款信号）；外部移动（无归因）与输入无关恒静默。
    /// 纯函数直测；基线=全窗口基线表按 windowID 查找（B184：窗在非前台时被移动、
    /// 之后才聚焦的流程，首观测即有历史基线，照样触发——旧「同窗连续观测」版有流程缝）。
    /// - lastSeenOnMain == nil：本窗无历史基线，无从谈跨越。
    /// - arrivalMover == nil：归因账本无新鲜记录 = 外部来源移动。
    /// - hasLiveSessionBinding：仅 userAction 分支消费（hookPull 拉回本就是会话窗，
    ///   且 SessionEnd 完成时序与拉回同拍，查绑定反而会误杀）。
    static func decideMoveToMainArrival(
        moveToMainEnabled: Bool,
        lastSeenOnMain: Bool?,
        nowOnMain: Bool,
        arrivalMover: InputBubbleArrivalMover?,
        hasLiveSessionBinding: Bool
    ) -> Outcome {
        guard moveToMainEnabled else { return .skipNotEnabled }
        guard let wasOnMain = lastSeenOnMain else { return .skipNoBaseline }
        guard !wasOnMain else { return .skipAlreadyOnMain }
        guard nowOnMain else { return .skipStillOffMain }
        guard arrivalMover != nil else { return .skipExternalMove }
        if arrivalMover == .hookPull { return .summon }
        guard hasLiveSessionBinding else { return .skipNoLiveSession }
        return .summon
    }

    enum ArrivalWhileOpen: Equatable { case keepCurrent, retarget }

    /// B184：气泡开着时「另一窗跨到主屏」的处置门。B195 加输入中守卫。
    /// - 自动隐藏模式（autoHide=true）：不打扰正在使用的气泡（旧行为）；
    /// - 气泡本就绑在到达窗上：跟随引擎已处理，不动；
    /// - 输入中（isDirty：文本≠打开时恢复的基准）→ 不改绑（真机实锤 2026-09-16
    ///   16:28 七秒连改绑两次 250→690→685：正在打的字被换成一窗空前缀=用户主诉
    ///   「气泡搞没了/被重置」；改绑收益让位输入连续性，到达窗不再弹不追补）；
    /// - 绑定跟随模式（默认）且空闲：气泡改绑到刚移到主屏的窗（旧窗草稿按窗保留）。
    static func decideArrivalWhileBubbleOpen(
        autoHide: Bool,
        openForWindowID: UInt32?,
        arrivedWindowID: UInt32,
        isDirty: Bool = false
    ) -> ArrivalWhileOpen {
        if autoHide { return .keepCurrent }
        if openForWindowID == arrivedWindowID { return .keepCurrent }
        if isDirty { return .keepCurrent }
        return .retarget
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
    /// B184：各窗主屏归属基线表（windowID → 上次观测 onMain）。
    /// 升级自 B180 的「仅跟踪最顶窗」：窗在非前台时被移动、之后才聚焦的流程，
    /// 首观测即有历史基线照样触发。容量 64 淘汰最旧，防长会话无界增长。
    private var onMainBaselineByWindow: [UInt32: Bool] = [:]
    private var baselineOrder: [UInt32] = []
    /// B305：前台 app 身份缓存（pid → localizedName/bundleIdentifier）。属性读取走
    /// LaunchServices 同步 XPC（装机实锤主线程 STALL 单次 1~7s、每天数百次，卡死期间
    /// 热键 tap/Carbon 分发全停）；前台 pid 未变的拍复用缓存，pid 变化才重读。
    private var frontIdentityPID: pid_t?
    private var frontIdentityName: String?
    private var frontIdentityBundleID: String?

    private init() {}

    func start() {
        guard observer == nil else { return }
        let autoshow = InputBubbleAutoShow.shared
        // B185：启动即全量播种基线——部署重启频繁，重启后基线表为空，第一次
        // 「副屏→主屏」必然无基线不弹（用户复测踩中）；启动扫一遍所有终端窗的
        // 主屏归属，之后照常由 tick 增量更新。屏幕重排时重播种防基线过期。
        autoshow.seedBaselines()
        NotificationCenter.default.addObserver(
            autoshow,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
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

    /// B185：屏幕插拔/重排 → 基线重播种（窗口随屏重排后 onMain 可能整体翻转）。
    @objc private func screenConfigurationDidChange() {
        seedBaselines()
    }

    /// B185：把当前所有终端 app 的 onscreen 常规窗主屏归属一次扫入基线表。
    /// 幂等：重复播种只刷新值，不清 tick 增量建立的历史。
    func seedBaselines() {
        var terminalPIDs: Set<pid_t> = []
        var seeded = 0
        let entries = cgWindowListAll()
        for entry in entries where entry.layer == 0 && entry.isOnScreen {
            guard let bounds = entry.bounds else { continue }
            if !terminalPIDs.contains(entry.ownerPID) {
                guard let app = NSRunningApplication(processIdentifier: entry.ownerPID),
                      TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else { continue }
                terminalPIDs.insert(entry.ownerPID)
            }
            recordBaseline(windowID: entry.windowID, onMain: CoordinateKit.isOnMainScreen(bounds))
            seeded += 1
        }
        if seeded > 0 {
            log("[InputBubble] baseline seeded", level: .debug, fields: ["windows": String(seeded)])
        }
    }

    func tick() {
        let controller = InputBubbleController.shared
        let front = NSWorkspace.shared.frontmostApplication
        // B305：前台身份按 pid 缓存（决策表 InputBubbleFrontIdentityPlan，Runner 直测）。
        // localizedName/bundleIdentifier 的读取走 LaunchServices 同步 XPC——装机实锤
        // 每秒 tick 重复读导致主线程 STALL 单次 1~7s（热键 tap/Carbon 分发全停）；
        // pid 未变的拍零属性读取，只在 pid 变化时重读并回写。
        let frontPID = front?.processIdentifier
        var identityName: String?
        var identityBundleID: String?
        switch InputBubbleFrontIdentityPlan.source(cachedPID: frontIdentityPID, currentPID: frontPID) {
        case .cached:
            identityName = frontIdentityName
            identityBundleID = frontIdentityBundleID
        case .readFresh:
            identityName = front?.localizedName
            identityBundleID = front?.bundleIdentifier
            frontIdentityPID = frontPID
            frontIdentityName = identityName
            frontIdentityBundleID = identityBundleID
        case .none:
            break
        }
        let frontIsTerminal = TerminalRegistry.isTerminalOrIDEApp(
            appName: identityName,
            bundleIdentifier: identityBundleID
        )

        // B185：跨屏检测扫描前台终端 app 的「全部」onscreen 常规窗——多窗多屏下
        // z 序最顶窗未必是用户刚移动的窗（真机探针实锤：z 顶停留旧窗时，被移窗的
        // 跨越永远不可见）；基线表按 windowID 记录，天然支持逐窗比对。
        var terminalWindows: [CGWindowEntry] = []
        var currentOnMain: [UInt32: Bool] = [:]
        if frontIsTerminal, let frontApp = front {
            terminalWindows = cgWindowListAll().filter {
                $0.ownerPID == frontApp.processIdentifier && $0.layer == 0 && $0.isOnScreen
            }
            for entry in terminalWindows {
                guard let bounds = entry.bounds else { continue }
                currentOnMain[entry.windowID] = CoordinateKit.isOnMainScreen(bounds)
            }
        }
        // top = 被扫窗的 z 序最前（CGWindowList 首位）；v1 的单窗观测变量已随 B185 全扫版退役
        //（此前恒 top=nil，2026-09-16 零警告门禁清账改为真值）。
        // B211：B185 的临时 [PROBE] tick 日志（每秒一条 INFO、日均 8.6 万行洪水）随诊断
        // 使命完结删除——真信号（summon/arrival suppressed）各有专属日志。
        let topWindowID = terminalWindows.first?.windowID
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
                "bundleID": identityBundleID ?? "nil"
            ])
            CrashContextRecorder.shared.record("input_bubble_autoshow windowID=\(topWindowID.map(String.init) ?? "nil")")
            controller.summon()
            return
        case .skipNotTerminal:
            lastEvaluatedWindowID = nil
        case .skipSameWindow, .skipNoLiveSession:
            if let top = topWindowID { lastEvaluatedWindowID = top }
        case .skipNoBaseline, .skipStillOffMain, .skipAlreadyOnMain, .skipNotEnabled, .skipBubbleActive,
             .skipExternalMove:
            break
        }

        // B185：跨屏检测 v3——扫描前台终端 app 的「全部」onscreen 常规窗，逐窗比对
        // 基线表旧值（读旧→判跨越→再落表，顺序不可换）。多窗多屏下 z 序最顶窗未必是
        // 用户刚移动的窗（真机探针实锤），单窗观测版有结构性盲区。
        // B212：跨越是否成弹=归因×绑定合取——hook 拉回直弹；用户 ⌃Q 拉回挂活跃会话的
        // 窗才弹（B211 全拦属过度修正，用户复诉「不会自动弹了」）；外部移动恒静默。
        // 气泡开着时：跟随模式改绑到到达窗；自动隐藏模式维持旧行为不打扰。
        var arrivedEntry: CGWindowEntry?
        var suppressedArrival: (windowID: UInt32, outcome: InputBubbleAutoShowGate.Outcome)?
        for entry in terminalWindows {
            guard let nowOnMain = currentOnMain[entry.windowID] else { continue }
            let arrivalOutcome = InputBubbleAutoShowGate.decideMoveToMainArrival(
                moveToMainEnabled: InputBubblePreferences.autoShowOnMoveToMain,
                lastSeenOnMain: onMainBaselineByWindow[entry.windowID],
                nowOnMain: nowOnMain,
                arrivalMover: MoveToMainAttributionLedger.shared.recentMover(windowID: entry.windowID),
                hasLiveSessionBinding: SessionWindowRegistry.shared.hasLiveSessionBinding(windowID: entry.windowID))
            if case .summon = arrivalOutcome {
                arrivedEntry = entry
                break
            }
            switch arrivalOutcome {
            case .skipNoLiveSession, .skipExternalMove:
                if suppressedArrival == nil { suppressedArrival = (entry.windowID, arrivalOutcome) }
            default:
                break
            }
        }
        if let suppressed = suppressedArrival, arrivedEntry == nil {
            log("[InputBubble] move-to-main arrival suppressed", fields: [
                "windowID": String(suppressed.windowID),
                "outcome": String(describing: suppressed.outcome)
            ])
        }
        if let arrived = arrivedEntry, let frontApp = front {
            if controller.isIdle {
                log("[InputBubble] move-to-main auto-show summon", fields: [
                    "windowID": String(arrived.windowID),
                    "bundleID": identityBundleID ?? "nil"
                ])
                CrashContextRecorder.shared.record("input_bubble_autoshow_move windowID=\(arrived.windowID)")
                controller.summonForMovedWindow(
                    windowID: arrived.windowID,
                    pid: frontApp.processIdentifier,
                    appName: identityName
                )
            } else {
                let disposition = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
                    autoHide: InputBubblePreferences.autoHide,
                    openForWindowID: controller.target?.windowID,
                    arrivedWindowID: arrived.windowID)
                log("[InputBubble] move-to-main arrival while bubble open", fields: [
                    "windowID": String(arrived.windowID),
                    "openFor": (controller.target?.windowID).map(String.init) ?? "nil",
                    "disposition": String(describing: disposition)
                ])
                if case .retarget = disposition {
                    controller.retargetForMovedWindow(
                        windowID: arrived.windowID,
                        pid: frontApp.processIdentifier,
                        appName: identityName
                    )
                }
            }
        }
        // 跨越判定完成后统一落基线（含无跨越拍：刷新现值）
        for entry in terminalWindows {
            if let nowOnMain = currentOnMain[entry.windowID] {
                recordBaseline(windowID: entry.windowID, onMain: nowOnMain)
            }
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

    /// B184：落基线（首见入表，容量 64 FIFO 淘汰最旧，防长会话无界增长）。
    private func recordBaseline(windowID: UInt32, onMain: Bool) {
        if onMainBaselineByWindow[windowID] == nil {
            baselineOrder.append(windowID)
            if baselineOrder.count > 64 {
                let evict = baselineOrder.removeFirst()
                onMainBaselineByWindow.removeValue(forKey: evict)
            }
        }
        onMainBaselineByWindow[windowID] = onMain
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
