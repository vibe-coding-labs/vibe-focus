import AppKit
import Carbon
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// B129 输入气泡：纯决策层直测（热键匹配矩阵 / 键序计划 / 提交门判序 /
// 剪贴板恢复决策 / CG→AppKit 翻转 / 锚点布局双轴夹进与退化）。
// IO 编排（NSPanel/CGEvent/剪贴板读写）在 InputBubbleController，归真机 E2E。

extension RunnerHarness {
    func runInputBubbleTests() {
        print("\n=== InputBubble (B129) ===")

        // --- B188 唤起热键：默认 ⌃X 契约 + 配置化匹配矩阵 ---
        check("bubble hotkey: 默认配置 = ⌃X", InputBubbleHotKeyPlan.defaultConfig
            == HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey)))
        let bk = InputBubbleHotKeyPlan.defaultConfig
        check("bubble hotkey: ⌃X 命中", InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey)))
        check("bubble hotkey: ⌘B 不命中（旧默认退役）", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey)))
        check("bubble hotkey: ⌘X 不命中（修饰位错）", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey)))
        check("bubble hotkey: ⌃⌘X 不命中（多修饰）", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | cmdKey)))
        check("bubble hotkey: ⌃⇧X 不命中", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | shiftKey)))
        check("bubble hotkey: 其他键 ⌃ 不命中", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey)))
        check("bubble hotkey: 自定义配置按值匹配", InputBubbleHotKeyPlan.matches(
            config: HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)),
            keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey)))

        // --- 键序计划 ---
        check("keyPlan: submit = paste+return", InputBubbleKeyPlan.steps(for: .submit) == [.paste, .returnKey])
        check("keyPlan: pasteOnly = paste", InputBubbleKeyPlan.steps(for: .pasteOnly) == [.paste])
        check("keyPlan: cancel = 空", InputBubbleKeyPlan.steps(for: .cancel) == [])

        // --- 提交门判序 ---
        func gate(_ text: String, _ mode: InputBubbleSubmitMode, _ valid: Bool, _ front: Bool) -> InputBubbleSubmitGate.Outcome {
            InputBubbleSubmitGate.decide(text: text, mode: mode, targetStillValid: valid, frontmostMatchesTarget: front)
        }
        if case .dismissOnly = gate("", .submit, true, true) {
            check("gate: 空文本 → dismissOnly", true)
        } else { check("gate: 空文本 → dismissOnly", false) }
        if case .dismissOnly = gate("   \n ", .submit, true, true) {
            check("gate: 空白文本 → dismissOnly", true)
        } else { check("gate: 空白文本 → dismissOnly", false) }
        if case .dismissOnly = gate("hi", .cancel, true, true) {
            check("gate: cancel → dismissOnly", true)
        } else { check("gate: cancel → dismissOnly", false) }
        if case .dismissOnly = gate("", .submit, false, false) {
            check("gate: 空文本优先于目标校验", true)
        } else { check("gate: 空文本优先于目标校验", false) }
        if case .abortMissingTarget = gate("hi", .submit, false, true) {
            check("gate: 目标窗失效 → abortMissingTarget", true)
        } else { check("gate: 目标窗失效 → abortMissingTarget", false) }
        if case .abortFrontmostMismatch = gate("hi", .submit, true, false) {
            check("gate: 前台不符 → abortFrontmostMismatch", true)
        } else { check("gate: 前台不符 → abortFrontmostMismatch", false) }
        if case .proceed(let steps) = gate("hi", .submit, true, true), steps == [.paste, .returnKey] {
            check("gate: submit 放行 = paste+return", true)
        } else { check("gate: submit 放行 = paste+return", false) }
        if case .proceed(let steps) = gate("hi", .pasteOnly, true, true), steps == [.paste] {
            check("gate: pasteOnly 放行 = 仅 paste", true)
        } else { check("gate: pasteOnly 放行 = 仅 paste", false) }

        // --- 剪贴板恢复决策 ---
        check("clipboard: changeCount 未动 → 恢复", InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 42))
        check("clipboard: 用户又复制 → 不恢复", !InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 43))
        check("clipboard: count 异常回退 → 不恢复", !InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 41))

        // --- CG→AppKit y 翻转 ---
        check("layout: appKitY 翻转", InputBubbleLayout.appKitY(fromCGY: 100, primaryScreenHeight: 1117) == 1017)
        check("layout: appKitY 零点", InputBubbleLayout.appKitY(fromCGY: 1117, primaryScreenHeight: 1117) == 0)
        let cgFrame = CGRect(x: 100, y: 200, width: 600, height: 400)
        let akFrame = InputBubbleLayout.appKitFrame(fromCGFrame: cgFrame, primaryScreenHeight: 1117)
        check("layout: appKitFrame 整体翻转", akFrame == CGRect(x: 100, y: 517, width: 600, height: 400))

        // --- 锚点布局 ---
        let bubble = CGSize(width: 480, height: 150)
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // 常规：窗内左下 + margin
        let normal = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 常规贴窗左下内侧", normal == CGPoint(x: 116, y: 116))
        // 右缘夹进：窗太靠右，气泡左移保完整可见
        let rightClamped = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 1400, y: 100, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 右缘夹进 x=visible.max-宽-margin", rightClamped.x == 1728 - 480 - 16 && rightClamped.y == 116)
        // 下缘夹进：窗底越出屏幕（AppKit 坐标 minY < visible.minY）
        let bottomClamped = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 100, y: -50, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 下缘夹进 y=visible.min+margin", bottomClamped == CGPoint(x: 116, y: 16))
        // 副屏负坐标 visibleFrame（本机 P40UG 在主屏上方 = 负 y 区）
        let negVisible = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let negCase = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: -1800, y: -500, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: negVisible, margin: 16)
        check("anchor: 负坐标副屏正常锚定", negCase == CGPoint(x: -1784, y: -484))
        // 退化：气泡比屏宽 → 贴 visible 左缘不越界
        let degenerate = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
            bubbleSize: CGSize(width: 2000, height: 150),
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 800),
            margin: 16)
        check("anchor: 气泡比屏宽退化贴左缘", degenerate.x == 16 && degenerate.y == 66)

        // --- 时序常量存在性（执行器消费，防误删） ---
        check("timing: 轮询预算 > 间隔", InputBubbleTiming.frontmostPollBudgetMs > InputBubbleTiming.frontmostPollIntervalMs)
        check("timing: 粘贴→回车间隔与恢复延迟为正", InputBubbleTiming.pasteToReturnDelayMs > 0 && InputBubbleTiming.clipboardRestoreDelayMs > 0)

        // --- B133 尺寸归一（clamp 纯函数） ---
        check("prefs: 宽度未设置(0) → 默认 480", InputBubblePreferences.clampedWidth(0) == 480)
        check("prefs: 宽度步进取整 483 → 480", InputBubblePreferences.clampedWidth(483) == 480)
        check("prefs: 宽度越上界 9999 → 720", InputBubblePreferences.clampedWidth(9999) == 720)
        check("prefs: 宽度越下界 100 → 320", InputBubblePreferences.clampedWidth(100) == 320)
        check("prefs: 宽度合法值 600 保真", InputBubblePreferences.clampedWidth(600) == 600)
        check("prefs: 高度未设置(0) → 默认 150", InputBubblePreferences.clampedHeight(0) == 150)
        check("prefs: 高度步进取整 157 → 160", InputBubblePreferences.clampedHeight(157) == 160)
        check("prefs: 高度越上界 500 → 300", InputBubblePreferences.clampedHeight(500) == 300)
        check("prefs: 高度越下界 50 → 100", InputBubblePreferences.clampedHeight(50) == 100)

        // --- B133/B161 回车行为 → 解析矩阵（nil = 插入字面换行不注入） ---
        if case .submit = InputBubbleKeyPlan.resolveEnterAction(commandHeld: false, submitOnEnter: true) {
            check("enterAction: 回车即提交+无修饰 → submit", true)
        } else { check("enterAction: 回车即提交+无修饰 → submit", false) }
        if case .pasteOnly = InputBubbleKeyPlan.resolveEnterAction(commandHeld: true, submitOnEnter: true) {
            check("enterAction: 回车即提交+⌘ → pasteOnly", true)
        } else { check("enterAction: 回车即提交+⌘ → pasteOnly", false) }
        check("enterAction: 默认（关）+无修饰 → nil 换行", InputBubbleKeyPlan.resolveEnterAction(commandHeld: false, submitOnEnter: false) == nil)
        if case .submit = InputBubbleKeyPlan.resolveEnterAction(commandHeld: true, submitOnEnter: false) {
            check("enterAction: 默认（关）+⌘ → submit 发送", true)
        } else { check("enterAction: 默认（关）+⌘ → submit 发送", false) }

        // --- B133/B161 提示文案随行为同步 ---
        check("hint: 提交模式文案含「注入并提交」", InputBubbleKeyPlan.hintText(submitOnEnter: true).contains("注入并提交"))
        check("hint: 默认模式文案含「Enter 换行」与「⌘Enter 注入并提交」", InputBubbleKeyPlan.hintText(submitOnEnter: false).contains("Enter 换行") && InputBubbleKeyPlan.hintText(submitOnEnter: false).contains("⌘Enter 注入并提交"))

        // --- B176 提交后自动归位门（判序：偏好→提交语义→有记录→在主屏） ---
        func arGate(_ pref: Bool, _ submits: Bool, _ record: Bool, _ onMain: Bool) -> InputBubbleAutoRestoreGate.Outcome {
            InputBubbleAutoRestoreGate.decide(
                preferenceEnabled: pref, submits: submits,
                hasToggleRecord: record, isOnMainScreen: onMain)
        }
        check("autoRestore: 偏好关 → skipDisabled（哪怕其余全满足）",
              arGate(false, true, true, true) == .skipDisabled)
        check("autoRestore: 非提交（⌘Enter 仅粘贴）→ skipNotSubmitted",
              arGate(true, false, true, true) == .skipNotSubmitted)
        check("autoRestore: 无 toggle 记录（无从知原位）→ skipNoRecord",
              arGate(true, true, false, true) == .skipNoRecord)
        check("autoRestore: 窗不在主屏（本就在家）→ skipNotOnMain",
              arGate(true, true, true, false) == .skipNotOnMain)
        check("autoRestore: 全满足 → restore",
              arGate(true, true, true, true) == .restore)
        check("autoRestore: 判序优先级 偏好 > 提交（关+非提交）",
              arGate(false, false, false, false) == .skipDisabled)
        check("autoRestore: 判序优先级 提交 > 记录",
              arGate(true, false, false, false) == .skipNotSubmitted)
        check("autoRestore: 判序优先级 记录 > 主屏",
              arGate(true, true, false, false) == .skipNoRecord)
        check("keyPlan: submit 键序含 returnKey（归位触发语义）",
              InputBubbleKeyPlan.steps(for: .submit).contains(.returnKey))
        check("keyPlan: pasteOnly 键序不含 returnKey（不触发归位）",
              !InputBubbleKeyPlan.steps(for: .pasteOnly).contains(.returnKey))

        // --- B160 聚焦自动弹出决策门（判序：开关→气泡占用→终端→窗口变化→活跃绑定） ---
        func gate(_ auto: Bool, _ idle: Bool, _ term: Bool, _ changed: Bool, _ live: Bool) -> InputBubbleAutoShowGate.Outcome {
            InputBubbleAutoShowGate.decide(
                autoShowEnabled: auto, phaseIdle: idle, frontIsTerminal: term,
                windowChanged: changed, hasLiveSessionBinding: live)
        }
        if case .summon = gate(true, true, true, true, true) {
            check("autoshow: 全条件满足 → summon", true)
        } else { check("autoshow: 全条件满足 → summon", false) }
        if case .skipNotEnabled = gate(false, true, true, true, true) {
            check("autoshow: 开关关 → skipNotEnabled（⌥⌘B 不受影响）", true)
        } else { check("autoshow: 开关关 → skipNotEnabled（⌥⌘B 不受影响）", false) }
        if case .skipBubbleActive = gate(true, false, true, true, true) {
            check("autoshow: 气泡开着 → skipBubbleActive（lastSeen 冻结防回焦死循环）", true)
        } else { check("autoshow: 气泡开着 → skipBubbleActive（lastSeen 冻结防回焦死循环）", false) }
        if case .skipNotTerminal = gate(true, true, false, false, false) {
            check("autoshow: 前台非终端 → skipNotTerminal（离开域清标记）", true)
        } else { check("autoshow: 前台非终端 → skipNotTerminal（离开域清标记）", false) }
        if case .skipSameWindow = gate(true, true, true, false, true) {
            check("autoshow: 同窗 → skipSameWindow（注入回焦不重弹）", true)
        } else { check("autoshow: 同窗 → skipSameWindow（注入回焦不重弹）", false) }
        if case .skipNoLiveSession = gate(true, true, true, true, false) {
            check("autoshow: 无活跃会话绑定 → skipNoLiveSession（普通终端不弹）", true)
        } else { check("autoshow: 无活跃会话绑定 → skipNoLiveSession（普通终端不弹）", false) }
        // 气泡占用优先于「非终端清标记」：气泡开着时 lastSeen 冻结不被清
        let bubbleActiveOutcome = InputBubbleAutoShowGate.decide(
            autoShowEnabled: true, phaseIdle: false, frontIsTerminal: false,
            windowChanged: false, hasLiveSessionBinding: false)
        if case .skipBubbleActive = bubbleActiveOutcome {
            check("autoshow: 气泡开着+非终端 → 冻结优先于清标记", true)
        } else { check("autoshow: 气泡开着+非终端 → 冻结优先于清标记", false) }

        // --- B162 移回主屏自动弹出决策门 ---
        if case .summon = InputBubbleAutoShowGate.decideMoveToMainAutoShow(autoShowEnabled: true, phaseIdle: true) {
            check("moveToMain: 开+空闲 → summon", true)
        } else { check("moveToMain: 开+空闲 → summon", false) }
        if case .skipNotEnabled = InputBubbleAutoShowGate.decideMoveToMainAutoShow(autoShowEnabled: false, phaseIdle: true) {
            check("moveToMain: 开关关 → skipNotEnabled", true)
        } else { check("moveToMain: 开关关 → skipNotEnabled", false) }
        if case .skipBubbleActive = InputBubbleAutoShowGate.decideMoveToMainAutoShow(autoShowEnabled: true, phaseIdle: false) {
            check("moveToMain: 气泡占用 → skipBubbleActive", true)
        } else { check("moveToMain: 气泡占用 → skipBubbleActive", false) }

        // --- B180/B184 跨到主屏自动弹出决策门 v2（基线表版：lastSeenOnMain 按 windowID 查表，nil=无基线）---
        // B211 加 arrivalMover、B212 加 hasLiveSessionBinding——既有短路序断言传 .hookPull+true
        //（证明「能到 summon 的前提」下各短路仍先生效），summon/skip 分流断言见 B212 块。
        if case .skipNotEnabled = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: false, lastSeenOnMain: false, nowOnMain: true, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 开关关 → skipNotEnabled", true)
        } else { check("arrival: 开关关 → skipNotEnabled", false) }
        if case .skipNoBaseline = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: nil, nowOnMain: true, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 无基线 → skipNoBaseline", true)
        } else { check("arrival: 无基线 → skipNoBaseline", false) }
        if case .skipAlreadyOnMain = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: true, nowOnMain: true, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 已在主屏 → skipAlreadyOnMain", true)
        } else { check("arrival: 已在主屏 → skipAlreadyOnMain", false) }
        if case .skipAlreadyOnMain = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: true, nowOnMain: false, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 主屏移去别屏（反向，基线先短路）→ skipAlreadyOnMain", true)
        } else { check("arrival: 主屏移去别屏（反向，基线先短路）→ skipAlreadyOnMain", false) }
        if case .skipStillOffMain = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: false, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 同窗仍在非主屏 → skipStillOffMain", true)
        } else { check("arrival: 同窗仍在非主屏 → skipStillOffMain", false) }
        if case .summon = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: true, arrivalMover: .hookPull, hasLiveSessionBinding: true) {
            check("arrival: 基线非主屏→主屏 + hook 拉回 → summon", true)
        } else { check("arrival: 基线非主屏→主屏 + hook 拉回 → summon", false) }

        // --- B212 到达弹出语义终案：归因×绑定合取 ---
        // B211 全拦用户拉回属过度修正（装机后一早晨 21 次 skipUserMoved，用户复诉「不会
        // 自动弹了」）。终案：⌃Q 拉回挂活跃会话的窗 → 弹（用户工作流）；无绑定的窗
        //（E2E 测试窗/普通终端）与外部移动 → 静默（B211 主诉的噪音类）。
        if case .summon = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: true, arrivalMover: .userAction, hasLiveSessionBinding: true) {
            check("arrival B212: 跨越 + ⌃Q 拉回 + 挂活跃会话 → summon（恢复弹出）", true)
        } else { check("arrival B212: 跨越 + ⌃Q 拉回 + 挂活跃会话 → summon（恢复弹出）", false) }
        if case .skipNoLiveSession = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: true, arrivalMover: .userAction, hasLiveSessionBinding: false) {
            check("arrival B212: 跨越 + ⌃Q 拉回 + 无绑定（E2E 测试窗/普通终端）→ skipNoLiveSession（静默）", true)
        } else { check("arrival B212: 跨越 + ⌃Q 拉回 + 无绑定（E2E 测试窗/普通终端）→ skipNoLiveSession（静默）", false) }
        if case .skipExternalMove = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: true, arrivalMover: nil, hasLiveSessionBinding: true) {
            check("arrival B212: 跨越 + 无归因（外部 yabai/重排）→ skipExternalMove（绑定也救不回，恒静默）", true)
        } else { check("arrival B212: 跨越 + 无归因（外部 yabai/重排）→ skipExternalMove（绑定也救不回，恒静默）", false) }
        if case .summon = InputBubbleAutoShowGate.decideMoveToMainArrival(
            moveToMainEnabled: true, lastSeenOnMain: false, nowOnMain: true, arrivalMover: .hookPull, hasLiveSessionBinding: false) {
            check("arrival B212: hook 拉回不查绑定（SessionEnd 完成与拉回同拍）→ summon", true)
        } else { check("arrival B212: hook 拉回不查绑定（SessionEnd 完成与拉回同拍）→ summon", false) }
        check("mover B211: claudeSessionEnd → hookPull", InputBubbleArrivalMover.map(.claudeSessionEnd) == .hookPull)
        check("mover B211: manualHotkey → userAction", InputBubbleArrivalMover.map(.manualHotkey) == .userAction)
        check("mover B211: userPromptSubmit（B126 已退役搬窗）保守 → userAction", InputBubbleArrivalMover.map(.userPromptSubmit) == .userAction)

        // --- B211 归因账本：hook 拉回 10s 新鲜期内可弹，过期/覆盖/容量淘汰 ---
        let ledger = MoveToMainAttributionLedger.shared
        let ledgerNow = Date()
        ledger.record(windowID: 911_001, mover: .hookPull, at: ledgerNow)
        check("ledger B211: 新鲜期内读回 hookPull", ledger.recentMover(windowID: 911_001, now: ledgerNow.addingTimeInterval(5)) == .hookPull)
        check("ledger B211: 无记录窗 → nil（外部移动不弹）", ledger.recentMover(windowID: 911_099, now: ledgerNow) == nil)
        ledger.record(windowID: 911_002, mover: .hookPull, at: ledgerNow.addingTimeInterval(-11))
        check("ledger B211: 超 10s 新鲜期 → nil", ledger.recentMover(windowID: 911_002, now: ledgerNow) == nil)
        check("ledger B211: 新鲜期边界（恰好 10s）→ 仍可读", ledger.recentMover(windowID: 911_002, now: ledgerNow.addingTimeInterval(-1)) == .hookPull)
        ledger.record(windowID: 911_003, mover: .userAction, at: ledgerNow)
        check("ledger B211: ⌃Q 记账读回 userAction", ledger.recentMover(windowID: 911_003, now: ledgerNow) == .userAction)
        ledger.record(windowID: 911_003, mover: .hookPull, at: ledgerNow.addingTimeInterval(1))
        check("ledger B211: 同窗后继 hook 拉回覆盖 → 最新归因胜", ledger.recentMover(windowID: 911_003, now: ledgerNow.addingTimeInterval(1)) == .hookPull)
        ledger.record(windowID: 911_004, mover: .hookPull, at: ledgerNow.addingTimeInterval(2))
        ledger.record(windowID: 911_004, mover: .userAction, at: ledgerNow.addingTimeInterval(3))
        check("ledger B211: 同窗用户移动后覆盖 → userAction（后到语义胜）", ledger.recentMover(windowID: 911_004, now: ledgerNow.addingTimeInterval(3)) == .userAction)
        for idx in 0..<(MoveToMainAttributionLedger.capacity + 2) {
            ledger.record(windowID: UInt32(912_000 + idx), mover: .hookPull, at: ledgerNow)
        }
        check("ledger B211: 容量 32 FIFO——最旧两条被淘汰", ledger.recentMover(windowID: 912_000, now: ledgerNow) == nil
            && ledger.recentMover(windowID: 912_001, now: ledgerNow) == nil)
        check("ledger B211: 容量 32 FIFO——最新条目仍在", ledger.recentMover(windowID: UInt32(912_000 + MoveToMainAttributionLedger.capacity + 1), now: ledgerNow) == .hookPull)

        // --- B184 气泡开着时到达窗的处置门（跟随模式改绑/自动隐藏不打扰/本窗跟随已处理） ---
        if case .keepCurrent = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: true, openForWindowID: nil, arrivedWindowID: 42) {
            check("whileOpen: 自动隐藏模式 → keepCurrent（不打扰）", true)
        } else { check("whileOpen: 自动隐藏模式 → keepCurrent（不打扰）", false) }
        if case .keepCurrent = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: false, openForWindowID: 42, arrivedWindowID: 42) {
            check("whileOpen: 到达窗=气泡本窗 → keepCurrent（跟随已处理）", true)
        } else { check("whileOpen: 到达窗=气泡本窗 → keepCurrent（跟随已处理）", false) }
        if case .retarget = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: false, openForWindowID: 42, arrivedWindowID: 43) {
            check("whileOpen: 跟随模式异窗到达 → retarget（改绑）", true)
        } else { check("whileOpen: 跟随模式异窗到达 → retarget（改绑）", false) }
        if case .retarget = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: false, openForWindowID: nil, arrivedWindowID: 43) {
            check("whileOpen: 跟随模式无目标 → retarget", true)
        } else { check("whileOpen: 跟随模式无目标 → retarget", false) }
        // B195 输入中守卫：改绑让位输入连续性（真机七秒连改绑两次拽走打字主诉）
        if case .keepCurrent = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: false, openForWindowID: 42, arrivedWindowID: 43, isDirty: true) {
            check("whileOpen: 输入中异窗到达 → keepCurrent（不改绑）", true)
        } else { check("whileOpen: 输入中异窗到达 → keepCurrent（不改绑）", false) }
        if case .keepCurrent = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: true, openForWindowID: 42, arrivedWindowID: 43, isDirty: true) {
            check("whileOpen: 自动隐藏+输入中 → keepCurrent（判序在前）", true)
        } else { check("whileOpen: 自动隐藏+输入中 → keepCurrent（判序在前）", false) }
        if case .retarget = InputBubbleAutoShowGate.decideArrivalWhileBubbleOpen(
            autoHide: false, openForWindowID: 42, arrivedWindowID: 43, isDirty: false) {
            check("whileOpen: 干净气泡异窗到达 → retarget（B184 语义保持）", true)
        } else { check("whileOpen: 干净气泡异窗到达 → retarget（B184 语义保持）", false) }

        // --- B186 语音气泡让位（LazyTyper 录音气泡识别 + 让位决策） ---
        check("voiceYield: LazyTyper 320×170 录音气泡 ✓", InputBubbleLayout.isVoiceBubbleWindow(ownerName: "LazyTyper", width: 320, height: 170))
        check("voiceYield: 尺寸下界 280×140 ✓", InputBubbleLayout.isVoiceBubbleWindow(ownerName: "LazyTyper", width: 280, height: 140))
        check("voiceYield: 尺寸上界 400×220 ✓", InputBubbleLayout.isVoiceBubbleWindow(ownerName: "LazyTyper", width: 400, height: 220))
        check("voiceYield: 状态项 34×24 ✗", !InputBubbleLayout.isVoiceBubbleWindow(ownerName: "LazyTyper", width: 34, height: 24))
        check("voiceYield: 主窗 1300×818 ✗", !InputBubbleLayout.isVoiceBubbleWindow(ownerName: "LazyTyper", width: 1300, height: 818))
        check("voiceYield: 他 app 648×455 ✗", !InputBubbleLayout.isVoiceBubbleWindow(ownerName: "iTerm2", width: 648, height: 455))
        check("voiceYield: owner 空 ✗", !InputBubbleLayout.isVoiceBubbleWindow(ownerName: nil, width: 320, height: 170))
        if case .yield = InputBubbleVoiceYieldPlan.decide(voiceBubblePresent: true, alreadyYielded: false) {
            check("yieldPlan: 语音气泡出现且未让位 → yield", true)
        } else { check("yieldPlan: 语音气泡出现且未让位 → yield", false) }
        if case .restore = InputBubbleVoiceYieldPlan.decide(voiceBubblePresent: false, alreadyYielded: true) {
            check("yieldPlan: 语音气泡消失且已让位 → restore", true)
        } else { check("yieldPlan: 语音气泡消失且已让位 → restore", false) }
        if case .none = InputBubbleVoiceYieldPlan.decide(voiceBubblePresent: true, alreadyYielded: true) {
            check("yieldPlan: 已让位维持 → none", true)
        } else { check("yieldPlan: 已让位维持 → none", false) }
        if case .none = InputBubbleVoiceYieldPlan.decide(voiceBubblePresent: false, alreadyYielded: false) {
            check("yieldPlan: 均无 → none", true)
        } else { check("yieldPlan: 均无 → none", false) }

        // --- B210 初始文本恢复决策门（严格本窗草稿：窗草稿 > 前缀）。全局历史兜底
        //     已整个移除——用户两连定案（2026-09-18）：唤起绝不容忍「上一次内容」
        //     自动出现；历史里的旧草稿/已提交条目只能走 ↑↓/⌘Y 面板显式通道。 ---
        check("restore B210: 窗草稿非空白 → 本窗草稿", InputBubbleDraftRestorePlan.resolve(windowDraft: "打到一半", prefix: "/goal ") == (text: "打到一半", from: .windowDraft))
        check("restore B210: 空白窗草稿视为无草稿 → 前缀", InputBubbleDraftRestorePlan.resolve(windowDraft: "  \n ", prefix: "/goal ") == (text: "/goal ", from: .prefix))
        check("restore B210: 无窗草稿 → 前缀（历史旧草稿/已提交一概不回填）", InputBubbleDraftRestorePlan.resolve(windowDraft: nil, prefix: "/goal ") == (text: "/goal ", from: .prefix))
        check("restore B210: 双空+空前缀 → 空串", InputBubbleDraftRestorePlan.resolve(windowDraft: nil, prefix: "") == (text: "", from: .prefix))

        // --- B162 位置记忆编解码 + 夹取 ---
        let saved = CGRect(x: -1920.5, y: 100.25, width: 480, height: 150)
        check("frame: 编解码往返保真", InputBubbleLayout.decodeFrame(InputBubbleLayout.encodeFrame(saved)) == saved)
        check("frame: 非法串 → nil", InputBubbleLayout.decodeFrame("not-a-frame") == nil)
        check("frame: 分量不足 → nil", InputBubbleLayout.decodeFrame("1,2,3") == nil)
        let posVisible = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        check("clamped: 屏内原样保留", InputBubbleLayout.clampedOrigin(position: CGPoint(x: 300, y: 200), bubbleSize: bubble, visibleFrame: posVisible) == CGPoint(x: 300, y: 200))
        check("clamped: 越右缘拉回", InputBubbleLayout.clampedOrigin(position: CGPoint(x: 2000, y: 200), bubbleSize: bubble, visibleFrame: posVisible).x == 1728 - 480)
        check("clamped: 越下缘拉回", InputBubbleLayout.clampedOrigin(position: CGPoint(x: 300, y: -500), bubbleSize: bubble, visibleFrame: posVisible).y == 0)
        check("clamped: 宽超屏 x 贴左缘 y 屏内保留", InputBubbleLayout.clampedOrigin(position: CGPoint(x: 50, y: 50), bubbleSize: CGSize(width: 9000, height: 900), visibleFrame: posVisible) == CGPoint(x: 0, y: 50))
        check("clamped: 双轴退化全贴原点", InputBubbleLayout.clampedOrigin(position: CGPoint(x: 50, y: 50), bubbleSize: CGSize(width: 9000, height: 9000), visibleFrame: posVisible) == CGPoint(x: 0, y: 0))

        // --- B162 草稿存储（隔离 suite，真实存取行为） ---
        let suiteName = "RunnerInputBubbleDraftTests-\(UUID().uuidString)"
        let draftDefaults = UserDefaults(suiteName: suiteName)!
        let store = InputBubbleDraftStore(defaults: draftDefaults)
        store.save("窗口 A 的半截话", for: 1111)
        store.save("窗口 B 的内容", for: 2222)
        check("draft: 按窗读取各自独立", store.draft(for: 1111) == "窗口 A 的半截话" && store.draft(for: 2222) == "窗口 B 的内容")
        store.save("窗口 A 更新", for: 1111)
        check("draft: 同窗覆盖更新", store.draft(for: 1111) == "窗口 A 更新")
        // B178 防抖语义：save 只进 pending，未 flush 不落盘——同 suite 新实例读不到。
        let storeUnflushed = InputBubbleDraftStore(defaults: draftDefaults)
        check("draft: 防抖 pending 未落盘（跨实例不可见）", storeUnflushed.draft(for: 1111) == nil)
        store.flushPending()
        // 跨实例（重启语义）：同 suite 重建 store 仍可读（flush 后）
        let store2 = InputBubbleDraftStore(defaults: draftDefaults)
        check("draft: 持久化跨实例可读", store2.draft(for: 2222) == "窗口 B 的内容")
        store2.clear(for: 1111)
        check("draft: clear 后读 nil", store2.draft(for: 1111) == nil && store2.draft(for: 2222) == "窗口 B 的内容")
        store2.save("   ", for: 2222)
        check("draft: 空白保存等价清除（pending 路径）", store2.draft(for: 2222) == nil)
        // B178：clear 必须丢弃 pending——提交清稿后延后 flush 不得复活草稿。
        store2.save("复活嫌疑文本", for: 3333)
        store2.clear(for: 3333)
        store2.flushPending()
        check("draft: clear 丢弃 pending 不复活", store2.draft(for: 3333) == nil)
        store2.flushPending()
        check("draft: 全清后存储键移除", draftDefaults.data(forKey: "inputBubbleDrafts") == nil)
        draftDefaults.removePersistentDomain(forName: suiteName)

        // --- B162 草稿惰性清理（纯函数） ---
        let now = Date()
        func entry(ageSeconds: TimeInterval) -> InputBubbleDraftEntry {
            InputBubbleDraftEntry(text: "t", at: now.addingTimeInterval(-ageSeconds))
        }
        let pruned = InputBubbleDraftStore.prune(
            ["a": entry(ageSeconds: 8 * 24 * 3600), "b": entry(ageSeconds: 1 * 3600)],
            now: now, maxAge: 7 * 24 * 3600, capacity: 32)
        check("prune: 过期剔除", !pruned.keys.contains("a") && pruned.keys.contains("b"))
        var aged: [String: InputBubbleDraftEntry] = [:]
        for index in 0..<40 {
            // 越大越新（index 秒前写入）
            aged[String(index)] = InputBubbleDraftEntry(text: "t\(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        let capacityPruned = InputBubbleDraftStore.prune(aged, now: now, maxAge: 7 * 24 * 3600, capacity: 32)
        check("prune: 容量裁剪保留最新 32 条", capacityPruned.count == 32 && capacityPruned["39"] != nil && capacityPruned["7"] == nil)
    }
}

