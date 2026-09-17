import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - 输入气泡控制器（B129）
// 生命周期：快捷键唤起（默认 ⌃X，仅聚焦终端窗时）→ 本地打字 → Enter/⌘Enter 注入 → 焦点还给终端。
// 行为约束：
// - 目标在弹 UI 前捕获（TitleEditor 2026-09-07 焦点劫持教训：弹 UI 后前台已是 VibeFocus，
//   再按前台取目标必盲射）；
// - 注入前双重校验：前台 app 回到目标 pid 且 AX 窗口柄与捕获一致（防激活期间切 tab 误射，
//   B125 教训：宁可不注入，不可射进错窗）；
// - 注入 = 剪贴板快照 → 写文本 → ⌘V（bracketed paste，多行不误提交）→[可选 Return]
//   → 按纯决策恢复剪贴板；
// - 纯决策全部在 InputBubbleLogic（Runner 直测），本文件只做 IO 编排。
// B151 按域拆分（逐字搬移零行为变更）：面板构建/锚定 → +Panel，提交链机械 → +Submission，
// 剪贴板快照恢复 → +Clipboard，气泡视图族 → InputBubbleViews；本文件保留状态、生命周期与委托。
// B162：Enter/⌘Enter 改 keyDown 层拦截（doCommandBy 收不到 ⌘Enter，noop: 实锤）+
// 草稿按窗保留（InputBubbleDraftStore）+ 用户拖动位置记忆 + Stop 拉回主屏定向弹出。
// B175：气泡内提交钮（鼠标路径）+ 右下角拖拽调尺寸（量化落账广播）+
// 与设置页尺寸滑杆双向实时联动（sizeDidChangeNotification）。

@MainActor
final class InputBubbleController: NSObject {
    static let shared = InputBubbleController()

    enum Phase { case idle, open, submitting }
    var phase: Phase = .idle

    /// B160：气泡是否空闲（自动弹出观察器的冻结判据；开着/提交中均不算空闲）
    var isIdle: Bool { phase == .idle }

    var panel: InputBubblePanel?
    var textView: NSTextView?

    /// 设置窗可见性暂存（B133：气泡与设置窗都是本 app key 候选，同屏竞争时设置窗
    /// 作为 main window 会抢走 key 使气泡收不到键盘——TitleEditor 同款解法：
    /// 气泡存续期临时 orderOut 设置窗，气泡关闭后恢复可见性）
    var settingsWasVisible = false

    /// B162：程序化定位期间的 windowDidMove 抑制标记（区分程序摆放 vs 用户拖动）。
    /// setFrameOrigin 的 didMove 通知同步派发，布尔标记即足够。
    var suppressMoveTracking = false

    /// B133：尺寸/回车语义从偏好读取（设置页可调）；面板按「构建参数指纹」缓存，
    /// 指纹变化（改尺寸/改回车行为）时下次唤起重建，避免陈旧布局。
    var panelBuiltFor: (size: NSSize, submitOnEnter: Bool)?
    var bubbleSize: NSSize {
        NSSize(width: InputBubblePreferences.bubbleWidth, height: InputBubblePreferences.bubbleHeight)
    }

    /// B175：右下角拖拽调尺寸的起点快照（beginResizeDrag 置位，finish 后清空）
    var resizeDragStart: (origin: NSPoint, size: NSSize)?

    /// B195：本次打开恢复出的基准文本（↑↓ 翻阅 stash 与改绑脏守卫的比对基准）。
    /// 用户打字后 textView.string != 此值 = 输入中（dirty）。
    var lastRestoredBaseText: String = ""
    /// B195：↑↓ 历史翻阅态——index = 当前展示的历史条目下标（nil=编辑现场）；
    /// stash = 进入翻阅前的现场文本（↓ 走出最新一条时还原）。
    var historyNavIndex: Int?
    var historyStashedText: String?

