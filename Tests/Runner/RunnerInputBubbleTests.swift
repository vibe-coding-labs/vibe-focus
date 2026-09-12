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

        // --- B162 唤起热键：默认 ⌘B 契约 + 配置化匹配矩阵 ---
        check("bubble hotkey: 默认配置 = ⌘B", InputBubbleHotKeyPlan.defaultConfig
            == HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey)))
        let bk = InputBubbleHotKeyPlan.defaultConfig
        check("bubble hotkey: ⌘B 命中", InputBubbleHotKeyPlan.matches(config: bk, keyCode: 11, carbonModifiers: UInt32(cmdKey)))
        check("bubble hotkey: 仅 ⌥ 不命中（⌥⌘B 退役）", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: 11, carbonModifiers: UInt32(optionKey)))
        check("bubble hotkey: ⌥⌘ 不命中（旧默认退役）", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: 11, carbonModifiers: UInt32(optionKey | cmdKey)))
        check("bubble hotkey: ⌃⌘ 不命中", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: 11, carbonModifiers: UInt32(controlKey | cmdKey)))
        check("bubble hotkey: ⌘+⇧ 不命中", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: 11, carbonModifiers: UInt32(cmdKey | shiftKey)))
        check("bubble hotkey: 其他键 ⌘ 不命中", !InputBubbleHotKeyPlan.matches(config: bk, keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey)))
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

        // --- B162 草稿预填解析（草稿优先，空白草稿回落前缀） ---
        check("prefill: 无草稿 → 前缀", InputBubbleKeyPlan.resolveInitialText(savedDraft: nil, prefix: "/goal ") == "/goal ")
        check("prefill: 草稿优先于前缀", InputBubbleKeyPlan.resolveInitialText(savedDraft: "打到一半", prefix: "/goal ") == "打到一半")
        check("prefill: 空白草稿视为无草稿", InputBubbleKeyPlan.resolveInitialText(savedDraft: "  \n ", prefix: "/goal ") == "/goal ")
        check("prefill: 双空 → 空串", InputBubbleKeyPlan.resolveInitialText(savedDraft: nil, prefix: "") == "")

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
            check("frames[\(label)]: 提示-提交钮-把手从左到右不重叠",
                  frames.hint.maxX <= frames.button.minX && frames.button.maxX <= frames.grip.minX)
            check("frames[\(label)]: 把手贴右缘在界内", frames.grip.maxX <= size.width && frames.grip.minX >= frames.button.maxX)
            check("frames[\(label)]: 底栏三件都落在底栏区(y≤26)", frames.button.maxY <= 26 && frames.grip.maxY <= 26 && frames.hint.maxY <= 26)
            check("frames[\(label)]: 滚动区在底栏上方且有正高度", frames.scroll.minY == 26 && frames.scroll.height > 0 && frames.scroll.maxY <= size.height)
            check("frames[\(label)]: 提示宽度为正", frames.hint.width > 0)
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

        // --- 录制转换契约：from(event:) 产出 Carbon 位，过校验、命中默认 ⌘B ---
        // 回归锁：旧实现直接塞 NSEvent.ModifierFlags.rawValue（⌘=1<<20），与 Carbon 位
        // （⌘=1<<8）完全错位——校验必败，三处录制自诞生起从未生效（用户报障根因）。
        let captured = HotKeyConfiguration.from(event: keyEvent(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command]))
        check("recorder: ⌘B 捕获 keyCode = B", captured?.keyCode == UInt32(kVK_ANSI_B))
        check("recorder: ⌘B 捕获修饰位 = Carbon cmdKey（非 NSEvent 位）",
              captured?.modifiers == UInt32(cmdKey)
              && captured?.modifiers != UInt32(NSEvent.ModifierFlags.command.rawValue))
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