// MARK: - B195：全局输入历史环 + ↑↓ 翻阅计划 + 恢复决策门

extension RunnerHarness {
    func runBubbleHistoryTests() {
        print("\n=== BubbleHistory (B195) ===")

        // --- 历史环存取（隔离 suite，真实存取行为） ---
        let suiteName = "RunnerBubbleHistoryTests-\(UUID().uuidString)"
        let historyDefaults = UserDefaults(suiteName: suiteName)!
        let store = InputBubbleHistoryStore(defaults: historyDefaults)
        check("history: 空存储空条目", store.entries().isEmpty)
        store.record("第一条提示词")
        store.record("第二条提示词")
        check("history: 后记的在前（最新在前）", store.entries().map(\.text) == ["第二条提示词", "第一条提示词"])
        check("history: 最新一条在头部", store.entries().first?.text == "第二条提示词")
        store.record("第二条提示词")  // 与最新同文
        check("history: 与最新同文去重不重复入列", store.entries().map(\.text) == ["第二条提示词", "第一条提示词"] && store.entries().count == 2)
        store.record("   \n  ")
        check("history: 空白文本忽略", store.entries().count == 2)
        // 跨实例（重启语义）
        let store2 = InputBubbleHistoryStore(defaults: historyDefaults)
        check("history: 持久化跨实例可读", store2.entries().first?.text == "第二条提示词")

        // --- 草稿/已提交状态机（B196 记账 + append 晋升；B210 起恢复决策不读历史，
        //     状态仍驱动面板徽章与提交晋升） ---
        store.record("纯草稿一", status: .draft)
        store.record("提交条", status: .submitted)
        store.record("纯草稿二", status: .draft)
        store.record("纯草稿一", status: .submitted)  // 近端同文草稿晋升已提交
        check("history: 近端同文草稿晋升已提交（状态不降级、置顶刷新）",
              store.entries().first?.text == "纯草稿一"
              && store.entries().first?.status == .submitted
              && store.entries().first(where: { $0.text == "纯草稿二" })?.status == .draft)
        store2.clear()
        check("history: clear 后空", store2.entries().isEmpty && historyDefaults.data(forKey: "inputBubbleHistory") == nil)
        historyDefaults.removePersistentDomain(forName: suiteName)

        // --- 历史环纯函数：同文去重刷时间戳 / 时效与容量清理 ---
        let now = Date()
        func hEntry(_ text: String, ageSeconds: TimeInterval) -> InputBubbleHistoryEntry {
            InputBubbleHistoryEntry(text: text, at: now.addingTimeInterval(-ageSeconds))
        }
        let appended = InputBubbleHistoryStore.append(
            [hEntry("旧文本", ageSeconds: 10)],
            text: "旧文本  ", at: now)  // 去空白后同文 → 刷新不重复
        check("historyAppend: 同文（去空白比对）刷新不重复", appended.count == 1 && appended[0].at == now)
        let appendedNew = InputBubbleHistoryStore.append(
            [hEntry("旧文本", ageSeconds: 10)],
            text: "新文本", at: now)
        check("historyAppend: 新文插入最前", appendedNew.map(\.text) == ["新文本", "旧文本"])
        let expiredPruned = InputBubbleHistoryStore.prune(
            [hEntry("太老", ageSeconds: 31 * 24 * 3600), hEntry("新鲜", ageSeconds: 3600)],
            now: now, maxAge: 30 * 24 * 3600, capacity: 50)
        check("historyPrune: 过期剔除", expiredPruned.map(\.text) == ["新鲜"])
        var many: [InputBubbleHistoryEntry] = []
        for index in 0..<60 { many.append(hEntry("t\(index)", ageSeconds: TimeInterval(60 - index))) }
        let capPruned = InputBubbleHistoryStore.prune(many, now: now, maxAge: 30 * 24 * 3600, capacity: 50)
        check("historyPrune: 容量裁剪保最新 50 条", capPruned.count == 50 && capPruned.first?.text == "t0" && capPruned.last?.text == "t49")

        // --- B209 草稿快照折叠（同窗线性输入链=一条滚动草稿；文本永不蒸发） ---
        // 打字前进链：「我」→「我想」→「我想问一下」全部互为前缀 → 单条原位刷新
        var rolled = InputBubbleHistoryStore.appendDraftSnapshot(
            [], text: "我", at: now.addingTimeInterval(-3), windowID: 7, windowTitle: "w")
        rolled = InputBubbleHistoryStore.appendDraftSnapshot(
            rolled, text: "我想", at: now.addingTimeInterval(-2), windowID: 7, windowTitle: "w")
        rolled = InputBubbleHistoryStore.appendDraftSnapshot(
            rolled, text: "我想问一下", at: now.addingTimeInterval(-1), windowID: 7, windowTitle: "w2")
        check("snapshot: 打字前进链折叠单条滚动草稿（文本/时间戳/窗名刷新、置顶）",
              rolled.count == 1 && rolled[0].text == "我想问一下"
              && rolled[0].at == now.addingTimeInterval(-1)
              && rolled[0].windowTitle == "w2" && rolled[0].status == .draft)
        // 删后退链：新文本是旧文本前缀 → 同样原位替换（不堆「删字快照」）
        rolled = InputBubbleHistoryStore.appendDraftSnapshot(
            rolled, text: "我想问", at: now, windowID: 7, windowTitle: "w2")
        check("snapshot: 删退链同条折叠", rolled.count == 1 && rolled[0].text == "我想问")
        // 前缀无关（清空重写）→ 新条目，旧草稿保留（文本永不蒸发）
        rolled = InputBubbleHistoryStore.appendDraftSnapshot(
            rolled, text: "帮我看下这个报错", at: now, windowID: 7, windowTitle: "w2")
        check("snapshot: 前缀无关新草稿追加、旧草稿保留",
              rolled.count == 2 && rolled[0].text == "帮我看下这个报错" && rolled[1].text == "我想问")
        // 已提交条目永不被打字快照改写：头部 submitted 同前缀也不折叠
        let withSubmitted = [
            InputBubbleHistoryEntry(text: "我想问", at: now, windowID: 8, windowTitle: nil, status: .submitted),
        ]
        let afterSubmitted = InputBubbleHistoryStore.appendDraftSnapshot(
            withSubmitted, text: "我想问一下", at: now, windowID: 8, windowTitle: nil)
        check("snapshot: 已提交条目不被打字改写（新草稿条目独立）",
              afterSubmitted.count == 2 && afterSubmitted[0].status == .draft
              && afterSubmitted[1].status == .submitted && afterSubmitted[1].text == "我想问")
        // 跨窗独立：窗 9 的滚动草稿不接窗 7 的链
        let crossWin = InputBubbleHistoryStore.appendDraftSnapshot(
            rolled, text: "我想问一下", at: now, windowID: 9, windowTitle: nil)
        check("snapshot: 跨窗各归各的滚动链", crossWin.count == 3 && crossWin[0].windowID == 9)
        // windowID=nil（legacy 通道）落 append 语义
        let legacy = InputBubbleHistoryStore.appendDraftSnapshot(
            [], text: "无窗草稿", at: now, windowID: nil, windowTitle: nil)
        check("snapshot: windowID=nil 落 append 语义", legacy.count == 1 && legacy[0].windowID == nil && legacy[0].status == .draft)
        // 去空白比对：等值/空白差折叠
        let wsFold = InputBubbleHistoryStore.appendDraftSnapshot(
            [InputBubbleHistoryEntry(text: "  同文  ", at: now.addingTimeInterval(-5), windowID: 3, windowTitle: nil, status: .draft)],
            text: "同文", at: now, windowID: 3, windowTitle: nil)
        check("snapshot: 去空白等值折叠", wsFold.count == 1 && wsFold[0].text == "同文" && wsFold[0].at == now)
        // store 实例路径：recordDraftSnapshot 真实存取（隔离 suite）
        let snapSuite = "RunnerBubbleSnapTests-\(UUID().uuidString)"
        let snapDefaults = UserDefaults(suiteName: snapSuite)!
        let snapStore = InputBubbleHistoryStore(defaults: snapDefaults)
        snapStore.recordDraftSnapshot("第一", windowID: 5, windowTitle: nil)
        snapStore.recordDraftSnapshot("第一次", windowID: 5, windowTitle: nil)
        snapStore.recordDraftSnapshot("第一次输入", windowID: 5, windowTitle: nil)
        check("snapshot: store 连续三次快照只留一条滚动草稿",
              snapStore.entries().count == 1 && snapStore.entries()[0].text == "第一次输入")
        check("snapshot: 滚动草稿保持 draft 状态（B210 恢复决策仍可从本窗 DraftStore 续写）",
              snapStore.entries()[0].status == .draft)
        snapDefaults.removePersistentDomain(forName: snapSuite)

        // --- B213 历史上限可配置：默认 1000 / 偏好跟随 / 立即裁剪 ---
        // 用户定案（2026-09-19）：写死的 B196 容量 200 对面板数据源太紧且不可见，
        // 改为偏好可调（默认 1000，域 50~10000），store 动态跟随，设置页改值立即裁剪。
        check("limit B213: 默认 1000", InputBubblePreferences.historyLimitDefault == 1000)
        check("limit B213: 合法域 50~10000", InputBubblePreferences.historyLimitRange == (50, 10000))
        check("limit B213: 候选含默认 1000", InputBubblePreferences.historyLimitChoices.contains(1000))
        // 偏好读写与钳制（Runner 自身 standard 域，写后必清）
        UserDefaults.standard.removeObject(forKey: "inputBubbleHistoryLimit")
        defer { UserDefaults.standard.removeObject(forKey: "inputBubbleHistoryLimit") }
        check("limit B213: 未设置 → 默认 1000", InputBubblePreferences.historyLimit == 1000)
        InputBubblePreferences.historyLimit = 30
        check("limit B213: 低于下界 30 → 钳到 50", InputBubblePreferences.historyLimit == 50)
        InputBubblePreferences.historyLimit = 99999
        check("limit B213: 高于上界 99999 → 钳到 10000", InputBubblePreferences.historyLimit == 10000)
        // store 跟随偏好：无 override 的 store 容量=偏好值（域内值——低于 50 会被钳到 50）
        InputBubblePreferences.historyLimit = 100
        let limitSuite = "RunnerBubbleLimit-\(UUID().uuidString)"
        let limitDefaults = UserDefaults(suiteName: limitSuite)!
        let followStore = InputBubbleHistoryStore(defaults: limitDefaults)
        for idx in 1...120 {
            followStore.record("第\(idx)条", now: Date().addingTimeInterval(Double(idx) * 0.001))
        }
        check("limit B213: 记录 120 条、上限 100 → 只留最新 100 条",
              followStore.entries().count == 100 && followStore.entries()[0].text == "第120条"
                  && followStore.entries().last?.text == "第21条")
        // 既有条目超新上限 → applyLimitChange 立即裁剪（不等下一次懒清理）
        InputBubblePreferences.historyLimit = 60
        followStore.applyLimitChange()
        check("limit B213: 上限改 60 → 立即裁剪到 60 条",
              followStore.entries().count == 60 && followStore.entries()[0].text == "第120条")
        // override 注入仍优先（测试通道不回归）
        let overrideStore = InputBubbleHistoryStore(defaults: limitDefaults, capacity: 1)
        overrideStore.record("再记一条", now: Date().addingTimeInterval(99))
        check("limit B213: capacity override 注入优先于偏好", overrideStore.entries().count == 1)
        limitDefaults.removePersistentDomain(forName: limitSuite)

        // --- ↑↓ 翻阅计划（最新在前；↑ 变旧到最旧停住；↓ 变新走出回现场；空历史不消费） ---
        if case .moveTo(let index) = InputBubbleHistoryNavPlan.up(currentIndex: nil, entryCount: 3), index == 0 {
            check("navUp: 未翻阅 → 进入最新(0)", true)
        } else { check("navUp: 未翻阅 → 进入最新(0)", false) }
        if case .moveTo(let index) = InputBubbleHistoryNavPlan.up(currentIndex: 0, entryCount: 3), index == 1 {
            check("navUp: 0→1（变旧）", true)
        } else { check("navUp: 0→1（变旧）", false) }
        if case .moveTo(let index) = InputBubbleHistoryNavPlan.up(currentIndex: 2, entryCount: 3), index == 2 {
            check("navUp: 最旧停住", true)
        } else { check("navUp: 最旧停住", false) }
        if case .none = InputBubbleHistoryNavPlan.up(currentIndex: nil, entryCount: 0) {
            check("navUp: 空历史不消费", true)
        } else { check("navUp: 空历史不消费", false) }
        if case .none = InputBubbleHistoryNavPlan.down(currentIndex: nil, entryCount: 3) {
            check("navDown: 未在翻阅不消费", true)
        } else { check("navDown: 未在翻阅不消费", false) }
        if case .exitToStashed = InputBubbleHistoryNavPlan.down(currentIndex: 0, entryCount: 3) {
            check("navDown: 最新一条再↓ → 回编辑现场", true)
        } else { check("navDown: 最新一条再↓ → 回编辑现场", false) }
        if case .moveTo(let index) = InputBubbleHistoryNavPlan.down(currentIndex: 2, entryCount: 3), index == 1 {
            check("navDown: 2→1（变新）", true)
        } else { check("navDown: 2→1（变新）", false) }
    }
}