    /// B183 绑定跟随模式（autoHide=false 默认）：跟随基线与轮询定时器。
    /// baseline = 上次同步点的目标窗 origin 与气泡 origin（均 AppKit 全局坐标）。
    var followWindowOrigin: NSPoint?
    var followBubbleOrigin: NSPoint?
    var followTimer: Timer?
    /// B186 语音气泡让位：true=已降到 .floating 给 LazyTyper 录音气泡让位
    var voiceYielded = false
    private var voiceYieldScanCounter = 0
    /// B183：本 app 内点击监视器——失焦后点气泡重新激活+收键
    /// （nonactivatingPanel 点击不激活 app，子视图会吃掉 mouseDown，必须监视器层拦）。
    var clickMonitor: Any?

    /// 热键瞬间捕获的注入目标
    struct Target {
        let pid: pid_t
        let bundleID: String?
        let windowID: UInt32
        let title: String?
    }
    var target: Target?

    /// 剪贴板快照（注入前保存；恢复决策按 changeCount 走 InputBubbleClipboardPlan）
    var clipboardItems: [[NSPasteboard.PasteboardType: Data]] = []
    var clipboardPostWriteCount = -1

    private override init() {
        super.init()
        // B175：设置页滑杆改尺寸 → 打开中的气泡面板实时联动
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bubbleSizeDidChange(_:)),
            name: InputBubblePreferences.sizeDidChangeNotification,
            object: nil
        )
    }

    // MARK: 热键入口（CGEventTap / Carbon / fallback 三通道汇合点；TitleEditor 同款非隔离静态）

    nonisolated static func triggerFromHotKey() {
        DispatchQueue.main.async {
            InputBubbleController.shared.summon()
        }
    }

    // MARK: 唤起 / 关闭

    /// 快捷键唤起（默认 ⌃X）：开着则关（toggle）；没开则捕获聚焦终端窗并弹气泡。
    /// 前台不是可识别终端时 beep 拒绝（静默吞键会让用户以为失灵，与摆位热键同款反馈）。
    func summon() {
        PerfMonitor.shared.beginSection("bubble.summon")
        defer { PerfMonitor.shared.endSection() }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        log("[InputBubble] summon called", fields: ["phase": String(describing: phase), "frontBundle": frontBundle])
        if phase == .open {
            dismiss(reactivateTarget: false)
            return
        }
        guard phase == .idle else { return }
        guard InputBubblePreferences.isEnabled else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[InputBubble] summon: no frontmost app")
            NSSound.beep()
            return
        }
        let bundleID = frontApp.bundleIdentifier
        guard TerminalRegistry.isTerminalOrIDEApp(
            appName: frontApp.localizedName,
            bundleIdentifier: bundleID
        ) else {
            // B164：前台是自家 app（设置窗里试键/录制）时静默退场——此刻唤起无从谈
            // 目标窗，beep 只会让用户误读为热键失灵；非终端他 app 保持 beep 拒绝反馈。
            if InputBubbleSummonGate.disposition(
                frontBundleID: bundleID,
                isTerminalApp: false
            ) == .ownApp {
                log("[InputBubble] summon: frontmost is self (settings/UI), silent skip", fields: [
                    "bundleID": bundleID ?? "nil"
                ])
                return
            }
            log("[InputBubble] summon: frontmost is not a terminal", fields: [
                "bundleID": bundleID ?? "nil"
            ])
            NSSound.beep()
            return
        }
        let pid = frontApp.processIdentifier
        guard let windowAX = WindowManager.shared.focusedWindow(for: pid),
              let windowID = WindowManager.shared.windowHandle(for: windowAX) else {
            log("[InputBubble] summon: no focused window for terminal", level: .warn, fields: [
                "pid": String(pid)
            ])
            NSSound.beep()
            return
        }
        // 锚点 frame 现查现用（CGWindowList 单窗读，非阻塞；与 AX 捕获同窗同源）
        guard let cgFrame = cgWindowBounds(for: windowID) else {
            log("[InputBubble] summon: no cg bounds for window", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            NSSound.beep()
            return
        }

        let captured = Target(pid: pid, bundleID: bundleID, windowID: windowID, title: WindowManager.shared.title(of: windowAX))
        showPanel(target: captured, cgFrame: cgFrame, source: .manualHotKey)
        CrashContextRecorder.shared.record("input_bubble_summon windowID=\(windowID) pid=\(pid)")
    }

    /// B162：窗口被移动到主屏（Stop hook 拉回成功等）后的定向弹出。
    /// 目标窗以入参为准——此刻前台未必是该终端，不能走前台捕获路径；
    /// 身份兜底校验（终端判定/窗口还在屏上）通过后复用 showPanel。
    func summonForMovedWindow(windowID: UInt32, pid: pid_t, appName: String?) {
        guard InputBubblePreferences.isEnabled, phase == .idle else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              TerminalRegistry.isTerminalOrIDEApp(appName: app.localizedName, bundleIdentifier: app.bundleIdentifier) else {
            log("[InputBubble] moved-window summon: app not terminal", level: .debug, fields: [
                "windowID": String(windowID), "pid": String(pid)
            ])
            return
        }
        guard let cgFrame = cgWindowBounds(for: windowID) else {
            log("[InputBubble] moved-window summon: window not onscreen", level: .debug, fields: [
                "windowID": String(windowID)
            ])
            return
        }
        let target = Target(pid: pid, bundleID: app.bundleIdentifier, windowID: windowID, title: appName)
        showPanel(target: target, cgFrame: cgFrame, source: .autoShow)
        CrashContextRecorder.shared.record("input_bubble_summon_moved windowID=\(windowID) pid=\(pid)")
    }

    /// B184：绑定跟随模式下，另一窗跨到主屏而气泡开着 → 气泡改绑到到达窗。
    /// 旧窗草稿按窗落盘不丢（InputBubbleDraftStore），dismiss+定向重弹即完成换绑。
    /// B195：输入中（文本≠恢复基准）不改绑——真机实锤七秒连改绑两次，正在打的字
    /// 被换成一窗空前缀=「气泡搞没了/被重置」主诉；改绑让位输入连续性。
    func retargetForMovedWindow(windowID: UInt32, pid: pid_t, appName: String?) {
        guard phase == .open, let current = target, current.windowID != windowID else { return }
        let isDirty = (textView?.string ?? "") != lastRestoredBaseText
        guard case .retarget = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: InputBubblePreferences.autoHide,
            openForWindowID: current.windowID,
            arrivedWindowID: windowID,
            isDirty: isDirty
        ) else {
            log("[InputBubble] arrival retarget skipped (drafting)", fields: [
                "openFor": String(current.windowID),
                "windowID": String(windowID)
            ])
            return
        }
        log("[InputBubble] follow retarget \(current.windowID) -> \(windowID)", fields: [
            "appName": appName ?? "nil"
        ])
        dismiss(reactivateTarget: false)
        summonForMovedWindow(windowID: windowID, pid: pid, appName: appName)
    }

    private func showPanel(target: Target, cgFrame: CGRect, source: InputBubbleSummonSource) {
        self.target = target
        phase = .open
        // B195：↑↓ 翻阅态随开随清（每次打开都是新现场）
        historyNavIndex = nil
        historyStashedText = nil

        // 先收起设置窗（若可见）：防止其以 main window 身份抢 key（实测存在）
        let settingsWindow = SettingsWindowController.shared.window
        settingsWasVisible = settingsWindow?.isVisible ?? false
        if settingsWasVisible { settingsWindow?.orderOut(nil) }

        let (panel, textView) = builtPanel()
        // B162：位置记忆优先——用户拖动过则出现在记忆位置（夹进目标屏可视区），
        // 从未拖过回落目标窗锚点。
        let origin = restoredOrigin(targetCGFrame: cgFrame)
        suppressMoveTracking = true
        panel.setFrameOrigin(origin)
        suppressMoveTracking = false
        // B195：恢复决策门——窗草稿优先；手动唤起兜底全局最近输入（窗重建/换窗
        // 也能拿回内容）；自动弹出保守（窗草稿否则前缀，不塞未经邀请的旧内容）。
        let restored = InputBubbleDraftRestorePlan.resolve(
            windowDraft: InputBubbleDraftStore.shared.draft(for: target.windowID),
            latestHistory: InputBubbleHistoryStore.shared.latestEntry()?.text,
            source: source,
            prefix: InputBubblePreferences.defaultPrefix
        )
        let initial = restored.text
        lastRestoredBaseText = initial
        textView.string = initial
        textView.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        // B178：光标跳尾的 scrollRangeToVisible 可能带偏横向 origin（宽度暂态/滚动条
        // 出现改变可视宽），选区落定立即归零，长草稿不再左缘裁字。
        (panel.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        panel.makeKeyAndOrderFront(nil)

        // 收键盘三件套：切 regular（accessory 不收 key）→ 激活自己 → textView 成第一响应者
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        textView.window?.makeFirstResponder(textView)
        // B180：气泡存续期隐藏自家浮层（幂等）——见 ScreenOverlayManager.setOverlaysSuppressedForInputBubble
        ScreenOverlayManager.shared.setOverlaysSuppressedForInputBubble(true)
        // B183：绑定跟随模式（自动隐藏=关，默认）启动跟随引擎；自动隐藏=开则不跟随（旧行为）
        if InputBubblePreferences.autoHide {
            stopFollowing()
        } else {
            startFollowing(targetCGFrame: cgFrame, bubbleOrigin: origin)
        }
        installClickMonitor()

        log("[InputBubble] bubble opened", fields: [
            "windowID": String(target.windowID),
            "pid": String(target.pid),
            "bundleID": target.bundleID ?? "nil",
            "title": truncateForLog(target.title ?? "", limit: 60),
            "origin": "\(Int(origin.x)),\(Int(origin.y))",
            "restoredFrom": restored.from.rawValue
        ])
    }

    /// Esc / 点外部 / toggle 关闭。reactivateTarget：Esc 关闭时把焦点还给终端
    /// （submit 路径自己已激活终端，传 false 防重复抢）。
    func dismiss(reactivateTarget: Bool) {
        PerfMonitor.shared.beginSection("bubble.hide")
        defer { PerfMonitor.shared.endSection() }
        guard phase == .open else { return }
        let captured = target
        // B195：关闭即抓当前文本落盘（不再依赖 300ms 防抖的最后一次 textDidChange——
        // 真机曾丢尾编辑）+ 进全局历史（重开/换窗都能拿回）。干净关闭（文本=恢复
        // 基准，用户没打字）零写入——不把默认前缀当草稿/历史污染存储。
        if let textView, let target, textView.string != lastRestoredBaseText {
            InputBubbleDraftStore.shared.save(textView.string, for: target.windowID)
            InputBubbleDraftStore.shared.flushPending()
            // B196：带状态/窗口归属（草稿态；防抖镜像同文会被 append 去重合并）
            InputBubbleHistoryStore.shared.record(
                textView.string,
                windowID: target.windowID,
                windowTitle: target.title,
                status: .draft
            )
        }
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        target = nil
        phase = .idle
        historyNavIndex = nil
        historyStashedText = nil
        // B196：气泡没了历史面板必联动收起（填充按钮的宿主不在了）
        InputBubbleHistoryPanelController.shared.close()
        NSApp.setActivationPolicy(.accessory)
        // B183：跟随引擎与点击监视器随气泡生命周期终止
        stopFollowing()
        // B180：气泡关闭即还原自家浮层（幂等；提交路径的 finishSubmission 同款）
        ScreenOverlayManager.shared.setOverlaysSuppressedForInputBubble(false)
        restoreSettingsWindowIfNeeded()
        if reactivateTarget, let t = captured {
            _ = NSRunningApplication(processIdentifier: t.pid)?.activate(options: .activateIgnoringOtherApps)
        }
        log("[InputBubble] bubble dismissed", level: .debug)
    }

    /// B195：SIGTERM 收尾（部署杀进程高频）——气泡开着且输入中时把当前文本落
    /// 草稿+历史，重启后重开不丢。与 dismiss 的差别：不动 UI/状态机（进程将死）。
    func flushDraftForTermination() {
        guard phase == .open, let textView, let target,
              textView.string != lastRestoredBaseText else { return }
        InputBubbleDraftStore.shared.save(textView.string, for: target.windowID)
        InputBubbleDraftStore.shared.flushPending()
        InputBubbleHistoryStore.shared.record(
            textView.string,
            windowID: target.windowID,
            windowTitle: target.title,
            status: .draft
        )
        log("[InputBubble] draft flushed on termination", fields: [
            "windowID": String(target.windowID)
        ])
    }

    // MARK: 历史面板（B196）

    /// 气泡上的「历史」入口：打开/聚焦历史面板（默认按当前绑定窗过滤）。
    func showHistoryPanel() {
        guard let bubbleFrame = panel?.frame else { return }
        InputBubbleHistoryPanelController.shared.toggle(
            anchorFrame: bubbleFrame,
            currentWindowID: target?.windowID,
            fill: { [weak self] text in
                self?.fillFromHistory(text)
            }
        )
    }

    /// ⌘Y（B204）：唤出/收回历史面板，返回 true=已消费。
    /// 气泡焦点态走这里；面板焦点态（搜索框打字中）由面板本地监视器同键收回，
    /// 两侧互斥接收、各收各的，不会双 toggle。
    func toggleHistoryPanel() -> Bool {
        guard phase == .open, panel != nil else { return false }
        showHistoryPanel()
        return true
    }

    /// 面板「填充」：把历史文本回填进打开中的气泡（替换全文），基线同步推进
    /// （防脏守卫/干净关闭语义把回填误判为用户新输入）。
    /// B203 防蒸发：覆盖前若现场是用户改动过的非空白文本，先落一条草稿历史——
    /// 正在输入的草稿不再被回填静默顶掉。
    func fillFromHistory(_ text: String) {
        guard phase == .open, let textView else { return }
        if let target,
           InputBubbleFillGuard.shouldPreserveCurrent(
            currentText: textView.string, baseText: lastRestoredBaseText) {
            InputBubbleHistoryStore.shared.record(
                textView.string,
                windowID: target.windowID,
                windowTitle: target.title,
                status: .draft
            )
        }
        textView.string = text
        lastRestoredBaseText = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if let target {
            InputBubbleDraftStore.shared.save(text, for: target.windowID)
        }
        (panel?.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        refocusPanel()
        log("[InputBubble] history filled into bubble", fields: [
            "windowID": target.map { String($0.windowID) } ?? "nil",
            "length": String(text.count)
        ])
    }

    // MARK: ↑↓ 输入历史翻阅（B195；B203 起口径=本窗优先，本窗无历史回落全部）

    /// ↑：逐条变旧。返回 true=已消费（textView 不再走 super 光标移动）。
    /// 首次进入翻阅自动 stash 现场文本；到最旧停住。
    func historyPrevious() -> Bool {
        guard phase == .open, let textView else { return false }
        let entries = InputBubbleHistoryFilter.navEntries(
            InputBubbleHistoryStore.shared.entries(),
            currentWindowID: target?.windowID
        )
        let action = InputBubbleHistoryNavPlan.up(currentIndex: historyNavIndex, entryCount: entries.count)
        return applyHistoryNav(action, entries: entries, textView: textView)
    }

    /// ↓：逐条变新；走出最新一条回编辑现场（stash 还原）。未在翻阅中=不消费。
    func historyNext() -> Bool {
        guard phase == .open, let textView else { return false }
        let entries = InputBubbleHistoryFilter.navEntries(
            InputBubbleHistoryStore.shared.entries(),
            currentWindowID: target?.windowID
        )
        let action = InputBubbleHistoryNavPlan.down(currentIndex: historyNavIndex, entryCount: entries.count)
        return applyHistoryNav(action, entries: entries, textView: textView)
    }

    private func applyHistoryNav(
        _ action: InputBubbleHistoryNavPlan.Action,
        entries: [InputBubbleHistoryEntry],
        textView: NSTextView
    ) -> Bool {
        PerfMonitor.shared.measure("bubble.historyNav") {
            switch action {
            case .none:
                return
            case .moveTo(let index):
                guard index < entries.count else { return }
                if historyNavIndex == nil { historyStashedText = textView.string }
                historyNavIndex = index
                setNavText(entries[index].text, textView: textView)
            case .exitToStashed:
                historyNavIndex = nil
                setNavText(historyStashedText ?? "", textView: textView)
                historyStashedText = nil
            }
        }
        return action != .none
    }

    /// 翻阅换文本：草稿同步（programmatic set 不触发 textDidChange，手动落）
    /// + 光标跳尾 + 横向归零（B178 同款）。
    private func setNavText(_ text: String, textView: NSTextView) {
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if let target {
            InputBubbleDraftStore.shared.save(text, for: target.windowID)
        }
        (panel?.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
    }

    // MARK: 绑定跟随（B183：autoHide=false 默认模式——气泡跟目标窗走）

    /// 启动跟随：基线 = 唤起时目标窗位置与气泡位置；0.2s 轮询目标窗位移。
    func startFollowing(targetCGFrame: CGRect, bubbleOrigin: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        followWindowOrigin = InputBubbleLayout.appKitFrame(
            fromCGFrame: targetCGFrame, primaryScreenHeight: primaryHeight
        ).origin
        followBubbleOrigin = bubbleOrigin
        followTimer?.invalidate()
        let controller = InputBubbleController.shared
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.followTick() }
            }
        }
    }

    /// 终止跟随（dismiss / 提交收尾 / 自动隐藏模式唤起时幂等清场）。
    func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        followWindowOrigin = nil
        followBubbleOrigin = nil
        removeClickMonitor()
        voiceYielded = false
    }

    /// 跟随拍：目标窗位移 → 气泡保偏移平移（夹进所在屏可视区）。
    /// bounds 读不到（最小化/目标窗关闭中）= 原地停驻不跳；目标进程消失 = 随之关闭。
    /// B190 区间埋点：5Hz 主线程周期作业（CGWindowList 单窗读），在「打字卡顿」归因里
    /// 必须有账可查；journal 静默（journalQuietSections）不刷 64 条环。
    func followTick() {
        PerfMonitor.shared.beginSection("bubble.followTick")
        defer { PerfMonitor.shared.endSection() }
        guard phase == .open, let target, let panel,
              let windowBefore = followWindowOrigin, let bubbleBefore = followBubbleOrigin else { return }
        if NSRunningApplication(processIdentifier: target.pid) == nil {
            log("[InputBubble] follow: target app gone, dismissing", level: .debug)
            dismiss(reactivateTarget: false)
            return
        }
        guard let cgFrame = cgWindowBounds(for: target.windowID) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowNow = InputBubbleLayout.appKitFrame(
            fromCGFrame: cgFrame, primaryScreenHeight: primaryHeight
        ).origin
        let moved = InputBubbleLayout.followOrigin(
            bubbleOrigin: bubbleBefore,
            windowOriginBefore: windowBefore,
            windowOriginNow: windowNow
        )
        let appKitFrame = InputBubbleLayout.appKitFrame(fromCGFrame: cgFrame, primaryScreenHeight: primaryHeight)
        let clamped = InputBubbleLayout.clampedOrigin(
            position: moved,
            bubbleSize: panel.frame.size,
            visibleFrame: containingScreenVisibleFrame(for: appKitFrame)
        )
        if clamped != panel.frame.origin {
            suppressMoveTracking = true
            panel.setFrameOrigin(clamped)
            suppressMoveTracking = false
        }
        // 基线每拍推进（含未位移拍：窗口尺寸变化等场景不累积漂移）
        followWindowOrigin = windowNow
        followBubbleOrigin = clamped
        // B186：语音气泡让位巡检（每 5 拍≈1s；全表 CG 扫描频次控制在 ~5Hz→1Hz）
        voiceYieldScanCounter += 1
        if voiceYieldScanCounter % 5 == 0 {
            updateVoiceYield()
        }
    }

    /// B186：检测 LazyTyper 录音气泡是否在屏——在则降层让位、消失即恢复。
    /// 让位发生在录音气泡出现之后，不影响 LazyTyper 的活跃显示器解析（那一刻
    /// 我们的气泡仍是最顶层窗）。幂等，状态由 voiceYielded 持有。
    func updateVoiceYield() {
        guard phase == .open, let panel else { return }
        // B190 区间埋点：全表 CGWindowList 扫描 ~1Hz（跟随模式开着时），journal 静默同 followTick。
        PerfMonitor.shared.beginSection("bubble.voiceYield")
        defer { PerfMonitor.shared.endSection() }
        // 不筛 layer：LazyTyper 录音气泡实测 layer=5（floating 域），按 owner+尺寸识别
        let present = cgWindowListAll().contains { entry in
            entry.isOnScreen
                && InputBubbleLayout.isVoiceBubbleWindow(
                    ownerName: entry.ownerName,
                    width: entry.bounds?.width ?? 0,
                    height: entry.bounds?.height ?? 0)
        }
        switch InputBubbleVoiceYieldPlan.decide(voiceBubblePresent: present, alreadyYielded: voiceYielded) {
        case .yield:
            panel.level = .floating
            voiceYielded = true
            log("[InputBubble] voice bubble yield: level -> floating")
        case .restore:
            panel.level = .statusBar + 1
            voiceYielded = false
            log("[InputBubble] voice bubble gone: level restored", level: .debug)
        case .none:
            break
        }
    }

    /// B183：失焦后点击气泡 → 重新激活本 app 并恢复 textView 第一响应者（幂等）。
    func refocusPanel() {
        guard phase == .open, panel != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
        textView?.window?.makeFirstResponder(textView)
    }

    /// B183：气泡内任意点击 → 回焦。本地监视器覆盖 textView 等子视图吃掉的 mouseDown
    /// （nonactivatingPanel 点击不激活 app，绑定跟随模式失焦后必须能点回来打字）。
    func installClickMonitor() {
        removeClickMonitor()
        let controller = InputBubbleController.shared
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .otherMouseDown]) { event in
            if event.window === controller.panel {
                controller.refocusPanel()
            }
            return event
        }
    }

    func removeClickMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }

    // MARK: 提交（Enter / ⌘Enter / 提交钮）

    /// B175：气泡内提交钮（鼠标路径）——语义恒为「注入并提交」，与回车键位无关。
    @objc func submitButtonClicked() {
        submit(mode: .submit)
    }

    fileprivate func submit(mode: InputBubbleSubmitMode) {
        PerfMonitor.shared.beginSection("bubble.submit", fields: ["mode": String(describing: mode)])
        defer { PerfMonitor.shared.endSection() }
        guard phase == .open, let target = target, let textView = textView else { return }
        let text = textView.string
        // 第一拍纯决策：空文本/cancel 只关（此时校验事实未知，传 true 只走文本/模式分支）
        if case .dismissOnly = InputBubbleSubmitGate.decide(
            text: text, mode: mode, targetStillValid: true, frontmostMatchesTarget: true
        ) {
            dismiss(reactivateTarget: true)
            return
        }

        phase = .submitting
        panel?.orderOut(nil)

        saveClipboardThenWrite(text)

        // 把焦点还给目标终端（TitleEditor 同款 activate；此时 VibeFocus 是前台 app，激活放行）
        _ = NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: .activateIgnoringOtherApps)
        waitFrontmostAndInject(target: target, text: text, mode: mode, elapsedMs: 0)
    }
}