// MARK: - B175：鼠标提交钮 + 右下角拖拽调尺寸（纯几何 / 布局契约 / 通知联动契约）

extension RunnerHarness {
    func runBubbleResizeTests() {
        print("\n=== BubbleResize (B175) ===")

        // --- 拖拽实时尺寸：连续 clamp（拖拽中不步进量化，顺滑优先；松手才量化） ---
        let startSize = CGSize(width: 480, height: 150)
        check("resize: 零位移原样保留", InputBubbleLayout.resizedSize(startSize: startSize, widthDelta: 0, heightDelta: 0) == startSize)
        check("resize: 位移直接应用（正 heightDelta = 增高）", InputBubbleLayout.resizedSize(startSize: startSize, widthDelta: 40, heightDelta: 30) == CGSize(width: 520, height: 180))
        check("resize: 连续值不步进量化", InputBubbleLayout.resizedSize(startSize: startSize, widthDelta: 7, heightDelta: 0).width == 487)
        check("resize: 越上界钳制 720×300", InputBubbleLayout.resizedSize(startSize: startSize, widthDelta: 9999, heightDelta: 9999) == CGSize(width: 720, height: 300))
        check("resize: 越下界钳制 320×100", InputBubbleLayout.resizedSize(startSize: startSize, widthDelta: -9999, heightDelta: -9999) == CGSize(width: 320, height: 100))
        check("resize: 尺寸域取自 Preferences 单源", InputBubblePreferences.widthRange.min == 320 && InputBubblePreferences.heightRange.max == 300)

        // --- 左上角固定 origin 派生（AppKit y 向上） ---
        let startOrigin = CGPoint(x: 100, y: 200)
        check("origin: 等高 origin 不动", InputBubbleLayout.resizedOrigin(startOrigin: startOrigin, startSize: startSize, newSize: startSize) == startOrigin)
        check("origin: 增高 30 → origin 下移 30（左上固定）", InputBubbleLayout.resizedOrigin(startOrigin: startOrigin, startSize: startSize, newSize: CGSize(width: 480, height: 180)) == CGPoint(x: 100, y: 170))
        check("origin: 缩高 20 → origin 上移 20", InputBubbleLayout.resizedOrigin(startOrigin: startOrigin, startSize: startSize, newSize: CGSize(width: 480, height: 130)) == CGPoint(x: 100, y: 220))
        check("origin: 宽度变化不影响 origin", InputBubbleLayout.resizedOrigin(startOrigin: startOrigin, startSize: startSize, newSize: CGSize(width: 600, height: 150)) == startOrigin)

        // --- contentFrames 布局契约（最小/默认/最大三档扫描） ---
        for size in [CGSize(width: 320, height: 100), CGSize(width: 480, height: 150), CGSize(width: 720, height: 300)] {
            let frames = InputBubbleLayout.contentFrames(for: size)
            let label = "\(Int(size.width))x\(Int(size.height))"
            check("frames[\(label)]: 历史-提示-提交钮-把手从左到右不重叠",
                  frames.history.maxX <= frames.hint.minX && frames.hint.maxX <= frames.button.minX && frames.button.maxX <= frames.grip.minX)
            check("frames[\(label)]: 把手贴右缘在界内", frames.grip.maxX <= size.width && frames.grip.minX >= frames.button.maxX)
            check("frames[\(label)]: 底栏四件都落在底栏区(y≤26)", frames.button.maxY <= 26 && frames.grip.maxY <= 26 && frames.hint.maxY <= 26 && frames.history.maxY <= 26)
            check("frames[\(label)]: 滚动区在底栏上方且有正高度", frames.scroll.minY == 26 && frames.scroll.height > 0 && frames.scroll.maxY <= size.height)
            check("frames[\(label)]: 提示宽度为正", frames.hint.width > 0)
            check("frames[\(label)]: 历史钮在界内", frames.history.minX >= 0 && frames.history.maxX <= frames.hint.minX)
        }

        // --- 视图契约：把手不搬窗（与背景拖动移窗解耦） ---
        let handle = BubbleResizeHandleView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        check("handle: mouseDownCanMoveWindow=false", !handle.mouseDownCanMoveWindow)

        // --- 尺寸通知契约（设置页滑杆与打开面板联动的依赖） ---
        // 先存后清再还原（B84 家法）：不依赖 Runner 持久域的先行状态
        let savedWidth = InputBubblePreferences.bubbleWidth
        let savedHeight = InputBubblePreferences.bubbleHeight
        final class NoteProbe: NSObject {
            var count = 0
            @objc func hit(_ note: Notification) { count += 1 }
        }
        let probe = NoteProbe()
        NotificationCenter.default.addObserver(
            probe, selector: #selector(NoteProbe.hit(_:)),
            name: InputBubblePreferences.sizeDidChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(probe) }
        let probeWidth: Double = savedWidth == 520 ? 540 : 520
        let probeHeight: Double = savedHeight == 160 ? 170 : 160
        InputBubblePreferences.bubbleWidth = probeWidth
        InputBubblePreferences.bubbleHeight = probeHeight
        check("prefs: 改值各广播一次", probe.count == 2)
        InputBubblePreferences.bubbleWidth = probeWidth
        check("prefs: 同值写不广播", probe.count == 2)
        InputBubblePreferences.bubbleWidth = savedWidth
        InputBubblePreferences.bubbleHeight = savedHeight
        check("prefs: 还原广播且值复原", probe.count == 4
              && InputBubblePreferences.bubbleWidth == savedWidth
              && InputBubblePreferences.bubbleHeight == savedHeight)
    }
}

// MARK: - B164：唤起快捷键录制修复（录制器契约 / 录制让位标志 / summon 前台处置）

extension RunnerHarness {
    func runBubbleHotkeyRecorderTests() {
        print("\n=== BubbleHotkeyRecorder (B164) ===")

        // 录制器同款 NSEvent 工厂（B142 模式）
        func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            )!
        }

        // --- 录制转换契约：from(event:) 产出 Carbon 位，过校验、命中默认 ⌃X ---
        // 回归锁：旧实现直接塞 NSEvent.ModifierFlags.rawValue（⌃=1<<18），与 Carbon 位
        // （⌃=1<<12）完全错位——校验必败，三处录制自诞生起从未生效（用户报障根因）。
        let captured = HotKeyConfiguration.from(event: keyEvent(keyCode: UInt16(kVK_ANSI_X), modifiers: [.control]))
        check("recorder: ⌃X 捕获 keyCode = X", captured?.keyCode == UInt32(kVK_ANSI_X))
        check("recorder: ⌃X 捕获修饰位 = Carbon controlKey（非 NSEvent 位）",
              captured?.modifiers == UInt32(controlKey)
              && captured?.modifiers != UInt32(NSEvent.ModifierFlags.control.rawValue))
        check("recorder: 捕获配置与默认唤起键全等", captured == InputBubbleHotKeyPlan.defaultConfig)
        check("recorder: 捕获配置通过校验（旧 bug 卡死的一步）",
              captured != nil && HotKeyManager.validationError(for: captured!) == nil)
        check("recorder: 捕获配置命中气泡匹配", InputBubbleHotKeyPlan.matches(
            config: InputBubbleHotKeyPlan.defaultConfig,
            keyCode: captured?.keyCode ?? 0,
            carbonModifiers: captured?.modifiers ?? 0))
        // 自定义组合同样走通：⌃⌥R 捕获 → 过校验
        let customCaptured = HotKeyConfiguration.from(
            event: keyEvent(keyCode: UInt16(kVK_ANSI_R), modifiers: [.control, .option]))
        check("recorder: ⌃⌥R 捕获过校验",
              customCaptured?.modifiers == UInt32(controlKey | optionKey)
              && HotKeyManager.validationError(for: customCaptured!) == nil)
        check("recorder: 零修饰 keyDown 不捕获（维持录制）", HotKeyConfiguration.from(
            event: keyEvent(keyCode: UInt16(kVK_ANSI_R), modifiers: [])) == nil)

        // --- 录制让位判据（B165 活体派生：keyWindow.firstResponder 是否录制钮） ---
        // Runner 无 key 窗 → 恒 false；此前的布尔标志在设置窗 orderOut 不触发 resign
        // 时会卡 true，让位变成全部全局热键永久失灵——派生实现无卡死态。
        check("recordingState: 无 key 窗 → 非录制", !ShortcutRecordingState.isRecording)
        check("recordingState: nil 响应者 → 不让位", !ShortcutRecordingState.isRecordingResponder(nil))
        let recordingButton = ShortcutRecorderButton(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        check("recordingState: 录制钮 → 让位", ShortcutRecordingState.isRecordingResponder(recordingButton))
        let plainButton = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        check("recordingState: 普通按钮 → 不让位", !ShortcutRecordingState.isRecordingResponder(plainButton))
        let textViewResponder = NSTextView()
        check("recordingState: 非录制钮响应者 → 不让位", !ShortcutRecordingState.isRecordingResponder(textViewResponder))

        // --- ⌃T 标题编辑键占用（B165）：三处录制校验共用 validationError 单源 ---
        check("titleEditor: ⌃T 开启时拒绝（含提示语）",
              HotKeyManager.validationError(for: HotKeyConfiguration.titleEditor)?
              .contains("标题编辑") == true)
        check("titleEditor: 唯一事实源常量 = 17 + controlKey",
              HotKeyConfiguration.titleEditor == HotKeyConfiguration(
                  keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey)))
        check("titleEditor: ⌃⌥T 不误伤", HotKeyManager.validationError(
            for: HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))) == nil)
        let savedTitleEditorHK = TitleEditorPreferences.isHotKeyEnabled
        TitleEditorPreferences.isHotKeyEnabled = false
        check("titleEditor: 热键开关关闭 → ⌃T 释放可绑",
              HotKeyManager.validationError(for: HotKeyConfiguration.titleEditor) == nil)
        TitleEditorPreferences.isHotKeyEnabled = savedTitleEditorHK
        check("titleEditor: 开关恢复 → ⌃T 重新占用",
              HotKeyManager.validationError(for: HotKeyConfiguration.titleEditor) != nil)

        // --- B172 IME 组词态避让：marked text 时 Enter 不拦截（交给输入法确认候选） ---
        do {
            let tv = InputBubbleTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            var fired: [Bool] = []
            tv.onEnterKey = { fired.append($0) }
            let ret = keyEvent(keyCode: UInt16(kVK_Return), modifiers: [])
            let cmdRet = keyEvent(keyCode: UInt16(kVK_Return), modifiers: [.command])
            tv.keyDown(with: ret)
            check("ime: 无组词 Enter → 拦截回调（无 ⌘）", fired == [false])
            tv.keyDown(with: cmdRet)
            check("ime: 无组词 ⌘Enter → 拦截回调（携 ⌘）", fired == [false, true])
            // 每次探针前重置组词：组词态首个 Enter 经 super 即被输入法语义消费（确认候选），
            // marked 随之清除——这本身就是要放行达到的行为
            tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            check("ime: marked text 就位", tv.hasMarkedText())
            tv.keyDown(with: ret)
            check("ime: 组词态 Enter → 不拦截（放行输入法确认候选）", fired == [false, true])
            tv.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.keyDown(with: cmdRet)
            check("ime: 组词态 ⌘Enter → 不拦截（同样让位输入法）", fired == [false, true])
            tv.unmarkText()
            tv.keyDown(with: ret)
            check("ime: 组词清除后恢复拦截", fired == [false, true, false])
        }

        // --- summon 前台处置三态（ownApp 静默 / reject beep / proceed 捕获） ---
        check("summonGate: 自家 app 前台 → ownApp 静默", InputBubbleSummonGate.disposition(
            frontBundleID: AppIdentity.bundleID, isTerminalApp: false) == .ownApp)
        check("summonGate: 自家 bundle 优先于终端判定", InputBubbleSummonGate.disposition(
            frontBundleID: AppIdentity.bundleID, isTerminalApp: true) == .ownApp)
        check("summonGate: 他 app 非终端 → reject", InputBubbleSummonGate.disposition(
            frontBundleID: "com.apple.Safari", isTerminalApp: false) == .reject)
        check("summonGate: 终端前台 → proceed", InputBubbleSummonGate.disposition(
            frontBundleID: "com.googlecode.iterm2", isTerminalApp: true) == .proceed)
        check("summonGate: nil bundle 非终端 → reject", InputBubbleSummonGate.disposition(
            frontBundleID: nil, isTerminalApp: false) == .reject)
    }
}