// MARK: - 文本事件（Enter/⌘Enter 在 keyDown 层拦截[B162]，Esc 走 doCommandBy，编辑实时存草稿）

extension InputBubbleController: NSTextViewDelegate {
    /// B162：InputBubbleTextView.keyDown 的 Enter/⌘Enter 拦截回调。
    /// 解析 nil = 不注入、插字面换行（默认交互 Enter 换行；⇧Enter 不会到达此处）。
    func handleEnter(commandHeld: Bool) {
        guard phase == .open else { return }
        if let mode = InputBubbleKeyPlan.resolveEnterAction(
            commandHeld: commandHeld,
            submitOnEnter: InputBubblePreferences.submitOnEnter
        ) {
            submit(mode: mode)
        } else {
            textView?.insertNewline(nil)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 到此的 insertNewline 只有 ⇧Enter / IME 路径（⌘Enter 在文本系统派发 noop:，
        // 从未到过这层——B129~B161 静默失效根因），一律默认行为：插入字面换行。
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc：关闭不注入，草稿保留（输入跟窗绑定，回来接着打）
            dismiss(reactivateTarget: true)
            return true
        default:
            return false
        }
    }

    /// B162：编辑实时落草稿（按目标窗绑定；提交成功由 inject 清除）
    func textDidChange(_ notification: Notification) {
        guard phase == .open, let target = target, let textView else { return }
        // B190 区间埋点：打字路径上的每次按键同步开销（store 内部有防抖，此区间量的是
        // 同步段）；打字卡顿归因时与 followTick/voiceYield 区分。
        PerfMonitor.shared.measure("bubble.draftSave") {
            InputBubbleDraftStore.shared.save(textView.string, for: target.windowID)
        }
    }
}