// MARK: - B178：横向滚动策略契约（放不下就换行，永不横向滚动/漂移）

extension RunnerHarness {
    func runBubbleScrollPolicyTests() {
        print("\n=== BubbleScrollPolicy (B178) ===")

        // 真身 builtPanel 构建（含滚动视图策略与布局链）
        let controller = InputBubbleController.shared
        let (panel, textView) = controller.builtPanel()
        guard let scroll = textView.enclosingScrollView else {
            check("scroll: documentView 已挂 scroll", false)
            return
        }
        check("scroll: 显式禁用横向滚动条部件", !scroll.hasHorizontalScroller)
        check("scroll: 横向弹性 none（无横向手势滚动）", scroll.horizontalScrollElasticity == .none)
        check("scroll: 建成即非退化可视宽（无宽 0 窗口）", scroll.contentSize.width > 100)
        check("scroll: 容器宽跟踪文本视图", textView.textContainer?.widthTracksTextView == true)
        // Runner 无活窗口时 scroller 风格回落 legacy（给 documentView 多算 15px 槽），
        // 与生产（系统 overlay）不符；显式对齐后再锁宽度契约
        scroll.scrollerStyle = .overlay
        controller.applyPanelSize(NSSize(width: InputBubblePreferences.bubbleWidth, height: InputBubblePreferences.bubbleHeight))

        // 长不可断 token + 跳尾选区（用户场景）：横向零漂移、文档不宽于可视区
        let longToken = String(repeating: "a", count: 208)
        textView.string = longToken
        textView.setSelectedRange(NSRange(location: longToken.count, length: 0))
        (panel.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        check("scroll: 长文+跳尾选区后 clip x 归零", scroll.contentView.bounds.origin.x == 0)
        check("scroll: 长文+跳尾选区后 textView x 归零", textView.bounds.origin.x == 0)
        check("scroll: 文档不宽于可视区（横向放不下=换行/裁剪）",
              textView.frame.width <= scroll.contentView.bounds.width + 0.5)

        // 联动 relayout（拖拽落账/设置滑杆同路径）后依旧零漂移且宽度同步
        controller.applyPanelSize(NSSize(width: 640, height: 240))
        check("scroll: relayout 后横向仍归零", scroll.contentView.bounds.origin.x == 0 && textView.bounds.origin.x == 0)
        check("scroll: relayout 后宽度同步", abs(textView.frame.width - scroll.contentView.bounds.width) < 0.5)

        // 漂移注入→归零收殓能力（模拟暂态偏移残留）
        textView.setBoundsOrigin(NSPoint(x: 33, y: 0))
        (panel.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        check("scroll: 人为漂移可被归零收殓", textView.bounds.origin.x == 0)

        // 释放共享控制器状态，不污染其他域
        panel.orderOut(nil)
        controller.panel = nil
        controller.textView = nil
        controller.panelBuiltFor = nil
    }
}

// MARK: - B196：历史状态/窗口归属 + 过滤 + 宽松解码（草稿晋升、跨窗隔离）

extension RunnerHarness {
    func runBubbleHistoryPanelTests() {
        print("\n=== BubbleHistoryPanel (B196) ===")

        // --- append 头部合并规则 v2（同窗同文去重/草稿晋升/跨窗隔离） ---
        let now = Date()
        func entry(_ text: String, at: Date, windowID: UInt32?, status: InputBubbleHistoryStatus) -> InputBubbleHistoryEntry {
            InputBubbleHistoryEntry(text: text, at: at, windowID: windowID, windowTitle: "win", status: status)
        }
        // 草稿→已提交：同窗同文原地晋升，不新增条目
        let promoted = InputBubbleHistoryStore.append(
            [entry("同一个提示词", at: now.addingTimeInterval(-60), windowID: 100, status: .draft)],
            text: "同一个提示词", at: now, windowID: 100, windowTitle: "win2", status: .submitted)
        check("append: 同窗同文草稿→已提交 原地晋升", promoted.count == 1 && promoted[0].status == .submitted && promoted[0].at == now && promoted[0].windowTitle == "win2")
        // 已提交头部 + 同文草稿回写：不降级
        let notDemoted = InputBubbleHistoryStore.append(
            [entry("已提交文本", at: now.addingTimeInterval(-60), windowID: 100, status: .submitted)],
            text: "已提交文本", at: now, windowID: 100, status: .draft)
        check("append: 已提交头部不被草稿记录降级", notDemoted.count == 1 && notDemoted[0].status == .submitted)
        // 同文异窗：各归各的时间线，新条目
        let crossWindow = InputBubbleHistoryStore.append(
            [entry("同文", at: now.addingTimeInterval(-60), windowID: 100, status: .draft)],
            text: "同文", at: now, windowID: 200, status: .draft)
        check("append: 同文异窗 → 新条目不合并", crossWindow.count == 2 && crossWindow[0].windowID == 200 && crossWindow[1].windowID == 100)
        // 同窗同文同状态：只刷时间戳
        let refreshed = InputBubbleHistoryStore.append(
            [entry("草稿A", at: now.addingTimeInterval(-60), windowID: 100, status: .draft)],
            text: "草稿A", at: now, windowID: 100, status: .draft)
        check("append: 同窗同文同状态 → 只刷时间戳", refreshed.count == 1 && refreshed[0].at == now)
        // 异文：照常新增
        let newEntry = InputBubbleHistoryStore.append(
            [entry("旧草稿", at: now.addingTimeInterval(-60), windowID: 100, status: .draft)],
            text: "新草稿", at: now, windowID: 100, status: .draft)
        check("append: 异文照常新增", newEntry.count == 2 && newEntry[0].text == "新草稿")

        // --- 过滤口径：默认本窗 / 全部 / legacy 无窗条目只在全部 ---
        let mixed: [InputBubbleHistoryEntry] = [
            entry("窗A-1", at: now, windowID: 100, status: .submitted),
            entry("窗B-1", at: now.addingTimeInterval(-1), windowID: 200, status: .draft),
            InputBubbleHistoryEntry(text: "legacy", at: now.addingTimeInterval(-2)),  // 无 windowID
        ]
        let currentOnly = InputBubbleHistoryFilter.select(mixed, scope: .currentWindow, currentWindowID: 100)
        check("filter: 本窗只出该窗条目", currentOnly.map(\.text) == ["窗A-1"])
        let allWindows = InputBubbleHistoryFilter.select(mixed, scope: .all, currentWindowID: 100)
        check("filter: 全部含所有窗+legacy", allWindows.count == 3)
        check("filter: 无当前窗时本窗口径为空", InputBubbleHistoryFilter.select(mixed, scope: .currentWindow, currentWindowID: nil).isEmpty)

        // --- 宽松解码：B195 旧条目（无 status/windowID 字段）不拒解 ---
        let legacyJSON = "[{\"text\":\"旧数据\",\"at\":780000000.0}]"
        let legacyDecoded = try? JSONDecoder().decode([InputBubbleHistoryEntry].self, from: legacyJSON.data(using: .utf8)!)
        check("decode: legacy 条目补默认草稿态+nil窗", legacyDecoded?.count == 1 && legacyDecoded?[0].status == .draft && legacyDecoded?[0].windowID == nil && legacyDecoded?[0].text == "旧数据")
        let newJSON = "[{\"text\":\"新数据\",\"at\":780000000.0,\"windowID\":300,\"windowTitle\":\"t\",\"status\":\"submitted\"}]"
        let newDecoded = try? JSONDecoder().decode([InputBubbleHistoryEntry].self, from: newJSON.data(using: .utf8)!)
        check("decode: 新格式字段齐全保真", newDecoded?[0].windowID == 300 && newDecoded?[0].status == .submitted && newDecoded?[0].windowTitle == "t")

        // --- 存取闭环（隔离 suite）：状态化记录 + 晋升 + 删除 ---
        let suiteName = "RunnerBubbleHistoryPanelTests-\(UUID().uuidString)"
        let historyDefaults = UserDefaults(suiteName: suiteName)!
        let store = InputBubbleHistoryStore(defaults: historyDefaults)
        store.record("打到一半的草稿", windowID: 42, windowTitle: "bot-service", status: .draft)
        check("store: 草稿记录带窗归属", store.entries().count == 1 && store.entries()[0].windowID == 42 && store.entries()[0].status == .draft && store.entries()[0].windowTitle == "bot-service")
        store.record("打到一半的草稿", windowID: 42, windowTitle: "bot-service", status: .submitted)
        check("store: 提交晋升同一条", store.entries().count == 1 && store.entries()[0].status == .submitted)
        let entryID = store.entries()[0].at
        store.record("另一窗草稿", windowID: 43, status: .draft)
        store.remove(at: entryID)
        check("store: 按 at 删除单条", store.entries().count == 1 && store.entries()[0].text == "另一窗草稿")
        store.remove(at: now.addingTimeInterval(-9999))
        check("store: 删不存在条目静默", store.entries().count == 1)
        historyDefaults.removePersistentDomain(forName: suiteName)

        // --- 面板行几何契约：展开增高/收起固定/时间文本非空 ---
        let rowEntry = InputBubbleHistoryEntry(text: "行几何", at: now, windowID: 7, windowTitle: "w", status: .submitted)
        check("row: 收起高度固定", HistoryRowView.height(isExpanded: false) == 56)
        check("row: 展开高度=收起+全文区", HistoryRowView.height(isExpanded: true) == HistoryRowView.collapsedHeight + HistoryRowView.expandedExtraHeight)
        check("row: 时间文本非空", !HistoryRowView.timeText(for: now).isEmpty)
        _ = rowEntry
    }
}

extension RunnerHarness {
    /// B203：搜索过滤 / ↑↓ 翻阅口径 / 批量清空 / 填充防蒸发门。
    func runBubbleHistorySearchTests() {
        print("\n=== BubbleHistorySearch (B203) ===")

        let now = Date()
        func entry(_ text: String, windowID: UInt32?, title: String? = "win") -> InputBubbleHistoryEntry {
            InputBubbleHistoryEntry(
                text: text, at: now.addingTimeInterval(-Double(text.hashValue % 1000).magnitude),
                windowID: windowID, windowTitle: title, status: .draft
            )
        }

        // --- Filter.search：折叠子串匹配正文/窗名，空白查询透传 ---
        let corpus: [InputBubbleHistoryEntry] = [
            entry("Fix the LoginService bug", windowID: 1),
            entry("写单元测试", windowID: 2, title: "remote-server-001"),
            entry(" unrelated ", windowID: 3, title: "Finder"),
        ]
        check("search: 空查询透传全量", InputBubbleHistoryFilter.search(corpus, query: "").count == 3)
        check("search: 纯空白查询透传", InputBubbleHistoryFilter.search(corpus, query: "   \n ").count == 3)
        check("search: 大小写折叠命中", InputBubbleHistoryFilter.search(corpus, query: "loginservice").map(\.text) == ["Fix the LoginService bug"])
        check("search: 中文子串命中正文", InputBubbleHistoryFilter.search(corpus, query: "单元测试").map(\.text) == ["写单元测试"])
        check("search: 窗名命中（正文不含）", InputBubbleHistoryFilter.search(corpus, query: "remote-server").map(\.text) == ["写单元测试"])
        check("search: 全半角折叠命中", InputBubbleHistoryFilter.search(corpus, query: "ｌｏｇｉｎ").map(\.text) == ["Fix the LoginService bug"])
        check("search: 无命中返回空", InputBubbleHistoryFilter.search(corpus, query: "不存在的词xyz").isEmpty)
        check("search: 首尾空白查询裁剪后命中", InputBubbleHistoryFilter.search(corpus, query: "  login  ").count == 1)
        // legacy 无窗名条目：只按正文匹配，不崩
        let legacyOnly: [InputBubbleHistoryEntry] = [InputBubbleHistoryEntry(text: "legacy text", at: now)]
        check("search: legacy 无窗名按正文匹配", InputBubbleHistoryFilter.search(legacyOnly, query: "LEGACY").count == 1)

        // --- Filter.navEntries：本窗优先，本窗空回落全部（保留跨窗兜底） ---
        let mixed: [InputBubbleHistoryEntry] = [
            entry("窗A-1", windowID: 100),
            entry("窗B-1", windowID: 200),
            InputBubbleHistoryEntry(text: "legacy", at: now.addingTimeInterval(-9)),
        ]
        check("nav: 本窗有历史只翻本窗", InputBubbleHistoryFilter.navEntries(mixed, currentWindowID: 100).map(\.text) == ["窗A-1"])
        check("nav: 本窗无历史回落全部", InputBubbleHistoryFilter.navEntries(mixed, currentWindowID: 300).count == 3)
        check("nav: 无当前窗回落全部", InputBubbleHistoryFilter.navEntries(mixed, currentWindowID: nil).count == 3)
        check("nav: 空历史仍空", InputBubbleHistoryFilter.navEntries([], currentWindowID: 1).isEmpty)
        // 与面板同源：本窗口径 = select(.currentWindow)
        check("nav: 与面板本窗口径一致", InputBubbleHistoryFilter.navEntries(mixed, currentWindowID: 200) == InputBubbleHistoryFilter.select(mixed, scope: .currentWindow, currentWindowID: 200))

        // --- FillGuard：现场文本改动过且非空白才需要在覆盖前抢救 ---
        check("fill: 改动过非空白 → 抢救", InputBubbleFillGuard.shouldPreserveCurrent(currentText: "打到一半", baseText: ""))
        check("fill: 未改动 → 不抢救", !InputBubbleFillGuard.shouldPreserveCurrent(currentText: "同文", baseText: "同文"))
        check("fill: 改动过但空白 → 不抢救", !InputBubbleFillGuard.shouldPreserveCurrent(currentText: "  ", baseText: ""))
        check("fill: 基准非空被改动 → 抢救", InputBubbleFillGuard.shouldPreserveCurrent(currentText: "/goal 新内容", baseText: "/goal "))

        // --- append 近端合并（B203 续）：翻阅往返不再堆重复对 ---
        func dEntry(_ text: String, windowID: UInt32?, status: InputBubbleHistoryStatus) -> InputBubbleHistoryEntry {
            InputBubbleHistoryEntry(text: text, at: now.addingTimeInterval(-Double((text.hashValue % 900).magnitude)), windowID: windowID, windowTitle: "w", status: status)
        }
        // 往返翻阅：乙→甲→乙→甲 四次镜像记账只留 2 条（旧规则会堆出 4 条）
        var nav = [dEntry("甲文", windowID: 5, status: .draft)]
        nav = InputBubbleHistoryStore.append(nav, text: "乙文", at: now, windowID: 5, status: .draft)
        nav = InputBubbleHistoryStore.append(nav, text: "甲文", at: now, windowID: 5, status: .draft)
        nav = InputBubbleHistoryStore.append(nav, text: "乙文", at: now, windowID: 5, status: .draft)
        check("append: 往返翻阅收口不堆重复对", nav.count == 2 && nav[0].text == "乙文" && nav[1].text == "甲文")
        // 窗深内命中（深度 3）：置顶刷新不加条
        let deep = [
            dEntry("目标文", windowID: 6, status: .draft),
            dEntry("垫1", windowID: 6, status: .draft),
            dEntry("垫2", windowID: 6, status: .draft),
        ]
        let mergedDeep = InputBubbleHistoryStore.append(deep, text: "目标文", at: now, windowID: 6, status: .draft)
        check("append: 窗深内命中置顶刷新", mergedDeep.count == 3 && mergedDeep[0].text == "目标文" && mergedDeep[0].at == now && mergedDeep[1].text == "垫1")
        // 窗深外（第 9 条起）：照常新增
        var far: [InputBubbleHistoryEntry] = [dEntry("目标文", windowID: 7, status: .draft)]
        for i in 1...8 { far.insert(dEntry("垫\(i)", windowID: 7, status: .draft), at: 0) }
        let mergedFar = InputBubbleHistoryStore.append(far, text: "目标文", at: now, windowID: 7, status: .draft)
        check("append: 窗深外照常新增", mergedFar.count == 10 && mergedFar[0].text == "目标文" && mergedFar[0].at == now)
        // 深度命中已提交不降级 / 草稿晋升
        let notDemotedDeep = InputBubbleHistoryStore.append(
            [dEntry("已提交文", windowID: 8, status: .submitted), dEntry("垫", windowID: 8, status: .draft)],
            text: "已提交文", at: now, windowID: 8, status: .draft)
        check("append: 深度命中已提交不降级", notDemotedDeep.count == 2 && notDemotedDeep[0].status == .submitted)
        let promotedDeep = InputBubbleHistoryStore.append(
            [dEntry("草稿文", windowID: 9, status: .draft), dEntry("垫", windowID: 9, status: .draft)],
            text: "草稿文", at: now, windowID: 9, status: .submitted)
        check("append: 深度命中草稿晋升已提交", promotedDeep.count == 2 && promotedDeep[0].status == .submitted)
        // 深度内同文异窗：不合并
        let diffWinDeep = InputBubbleHistoryStore.append(
            [dEntry("同文", windowID: 10, status: .draft), dEntry("垫", windowID: 10, status: .draft)],
            text: "同文", at: now, windowID: 11, status: .draft)
        check("append: 深度内同文异窗仍新增", diffWinDeep.count == 3 && diffWinDeep[0].windowID == 11)

        // --- Store.remove(where:)：批量删除只动命中集 ---
        let suiteName = "RunnerBubbleHistorySearchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InputBubbleHistoryStore(defaults: defaults)
        store.record("甲", windowID: 1, status: .draft)
        store.record("乙", windowID: 2, status: .submitted)
        store.record("丙", windowID: 3, status: .draft)
        store.remove { $0.windowID == 2 }
        check("remove(where:): 只删命中窗", store.entries().map(\.text) == ["丙", "甲"])
        store.remove { _ in false }
        check("remove(where:): 零命中不动存储", store.entries().count == 2)
        store.remove { _ in true }
        check("remove(where:): 全命中清空", store.entries().isEmpty)
        defaults.removePersistentDomain(forName: suiteName)

        // --- scope × search 组合口径（面板 currentVisibleEntries 的纯函数镜像） ---
        let scoped = InputBubbleHistoryFilter.select(mixed, scope: .currentWindow, currentWindowID: 100)
        check("compose: 本窗内再搜索", InputBubbleHistoryFilter.search(scoped, query: "窗A").count == 1)
        let scopedAll = InputBubbleHistoryFilter.select(mixed, scope: .all, currentWindowID: 100)
        check("compose: 全部内搜索窗名", InputBubbleHistoryFilter.search(scopedAll, query: "win").count == 2)
    }
}

extension RunnerHarness {
    /// B204：⌘Y 历史面板快捷键决策 + 搜索框回车填充目标 + 底栏提示契约。
    func runBubbleHistoryPanelKeyTests() {
        print("\n=== BubbleHistoryPanelKey (B204) ===")

        // --- ⌘Y 识别：裸 ⌘+Y 命中，其余修饰组合/键位一律不命中 ---
        let yKey = UInt16(0x10)  // kVK_ANSI_Y
        check("key: ⌘Y 命中", InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: yKey, flags: .command))
        check("key: 裸 Y 不命中", !InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: yKey, flags: []))
        check("key: ⇧⌘Y 不命中", !InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: yKey, flags: [.command, .shift]))
        check("key: ⌥⌘Y 不命中", !InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: yKey, flags: [.command, .option]))
        check("key: ⌃⌘Y 不命中", !InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: yKey, flags: [.command, .control]))
        check("key: ⌘X 不命中", !InputBubbleHistoryPanelKeyPlan.isHistoryPanelToggle(keyCode: 0x07, flags: .command))

        // --- 搜索框回车的填充目标：第一条可见记录；空列表不动作 ---
        let now = Date()
        let visible = [
            InputBubbleHistoryEntry(text: "第一条", at: now, windowID: 1, windowTitle: "w", status: .draft),
            InputBubbleHistoryEntry(text: "第二条", at: now.addingTimeInterval(-1), windowID: 1, windowTitle: "w", status: .submitted),
        ]
        check("fill: 搜索回车取第一条可见", InputBubbleHistoryPanelKeyPlan.fillTarget(visible: visible)?.text == "第一条")
        check("fill: 空列表回车不动作", InputBubbleHistoryPanelKeyPlan.fillTarget(visible: []) == nil)

        // --- 底栏提示契约：两种回车键位模式都带 ⌘Y 面板提示（文案与行为防漂移） ---
        check("hint: ⌘Y 提示进底栏文案（提交模式）", InputBubbleKeyPlan.hintText(submitOnEnter: true).contains("⌘Y 历史面板"))
        check("hint: ⌘Y 提示进底栏文案（默认模式）", InputBubbleKeyPlan.hintText(submitOnEnter: false).contains("⌘Y 历史面板"))
    }

    /// B214：InputBubblePreferences 全偏好存取分支直测（此前 40% 函数覆盖——
    /// getter 缺省回落/setter 落库/尺寸广播/热键解码回落/用户摆位编解码全链未测）。
    /// Runner 二进制的 UserDefaults.standard 是自身独立域，与生产 app 隔离；用后清理。
    func runBubblePreferencesBranchTests() {
        func clearAll() {
            for key in ["inputBubbleEnabled", "inputBubbleWidth", "inputBubbleHeight",
                        "inputBubbleSubmitOnEnter", "inputBubbleAutoShowOnFocus",
                        "inputBubbleDefaultPrefix", "inputBubbleHotKeyConfiguration",
                        "inputBubbleAutoShowOnMoveToMain", "inputBubbleAutoRestoreOnSubmit",
                        "inputBubbleAutoHide", "inputBubbleUserFrame"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        clearAll()
        defer { clearAll() }

        // ===== 布尔偏好三态：未设置回落默认 / set 落库 / get 回读 =====
        check("prefs: isEnabled 未设置 → true（B129 默认开）", InputBubblePreferences.isEnabled == true)
        InputBubblePreferences.isEnabled = false
        check("prefs: isEnabled set false → 回读 false", InputBubblePreferences.isEnabled == false)
        check("prefs: submitOnEnter 未设置 → false（B161 Enter 换行默认）",
              InputBubblePreferences.submitOnEnter == false)
        InputBubblePreferences.submitOnEnter = true
        check("prefs: submitOnEnter set true → 回读 true", InputBubblePreferences.submitOnEnter == true)
        check("prefs: autoShowOnFocus 未设置 → true（B160 默认开）",
              InputBubblePreferences.autoShowOnFocus == true)
        InputBubblePreferences.autoShowOnFocus = false
        check("prefs: autoShowOnFocus set false → 回读 false", InputBubblePreferences.autoShowOnFocus == false)
        check("prefs: autoShowOnMoveToMain 未设置 → true（B162 默认开）",
              InputBubblePreferences.autoShowOnMoveToMain == true)
        InputBubblePreferences.autoShowOnMoveToMain = false
        check("prefs: autoShowOnMoveToMain set false → 回读 false",
              InputBubblePreferences.autoShowOnMoveToMain == false)
        check("prefs: autoRestoreOnSubmit 未设置 → true（B176 默认开）",
              InputBubblePreferences.autoRestoreOnSubmit == true)
        InputBubblePreferences.autoRestoreOnSubmit = false
        check("prefs: autoRestoreOnSubmit set false → 回读 false",
              InputBubblePreferences.autoRestoreOnSubmit == false)
        check("prefs: autoHide 未设置 → false（B183 跟随模式默认）",
              InputBubblePreferences.autoHide == false)
        InputBubblePreferences.autoHide = true
        check("prefs: autoHide set true → 回读 true", InputBubblePreferences.autoHide == true)

        // ===== defaultPrefix：缺省空串 + 原样保留尾随空格 =====
        check("prefs: defaultPrefix 未设置 → 空串", InputBubblePreferences.defaultPrefix == "")
        InputBubblePreferences.defaultPrefix = "  /goal  "
        check("prefs: defaultPrefix 尾随空格原样保留",
              InputBubblePreferences.defaultPrefix == "  /goal  ")

        // ===== 热键：未设置回落 defaultConfig / 坏数据回落 / 合法往返 =====
        check("prefs: hotKey 未设置 → defaultConfig",
              InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
        UserDefaults.standard.set(Data([0xFF, 0x00]), forKey: "inputBubbleHotKeyConfiguration")
        check("prefs: hotKey 坏 JSON → defaultConfig（手写 defaults 不致崩）",
              InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
        let custom = HotKeyConfiguration(keyCode: 7, modifiers: UInt32(controlKey))
        InputBubblePreferences.hotKey = custom
        check("prefs: hotKey 合法 JSON 往返", InputBubblePreferences.hotKey == custom)

        // ===== 尺寸：set 归一落库 + 变化广播 / 同值不广播（NoteProbe 家法） =====
        final class SizeProbe: NSObject {
            var count = 0
            @objc func hit(_ note: Notification) { count += 1 }
        }
        let sizeProbe = SizeProbe()
        NotificationCenter.default.addObserver(
            sizeProbe, selector: #selector(SizeProbe.hit(_:)),
            name: InputBubblePreferences.sizeDidChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(sizeProbe) }

        check("prefs: bubbleWidth 未设置 → 默认 480", InputBubblePreferences.bubbleWidth == 480)
        InputBubblePreferences.bubbleWidth = 300          // 低于下界 → 钳 320，广播
        check("prefs: bubbleWidth 300 → 钳 320", InputBubblePreferences.bubbleWidth == 320)
        InputBubblePreferences.bubbleWidth = 10000        // 超上界 → 钳 720
        check("prefs: bubbleWidth 10000 → 钳 720", InputBubblePreferences.bubbleWidth == 720)
        InputBubblePreferences.bubbleWidth = 505          // 步长 20 取整 → 500
        check("prefs: bubbleWidth 505 → 步进取整 500", InputBubblePreferences.bubbleWidth == 500)
        InputBubblePreferences.bubbleWidth = 500          // 首次落 500：变化 → 广播一次
        check("prefs: bubbleWidth 变化广播（拖拽落账/滑杆联动数据源）", sizeProbe.count >= 1)
        let beforeSame = sizeProbe.count
        InputBubblePreferences.bubbleWidth = 500          // 同值写 → 不广播（联动回路收敛）
        check("prefs: bubbleWidth 同值写不广播", sizeProbe.count == beforeSame)

        check("prefs: bubbleHeight 未设置 → 默认 150", InputBubblePreferences.bubbleHeight == 150)
        InputBubblePreferences.bubbleHeight = 40          // 低于下界 → 钳 100
        check("prefs: bubbleHeight 40 → 钳 100", InputBubblePreferences.bubbleHeight == 100)
        InputBubblePreferences.bubbleHeight = 99999       // 超上界 → 钳 300
        check("prefs: bubbleHeight 99999 → 钳 300", InputBubblePreferences.bubbleHeight == 300)
        InputBubblePreferences.bubbleHeight = 0           // 0 = 未设置语义 → 默认 150
        check("prefs: bubbleHeight 0 → 默认 150", InputBubblePreferences.bubbleHeight == 150)
        InputBubblePreferences.bubbleHeight = 155         // 步长 10 → 160
        check("prefs: bubbleHeight 155 → 步进取整 160", InputBubblePreferences.bubbleHeight == 160)

        // ===== userPlacedOrigin：nil 默认 / set 编码往返 / nil 写清除 =====
        check("prefs: userPlacedOrigin 未拖过 → nil", InputBubblePreferences.userPlacedOrigin == nil)
        InputBubblePreferences.userPlacedOrigin = CGPoint(x: 1234.5, y: -678.0)
        check("prefs: userPlacedOrigin 编码往返（含负 y 副屏区）",
              InputBubblePreferences.userPlacedOrigin == CGPoint(x: 1234.5, y: -678.0))
        InputBubblePreferences.userPlacedOrigin = nil
        check("prefs: userPlacedOrigin 写 nil → 清除", InputBubblePreferences.userPlacedOrigin == nil)
    }
}

extension RunnerHarness {
    /// B223：偏好读写全链直测——此前只测纯 clamp 函数，getter/setter 的
    /// UserDefaults 落账分支（三值默认门/写读一致/通知广播/解码失败回落）零覆盖。
    /// Runner 进程 UserDefaults.standard 是独立域（无 bundle id），逐项清理不外泄。
    func runBubblePreferencesIOTests() {
        print("\n=== BubblePreferencesIO (B223) ===")
        let d = UserDefaults.standard

        // --- 布尔偏好族：未设置默认 + 写读双向 + 清理复位 ---
        // isEnabled 默认 true；submitOnEnter 默认 false（B161）；autoShowOnFocus 默认 true（B160）；
        // autoShowOnMoveToMain 默认 true（B212 后语义=hook 拉回弹出）；autoRestoreOnSubmit 默认 true（B176）；
        // autoHide 默认 false（B183 绑定跟随模式）。
        let boolPrefs: [(key: String, get: () -> Bool, set: (Bool) -> Void, def: Bool)] = [
            ("inputBubbleEnabled", { InputBubblePreferences.isEnabled }, { InputBubblePreferences.isEnabled = $0 }, true),
            ("inputBubbleSubmitOnEnter", { InputBubblePreferences.submitOnEnter }, { InputBubblePreferences.submitOnEnter = $0 }, false),
            ("inputBubbleAutoShowOnFocus", { InputBubblePreferences.autoShowOnFocus }, { InputBubblePreferences.autoShowOnFocus = $0 }, true),
            ("inputBubbleAutoShowOnMoveToMain", { InputBubblePreferences.autoShowOnMoveToMain }, { InputBubblePreferences.autoShowOnMoveToMain = $0 }, true),
            ("inputBubbleAutoRestoreOnSubmit", { InputBubblePreferences.autoRestoreOnSubmit }, { InputBubblePreferences.autoRestoreOnSubmit = $0 }, true),
            ("inputBubbleAutoHide", { InputBubblePreferences.autoHide }, { InputBubblePreferences.autoHide = $0 }, false),
        ]
        for pref in boolPrefs {
            d.removeObject(forKey: pref.key)
            check("prefsIO: \(pref.key) 未设置默认 \(pref.def)", pref.get() == pref.def)
            pref.set(!pref.def)
            check("prefsIO: \(pref.key) 写 \(pref.def ? "false" : "true") 读 \(pref.def ? "false" : "true")", pref.get() == !pref.def)
            d.removeObject(forKey: pref.key)
            check("prefsIO: \(pref.key) 清除后回默认", pref.get() == pref.def)
        }

        // --- defaultPrefix：未设置空串；尾随空格原样保留（B161 契约） ---
        d.removeObject(forKey: "inputBubbleDefaultPrefix")
        check("prefsIO: defaultPrefix 未设置空串", InputBubblePreferences.defaultPrefix == "")
        InputBubblePreferences.defaultPrefix = "/goal "
        check("prefsIO: defaultPrefix 尾随空格保真", InputBubblePreferences.defaultPrefix == "/goal ")
        d.removeObject(forKey: "inputBubbleDefaultPrefix")

        // --- hotKey：未设置默认配置；写读往返；手写坏 JSON 回落默认（不崩） ---
        d.removeObject(forKey: "inputBubbleHotKeyConfiguration")
        check("prefsIO: hotKey 未设置回落默认",
              InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
        let custom = HotKeyConfiguration(keyCode: 0x07, modifiers: UInt32(controlKey))
        InputBubblePreferences.hotKey = custom
        check("prefsIO: hotKey 写读往返", InputBubblePreferences.hotKey == custom)
        d.set(Data("not-json".utf8), forKey: "inputBubbleHotKeyConfiguration")
        check("prefsIO: hotKey 坏 JSON 回落默认",
              InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
        d.removeObject(forKey: "inputBubbleHotKeyConfiguration")

        // --- historyLimit setter→getter：setter 不钳制、getter 兜底钳制（域 50~10000） ---
        d.removeObject(forKey: "inputBubbleHistoryLimit")
        InputBubblePreferences.historyLimit = 3000
        check("prefsIO: historyLimit 合法值写读", InputBubblePreferences.historyLimit == 3000)
        InputBubblePreferences.historyLimit = 1
        check("prefsIO: historyLimit 存 1 读 50（getter 下钳）", InputBubblePreferences.historyLimit == 50)
        InputBubblePreferences.historyLimit = 99999
        check("prefsIO: historyLimit 存 99999 读 10000（getter 上钳）", InputBubblePreferences.historyLimit == 10000)
        d.removeObject(forKey: "inputBubbleHistoryLimit")
        check("prefsIO: historyLimit 清除回默认 1000", InputBubblePreferences.historyLimit == InputBubblePreferences.historyLimitDefault)

        // --- userPlacedOrigin：nil 哨兵 + 写读往返 + 坏串回落 nil ---
        d.removeObject(forKey: "inputBubbleUserFrame")
        check("prefsIO: userPlacedOrigin 未拖过为 nil", InputBubblePreferences.userPlacedOrigin == nil)
        InputBubblePreferences.userPlacedOrigin = CGPoint(x: 111, y: 222)
        check("prefsIO: userPlacedOrigin 写读往返",
              InputBubblePreferences.userPlacedOrigin == CGPoint(x: 111, y: 222))
        d.set("garbage-frame", forKey: "inputBubbleUserFrame")
        check("prefsIO: userPlacedOrigin 坏串回落 nil", InputBubblePreferences.userPlacedOrigin == nil)
        InputBubblePreferences.userPlacedOrigin = nil
        check("prefsIO: userPlacedOrigin 置 nil 清键", d.object(forKey: "inputBubbleUserFrame") == nil)

        // --- 尺寸写穿：clamp 落账 + 变化广播/同值静默（B175 单源通知契约） ---
        d.removeObject(forKey: "inputBubbleWidth")
        d.removeObject(forKey: "inputBubbleHeight")
        check("prefsIO: bubbleWidth 未设置默认 480", InputBubblePreferences.bubbleWidth == 480)
        check("prefsIO: bubbleHeight 未设置默认 150", InputBubblePreferences.bubbleHeight == 150)
        final class CountBox: @unchecked Sendable { var count = 0 }  // 通知同步派发于同线程，计数无竞态
        let box = CountBox()
        let sizeToken = NotificationCenter.default.addObserver(
            forName: InputBubblePreferences.sizeDidChangeNotification, object: nil, queue: nil
        ) { _ in box.count += 1 }
        InputBubblePreferences.bubbleWidth = 500
        check("prefsIO: bubbleWidth 写 500 读 500 + 广播 1 次",
              InputBubblePreferences.bubbleWidth == 500 && box.count == 1)
        InputBubblePreferences.bubbleWidth = 500
        check("prefsIO: bubbleWidth 同值写不广播", box.count == 1)
        InputBubblePreferences.bubbleWidth = 9999
        check("prefsIO: bubbleWidth 越界写钳 720 + 广播",
              InputBubblePreferences.bubbleWidth == 720 && box.count == 2)
        InputBubblePreferences.bubbleWidth = 333
        check("prefsIO: bubbleWidth 步进取整 340 + 广播",
              InputBubblePreferences.bubbleWidth == 340 && box.count == 3)
        InputBubblePreferences.bubbleHeight = 250
        check("prefsIO: bubbleHeight 写 250 读 250 + 广播",
              InputBubblePreferences.bubbleHeight == 250 && box.count == 4)
        InputBubblePreferences.bubbleHeight = 9999
        check("prefsIO: bubbleHeight 越界写钳 300 + 广播",
              InputBubblePreferences.bubbleHeight == 300 && box.count == 5)
        NotificationCenter.default.removeObserver(sizeToken)
        d.removeObject(forKey: "inputBubbleWidth")
        d.removeObject(forKey: "inputBubbleHeight")
    }
}

// MARK: - B214：剪贴板快照写入与按决策恢复（NSPasteboard IO 面）

extension RunnerHarness {
    /// 用户剪贴板保护：测试开始先手工快照当前剪贴板，defer 无条件还原——
    /// 中途断言失败也不丢用户数据。断言载荷全程用 B214 专属字符串。
    func runBubbleClipboardIOTests() {
        print("\n=== BubbleClipboardIO (B214) ===")
        let controller = InputBubbleController.shared
        let pb = NSPasteboard.general

        struct RawItem { let pairs: [(NSPasteboard.PasteboardType, Data)] }
        var userSnapshot: [RawItem] = []
        if let items = pb.pasteboardItems {
            for item in items.prefix(5) {
                var pairs: [(NSPasteboard.PasteboardType, Data)] = []
                for t in item.types.prefix(10) where !t.rawValue.hasPrefix("dyn.") {
                    if let d = item.data(forType: t) { pairs.append((t, d)) }
                }
                if !pairs.isEmpty { userSnapshot.append(RawItem(pairs: pairs)) }
            }
        }
        func restoreUserClipboard() {
            pb.clearContents()
            for raw in userSnapshot {
                let item = NSPasteboardItem()
                for (t, d) in raw.pairs { item.setData(d, forType: t) }
                pb.writeObjects([item])
            }
        }
        defer { restoreUserClipboard() }

        // 状态复位（shared 单例，防其它域遗留态）
        controller.clipboardItems = []
        controller.clipboardPostWriteCount = -1

        // 1) guard 路：从未写入（-1）→ restore 无操作
        controller.restoreClipboardIfSafe()
        check("clip: 从未写入时 restore 无操作不崩溃", true)

        // 2) saveClipboardThenWrite：当前内容入快照、新文本上剪贴板
        pb.clearContents()
        pb.setString("B214-original", forType: .string)
        controller.saveClipboardThenWrite("B214-replacement")
        check("clip: 写入后剪贴板为新文本", pb.string(forType: .string) == "B214-replacement")
        check("clip: 快照持有原文本一项", controller.clipboardItems.count == 1)
        check("clip: postWriteCount 记录写入时 changeCount",
              controller.clipboardPostWriteCount == pb.changeCount)

        // 3) 期间无外部改动 → 快照回写
        controller.restoreClipboardIfSafe()
        check("clip: 无改动恢复原文本", pb.string(forType: .string) == "B214-original")
        check("clip: 恢复后计数复位 -1", controller.clipboardPostWriteCount == -1)
        check("clip: 恢复后快照清空", controller.clipboardItems.isEmpty)

        // 4) 期间外部改动 → skip 恢复（保留用户新内容）
        pb.clearContents()
        pb.setString("B214-original-2", forType: .string)
        controller.saveClipboardThenWrite("B214-replacement-2")
        pb.clearContents()
        pb.setString("user-typed", forType: .string)
        controller.restoreClipboardIfSafe()
        check("clip: 外部改动后放弃恢复（保留用户新内容）",
              pb.string(forType: .string) == "user-typed")
        check("clip: skip 后快照清空", controller.clipboardItems.isEmpty)
        check("clip: skip 后计数复位 -1", controller.clipboardPostWriteCount == -1)
    }
}

extension RunnerHarness {
    /// B234：气泡面板几何与 resize 拖拽状态机直测（真面板 builtPanel 缝，B178 家法）——
    /// begin/apply/finish 三态机（起点记录/左上角固定实时尺寸/量化落账+清起点）、
    /// phase 与起点双守卫 no-op、anchorOrigin 锚进屏可视区、containingScreenVisibleFrame、
    /// restoredOrigin 无记忆回落锚点/有记忆界内直返。偏好与控制器状态全程存-还+orderOut 清场。
    func runBubblePanelGeometryTests() {
        print("\n=== BubblePanelGeometry (B234) ===")
        let controller = InputBubbleController.shared
        let d = UserDefaults.standard
        let keys = ["inputBubbleWidth", "inputBubbleHeight", "inputBubbleUserFrame"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
        }
        d.removeObject(forKey: "inputBubbleUserFrame")

        guard let mainScreen = NSScreen.screens.first(where: { $0.isMainScreen }) else {
            check("panelGeo: 真机存在主屏（异常环境跳过）", false)
            return
        }
        controller.phase = .open
        let (panel, _) = controller.builtPanel()
        defer {
            panel.orderOut(nil)
            controller.panel = nil
            controller.textView = nil
            controller.panelBuiltFor = nil
            controller.phase = .idle
            controller.resizeDragStart = nil
        }

        // --- resize 拖拽三态机：begin 记起点 → apply 左上角固定实时尺寸 → finish 量化落账 ---
        controller.beginResizeDrag()
        check("panelGeo: begin 记录拖拽起点（原 origin/size）",
              controller.resizeDragStart != nil
              && controller.resizeDragStart?.size == panel.frame.size)
        let startOrigin = panel.frame.origin
        let startWidth = panel.frame.width
        let startHeight = panel.frame.height
        controller.applyResizeDrag(dx: 60, dy: -40)  // 把手右下，向下拖 dy 负=增高
        let topUnchanged = abs((panel.frame.origin.y + panel.frame.height) - (startOrigin.y + startHeight)) < 0.5
        check("panelGeo: apply 变宽变高且左上角（顶边）钉住",
              panel.frame.width > startWidth && panel.frame.height > startHeight
              && panel.frame.origin.x == startOrigin.x && topUnchanged)
        controller.finishResizeDrag()
        check("panelGeo: finish 量化落账与面板同步",
              controller.resizeDragStart == nil
              && InputBubblePreferences.bubbleWidth == panel.frame.width
              && InputBubblePreferences.bubbleHeight == panel.frame.height)
        let settledWidth = panel.frame.width

        // --- 守卫链：无起点 apply/finish no-op；phase 非 open 同样 no-op ---
        controller.applyResizeDrag(dx: 30, dy: 30)
        controller.finishResizeDrag()
        check("panelGeo: 无起点 apply/finish no-op", panel.frame.width == settledWidth)
        controller.beginResizeDrag()
        controller.phase = .idle
        let idleWidth = panel.frame.width
        controller.applyResizeDrag(dx: 50, dy: 0)
        check("panelGeo: phase 非 open apply no-op", panel.frame.width == idleWidth)
        controller.phase = .open

        // --- containingScreenVisibleFrame：屏 AppKit frame → 该屏 visibleFrame ---
        check("panelGeo: 包含屏可视帧解析",
              controller.containingScreenVisibleFrame(for: mainScreen.frame) == mainScreen.visibleFrame)

        // --- anchorOrigin：目标窗（主屏 Quartz）锚点落进主屏可视区 ---
        let mainQuartz = CGRect(
            x: mainScreen.frame.minX,
            y: CoordinateKit.mainScreenHeight - mainScreen.frame.maxY,
            width: mainScreen.frame.width, height: mainScreen.frame.height)
        let anchor = controller.anchorOrigin(targetCGFrame: mainQuartz)
        let anchorBubble = CGRect(origin: anchor, size: controller.bubbleSize)
        check("panelGeo: 锚点气泡整体夹进主屏可视区",
              insetNSRect(mainScreen.visibleFrame, -2).contains(anchorBubble))

        // --- restoredOrigin：无记忆回落锚点；有记忆界内直返记忆 ---
        check("panelGeo: 从未拖动 restoredOrigin=锚点",
              controller.restoredOrigin(targetCGFrame: mainQuartz) == anchor)
        let remembered = NSPoint(x: mainScreen.visibleFrame.minX + 30, y: mainScreen.visibleFrame.minY + 30)
        InputBubblePreferences.userPlacedOrigin = remembered
        check("panelGeo: 界内记忆原样返回",
              controller.restoredOrigin(targetCGFrame: mainQuartz) == remembered)
        // 屏外记忆被夹回可视区
        InputBubblePreferences.userPlacedOrigin = NSPoint(x: mainScreen.visibleFrame.maxX + 9999, y: mainScreen.visibleFrame.minY)
        let clamped = controller.restoredOrigin(targetCGFrame: mainQuartz)
        check("panelGeo: 屏外记忆夹回可视区",
              insetNSRect(mainScreen.visibleFrame, -2).contains(clamped))
    }

    private func insetNSRect(_ r: NSRect, _ by: CGFloat) -> NSRect { r.insetBy(dx: by, dy: by) }
}

extension RunnerHarness {
    /// B236：气泡跟随引擎 + ↑↓ 历史翻阅状态机直测（B 档第三批）。
    /// followOrigin 纯几何三态、startFollowing/stopFollowing 状态接线、
    /// followTick 无状态 no-op 与幽灵窗「原地停驻」分支（pid=Runner 自身存活、
    /// windowID 幽灵 → cgWindowBounds nil 分支）、↑↓ 翻阅全状态机（phase 守卫/
    /// up 消费变旧/最旧停住/down 走出最新回 stash 现场/未翻阅 down 不消费），
    /// 历史仓用 shared（Runner 独立 defaults 域）+ 前后 clear() 自清理。
    func runBubbleFollowNavTests() {
        print("\n=== BubbleFollowNav (B236) ===")
        let controller = InputBubbleController.shared
        let store = InputBubbleHistoryStore.shared

        // --- followOrigin 纯几何：零位移不动、位移保偏移平移、负位移反向 ---
        check("followNav: followOrigin 零位移原点不动",
              InputBubbleLayout.followOrigin(bubbleOrigin: CGPoint(x: 100, y: 80),
                                             windowOriginBefore: CGPoint(x: 50, y: 60),
                                             windowOriginNow: CGPoint(x: 50, y: 60))
                  == CGPoint(x: 100, y: 80))
        check("followNav: followOrigin 位移保相对偏移",
              InputBubbleLayout.followOrigin(bubbleOrigin: CGPoint(x: 100, y: 80),
                                             windowOriginBefore: CGPoint(x: 50, y: 60),
                                             windowOriginNow: CGPoint(x: 90, y: 20))
                  == CGPoint(x: 140, y: 40))
        check("followNav: followOrigin 负位移反向跟随",
              InputBubbleLayout.followOrigin(bubbleOrigin: CGPoint(x: 100, y: 80),
                                             windowOriginBefore: CGPoint(x: 90, y: 20),
                                             windowOriginNow: CGPoint(x: 50, y: 60))
                  == CGPoint(x: 60, y: 120))

        // --- startFollowing/stopFollowing 状态接线与清场 ---
        controller.startFollowing(targetCGFrame: CGRect(x: 0, y: 0, width: 800, height: 500),
                                  bubbleOrigin: CGPoint(x: 10, y: 10))
        check("followNav: startFollowing 记录基线并挂 0.2s 轮询",
              controller.followWindowOrigin != nil && controller.followBubbleOrigin == CGPoint(x: 10, y: 10)
              && controller.followTimer != nil)
        controller.stopFollowing()
        check("followNav: stopFollowing 幂等清场",
              controller.followWindowOrigin == nil && controller.followBubbleOrigin == nil
              && controller.followTimer == nil)

        // --- followTick 守卫链：无状态 no-op ---
        let idlePhase = controller.phase
        controller.followTick()
        check("followNav: 无状态 tick no-op", controller.phase == idlePhase)

        // --- followTick 幽灵窗「原地停驻」：pid 存活（Runner 自身）+ windowID 幽灵 ---
        store.clear()
        defer {
            store.clear()
            controller.stopFollowing()
            controller.panel?.orderOut(nil)
            controller.panel = nil
            controller.textView = nil
            controller.panelBuiltFor = nil
            controller.phase = .idle
            controller.target = nil
            controller.historyNavIndex = nil
            controller.historyStashedText = nil
        }
        controller.phase = .open
        let (panel, textView) = controller.builtPanel()
        controller.textView = textView
        let ghostTarget = InputBubbleController.Target(
            pid: ProcessInfo.processInfo.processIdentifier, bundleID: nil,
            windowID: 3_999_999_999, title: "ghost")
        controller.target = ghostTarget
        controller.startFollowing(targetCGFrame: CGRect(x: 0, y: 0, width: 800, height: 500),
                                  bubbleOrigin: CGPoint(x: 12, y: 34))
        let parkedFrame = panel.frame
        controller.followTick()
        check("followNav: 幽灵窗 tick 原地停驻（bounds 读不到不跳）",
              panel.frame == parkedFrame && controller.followWindowOrigin != nil
              && controller.phase == .open)

        // --- ↑↓ 翻阅状态机：phase 守卫 → up 变旧/最旧停 → down 回现场/未翻阅不消费 ---
        // phase=.idle 时先验证守卫
        controller.phase = .idle
        check("followNav: phase 非 open historyPrevious false", !controller.historyPrevious())
        controller.phase = .open
        textView.string = "现场文本"
        store.record("条目-e2", windowID: 777_001, windowTitle: "t", status: .submitted,
                     now: Date().addingTimeInterval(-60))
        store.record("条目-e1", windowID: 777_001, windowTitle: "t", status: .submitted,
                     now: Date().addingTimeInterval(-30))
        controller.target = InputBubbleController.Target(
            pid: ProcessInfo.processInfo.processIdentifier, bundleID: nil,
            windowID: 777_001, title: "t")
        check("followNav: 未翻阅时 historyNext 不消费", !controller.historyNext())
        check("followNav: 首次 up 消费跳最新一条（e1 比 e2 新）",
              controller.historyPrevious() && textView.string == "条目-e1")
        _ = controller.historyPrevious()  // 到最旧 e2
        check("followNav: 已到最旧再 up 停住（仍最旧条目）",
              controller.historyPrevious() && textView.string == "条目-e2")
        check("followNav: down 回到较新一条", controller.historyNext() && textView.string == "条目-e1")
        check("followNav: 走出最新回编辑现场",
              controller.historyNext() && textView.string == "现场文本")
        check("followNav: 现场还原后再 down 不消费", !controller.historyNext())
        store.clear()
    }
}