// MARK: - 面板失焦处置（B183 前提：autoHide=true 才失焦即关；默认绑定跟随不消失）；
//         拖动位置记忆 + 跟随基线同步

extension InputBubbleController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard phase == .open else { return }  // submitting 路径自己管理面板，不在此关
        // B183：「自动隐藏」开=旧行为失焦即关；关（默认）=绑定跟随，失焦不消失，
        // 气泡跟随目标窗（含跨屏与拖动），用 ✕ / Esc / 快捷键 / 提交 关闭。
        if case .dismiss = InputBubbleResignPlan.decide(autoHide: InputBubblePreferences.autoHide) {
            dismiss(reactivateTarget: false)
        }
    }

    /// B162：用户拖动气泡 → 记忆位置（下次唤起优先用）。程序化定位被
    /// suppressMoveTracking 抑制；非当前面板的 didMove 忽略。
    /// B183：拖动同时同步跟随基线——保住用户新偏移，不被下一拍拉回旧位。
    func windowDidMove(_ notification: Notification) {
        guard phase == .open, !suppressMoveTracking else { return }
        guard let moved = notification.object as? NSWindow, moved === panel else { return }
        InputBubblePreferences.userPlacedOrigin = moved.frame.origin
        if followBubbleOrigin != nil {
            followBubbleOrigin = moved.frame.origin
        }
    }

    // MARK: B175 尺寸联动（设置页滑杆 ↔ 打开中的气泡面板）

    /// 偏好尺寸变化（拖拽落账 / 设置页写穿广播）→ 打开中的面板实时 relayout。
    /// 面板已等于目标尺寸时跳过（拖拽落账路径先 applyPanelSize 再写偏好，
    /// 广播到达时幂等收敛，不二次 setFrame）。
    @objc func bubbleSizeDidChange(_ notification: Notification) {
        guard phase == .open, panel != nil else { return }
        let newSize = NSSize(
            width: InputBubblePreferences.bubbleWidth,
            height: InputBubblePreferences.bubbleHeight
        )
        guard let current = panel?.frame,
              abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5
        else { return }
        applyPanelSize(newSize)
    }
}
