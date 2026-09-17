import Carbon
import CoreGraphics
import Foundation

// MARK: - 输入气泡纯决策层（B129）
// ⌥⌘B 唤起本地输入气泡 → Enter 一次性注入聚焦终端（SSH 远程逐键回显卡顿的对症通道：
// 逐键输入每键等一个网络往返，粘贴注入是单次突发）。本文件只放可穷尽测试的纯函数
// 与常量；NSPanel 生命周期 / 剪贴板 IO / CGEvent 投递归 InputBubbleController。
// 直测：RunnerInputBubbleTests。

/// 提交语义（气泡内回车键位 → 注入动作）。
enum InputBubbleSubmitMode: Equatable {
    /// Enter：粘贴 + Return（Claude Code 提交提示词）
    case submit
    /// ⌘Enter：仅粘贴不提交（文本留在输入框继续编辑）
    case pasteOnly
    /// Esc：关闭不注入
    case cancel
}

/// 气泡唤起热键计划（B188：默认 ⌃X + 设置页可自定义；三通道共用匹配）。
/// 组合键唯一事实源在 InputBubblePreferences.hotKey（持久化），此处的默认值
/// 与匹配纯函数供 Carbon/CGEventTap/NSEvent fallback 与 Runner 直测共用。
/// 冲突让位（主键/摆位键占用组合时不注册/不消费）在各注册通道内联判定。
enum InputBubbleHotKeyPlan {
    /// B188 默认 ⌃X（历史 ⌘B 退役——用户指定默认改 ⌃X）。
    static let defaultConfig = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_X),
        modifiers: UInt32(controlKey)
    )

    /// 纯匹配：Carbon / CGEventTap / NSEvent fallback 三通道共用（carbon 修饰位语义）。
    static func matches(config: HotKeyConfiguration, keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        keyCode == config.keyCode && carbonModifiers == config.modifiers
    }
}

/// summon 对前台 app 的处置（B164 三态）：快捷键按下的瞬间按前台 bundle 裁决。
/// ownApp = 前台就是 VibeFocus 自己（用户在设置窗试键/录制）——静默退场不 beep，
/// beep 会被误读为「热键失灵」（真机实锤 01:11 四连）；reject = 非终端前台，beep 拒绝；
/// proceed = 终端前台，继续捕获目标窗。
enum InputBubbleSummonDisposition: Equatable {
    case ownApp
    case reject
    case proceed
}

enum InputBubbleSummonGate {
    static func disposition(frontBundleID: String?, isTerminalApp: Bool) -> InputBubbleSummonDisposition {
        if frontBundleID == AppIdentity.bundleID { return .ownApp }
        return isTerminalApp ? .proceed : .reject
    }
}

/// 键击序列计划：注入执行器按序投递（唯一事实源，执行器不自带分支）。
enum InputBubbleKeyPlan {
    enum Step: Equatable {
        case paste      // ⌘V（bracketed paste：多行不误提交、CJK 无 keycode 映射问题）
        case returnKey  // Return（提交）
    }

    static func steps(for mode: InputBubbleSubmitMode) -> [Step] {
        switch mode {
        case .submit: return [.paste, .returnKey]
        case .pasteOnly: return [.paste]
        case .cancel: return []
        }
    }

    /// B133/B161：Enter 键位 → 回车解析（唯一事实源，TextView 委托与提示文案共用）。
    /// 返回 nil = 不注入、插入字面换行。B161 默认交互：Enter 换行、⌘Enter 发送；
    /// 「回车即提交」开启时反转：Enter 发送、⌘Enter 仅粘贴。
    static func resolveEnterAction(commandHeld: Bool, submitOnEnter: Bool) -> InputBubbleSubmitMode? {
        if submitOnEnter {
            return commandHeld ? .pasteOnly : .submit
        }
        return commandHeld ? .submit : nil
    }

    /// 气泡底部快捷键提示文案（随回车语义同步，防文案与行为漂移）。B195：+↑↓ 历史。
    static func hintText(submitOnEnter: Bool) -> String {
        submitOnEnter
            ? "Enter 注入并提交 · Shift+Enter 换行 · ⌘Enter 仅粘贴 · ↑↓ 历史 · Esc 关闭"
            : "Enter 换行 · ⌘Enter 注入并提交 · ↑↓ 历史 · Esc 关闭"
    }
}

/// 唤起来源（B195）：恢复决策按来源分流——手动唤起给历史兜底，自动弹出保守。
enum InputBubbleSummonSource: Equatable {
    case manualHotKey   // ⌃X 快捷键（用户显式要输入）
    case autoShow       // 焦点/移主屏自动弹出（系统主动，不塞旧内容）
}

/// 气泡初始文本恢复决策门（B195，取代 B162 的草稿直读）。
/// 真机取证（2026-09-17）：生产 restoredDraft=true 仅 4/45 次——草稿按 CGWindowID
/// 绑定，窗一关一开 ID 换新即成孤儿，改绑/换窗唤起必落空前缀=用户主诉「重开被重置」。
/// 判序：窗草稿非空白 → 窗草稿（同窗续写）→ 手动唤起且有历史 → 最近一条输入
/// （跨窗兜底）→ 默认前缀。
enum InputBubbleDraftRestorePlan {
    enum Source: String, Equatable {
        case windowDraft   // 本窗草稿（CGWindowID 绑定）
        case history       // 全局最近输入（B195 兜底）
        case prefix        // 默认前缀（真·新输入）
    }

    static func resolve(
        windowDraft: String?,
        latestHistory: String?,
        source: InputBubbleSummonSource,
        prefix: String
    ) -> (text: String, from: Source) {
        if let draft = windowDraft,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (draft, .windowDraft)
        }
        if source == .manualHotKey,
           let history = latestHistory,
           !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (history, .history)
        }
        return (prefix, .prefix)
    }
}

/// ↑↓ 历史翻阅计划（B195）：entries 最新在前；currentIndex = 当前展示的历史条目
/// 下标（nil = 还在编辑现场，未进入翻阅）。↑ 逐条变旧（到最旧停住）；↓ 逐条变新，
/// 走出最新一条回到编辑现场（stash 的现场文本）。空历史不消费按键。
enum InputBubbleHistoryNavPlan {
    enum Action: Equatable {
        case none                 // 不消费（无历史）
        case moveTo(index: Int)   // 展示 entries[index]（首次进入自动 stash 现场）
        case exitToStashed        // 回编辑现场（恢复 stash）
    }

    static func up(currentIndex: Int?, entryCount: Int) -> Action {
        guard entryCount > 0 else { return .none }
        let next = (currentIndex ?? -1) + 1
        return .moveTo(index: min(next, entryCount - 1))
    }

    static func down(currentIndex: Int?, entryCount: Int) -> Action {
        guard let index = currentIndex else { return .none }
        return index <= 0 ? .exitToStashed : .moveTo(index: index - 1)
    }
}

/// 填充防蒸发门（B203）：面板「填充」会用历史文本整段覆盖气泡现场——若现场文本是
/// 用户改动过的（≠恢复基准）非空白内容，覆盖前必须先落一条草稿历史，兑现
/// 「文本永不蒸发」承诺（B198 前的回填会静默顶掉正在输入的草稿）。
enum InputBubbleFillGuard {
    /// true = 覆盖前先把现场文本存草稿历史。
    static func shouldPreserveCurrent(currentText: String, baseText: String) -> Bool {
        currentText != baseText
            && !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 注入前决策门（唯一判定点，执行器照办不二次判断）。
/// 判序：空文本/cancel 只关气泡 → 目标窗失效 beep 拒绝 → 前台不符 beep 拒绝 → 放行。
/// 严格性依据 B125 教训：宁可不注入，不可射进错窗。
enum InputBubbleSubmitGate {
    enum Outcome: Equatable {
        /// 执行 steps 注入
        case proceed(steps: [InputBubbleKeyPlan.Step])
        /// 空文本 / cancel：只关气泡，不动终端
        case dismissOnly
        /// 目标窗已不在（关窗/切 tab 后窗口柄对不上）：beep 拒绝
        case abortMissingTarget
        /// 激活后前台不是目标 app：防误注入别的 app
        case abortFrontmostMismatch
    }

    static func decide(
        text: String,
        mode: InputBubbleSubmitMode,
        targetStillValid: Bool,
        frontmostMatchesTarget: Bool
    ) -> Outcome {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mode == .cancel { return .dismissOnly }
        guard targetStillValid else { return .abortMissingTarget }
        guard frontmostMatchesTarget else { return .abortFrontmostMismatch }
        return .proceed(steps: InputBubbleKeyPlan.steps(for: mode))
    }
}

/// 剪贴板恢复决策：注入写入后若 changeCount 又变了（用户/其他 app 在注入窗口期复制），
/// 尊重新内容不恢复；changeCount 未动才回写快照。
enum InputBubbleClipboardPlan {
    /// postWriteCount = 我方写入完成后的 changeCount 快照。
    static func shouldRestore(postWriteCount: Int, currentCount: Int) -> Bool {
        currentCount == postWriteCount
    }
}

/// 提交后自动归位决策门（B176）。
/// 气泡提交（注入含 Return）= 用户显式「用完此窗」信号，注入落地后把窗还原到
/// toggle 记录的原位。2026-09-16 用户定案：直接在 Claude Code 输入框回车同样归位
/// （UPS 侧 userPlacedSkip 已退役，两链路语义一致）；「提交后自动归位」偏好关闭时
/// 气泡路径不动作，UPS 路径由 claudeHookAutoRestoreOnPromptSubmit 独立把关。
/// 判序：偏好关 → 非提交（⌘Enter 仅粘贴/Esc）→ 无 toggle 记录（无从知原位，
/// 诚实不动作）→ 窗不在主屏（本就在家/别处）→ 归位。
enum InputBubbleAutoRestoreGate {
    enum Outcome: Equatable {
        case restore
        case skipDisabled
        case skipNotSubmitted
        case skipNoRecord
        case skipNotOnMain
    }

    static func decide(
        preferenceEnabled: Bool,
        submits: Bool,
        hasToggleRecord: Bool,
        isOnMainScreen: Bool
    ) -> Outcome {
        guard preferenceEnabled else { return .skipDisabled }
        guard submits else { return .skipNotSubmitted }
        guard hasToggleRecord else { return .skipNoRecord }
        guard isOnMainScreen else { return .skipNotOnMain }
        return .restore
    }
}

/// 气泡锚点布局（AppKit 全局坐标，bottom-left 原点）：贴目标窗左下角内侧，
/// 水平/垂直双轴夹进屏幕 visibleFrame；退化（气泡比屏宽/高）时贴 visible 左/下缘。
enum InputBubbleLayout {

    /// CG 全局坐标（top-left 原点）y → AppKit 全局坐标 y。
    /// 主屏高度 = NSScreen.screens 首元素（含菜单栏主屏）frame.height，由调用方传入。
    static func appKitY(fromCGY cgY: CGFloat, primaryScreenHeight: CGFloat) -> CGFloat {
        primaryScreenHeight - cgY
    }

    /// CG 全局 frame → AppKit 全局 frame（仅 y 翻转；x 同轴）。
    static func appKitFrame(fromCGFrame cgFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgFrame.origin.x,
            y: appKitY(fromCGY: cgFrame.maxY, primaryScreenHeight: primaryScreenHeight),
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    /// 锚点 = 目标窗 minX/minY + margin（气泡坐在窗内左下），再双轴夹进 visibleFrame。
    static func anchorOrigin(
        targetAppKitFrame: CGRect,
        bubbleSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat
    ) -> CGPoint {
        let rawX = targetAppKitFrame.minX + margin
        let rawY = targetAppKitFrame.minY + margin
        let xLower = visibleFrame.minX + margin
        let yLower = visibleFrame.minY + margin
        // 退化保护：气泡比屏还宽/高时 upper 取下限，气泡仍完整落在屏内左/下缘
        let xUpper = max(visibleFrame.maxX - bubbleSize.width - margin, xLower)
        let yUpper = max(visibleFrame.maxY - bubbleSize.height - margin, yLower)
        return CGPoint(x: min(max(rawX, xLower), xUpper),
                       y: min(max(rawY, yLower), yUpper))
    }

    // MARK: 位置记忆（B162）

    /// 用户拖动记忆 frame 的持久化编码（AppKit 全局坐标 "x,y,w,h"）。
    static func encodeFrame(_ frame: CGRect) -> String {
        "\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
    }

    /// 位置记忆解码；格式不符回落 nil（按无记忆处理走锚点）。
    static func decodeFrame(_ raw: String) -> CGRect? {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// 用户记忆位置 → 目标屏 visibleFrame 内夹取（尺寸用当前气泡尺寸；
    /// 记忆位置在另一块屏/屏外时拉回屏内，退化同 anchorOrigin 取下限）。
    static func clampedOrigin(position: CGPoint, bubbleSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let xUpper = max(visibleFrame.maxX - bubbleSize.width, visibleFrame.minX)
        let yUpper = max(visibleFrame.maxY - bubbleSize.height, visibleFrame.minY)
        return CGPoint(x: min(max(position.x, visibleFrame.minX), xUpper),
                       y: min(max(position.y, visibleFrame.minY), yUpper))
    }

    // MARK: 右下角拖拽调尺寸（B175）

    /// 拖拽中的实时尺寸：连续 clamp 到合法域（不按步进量化——拖拽要顺滑，
    /// 松手时才经 clampedWidth/clampedHeight 量化并持久化）。
    static func resizedSize(startSize: CGSize, widthDelta: CGFloat, heightDelta: CGFloat) -> CGSize {
        let widthRange = InputBubblePreferences.widthRange
        let heightRange = InputBubblePreferences.heightRange
        return CGSize(
            width: min(max(startSize.width + widthDelta, widthRange.min), widthRange.max),
            height: min(max(startSize.height + heightDelta, heightRange.min), heightRange.max)
        )
    }

    /// 右下角拖拽 = 左上角固定（AppKit y 向上）：origin 随高度变化反向平移。
    static func resizedOrigin(startOrigin: CGPoint, startSize: CGSize, newSize: CGSize) -> CGPoint {
        CGPoint(x: startOrigin.x, y: startOrigin.y + (startSize.height - newSize.height))
    }

    // MARK: 语音气泡让位（B186：LazyTyper 录音气泡出现在我们气泡之上）

    /// 识别 LazyTyper 录音气泡窗口（事实源）：owner 含 LazyTyper 且尺寸落在
    /// 录音气泡域（320×170 逻辑 ± 容差）。状态项(34×24)/主窗(~1300×818)/他 app 均不匹配。
    static func isVoiceBubbleWindow(ownerName: String?, width: CGFloat, height: CGFloat) -> Bool {
        guard ownerName?.contains("LazyTyper") == true else { return false }
        return width >= 280 && width <= 400 && height >= 140 && height <= 220
    }

    // MARK: 气泡内容布局（B175：提示文案 + 滚动输入区 + 提交钮 + 缩放把手；B183：+关闭钮；
    //       B196：+历史入口钮贴底栏最左）

    /// 按面板尺寸摆内容（唯一事实源：builtPanel 初建 / 拖拽 relayout / 设置页联动
    /// relayout 三方共用）。底栏左→右：历史钮、提示文案；右端依次提交钮、缩放把手；
    /// B183 关闭钮（✕）贴右上角，压在滚动区上沿（子视图序在 scroll 之后=可点）。
    static func contentFrames(for size: CGSize) -> (hint: CGRect, scroll: CGRect, button: CGRect, grip: CGRect, close: CGRect, history: CGRect) {
        let gripSide: CGFloat = 14
        let buttonSize = CGSize(width: 58, height: 18)
        let grip = CGRect(x: size.width - gripSide - 6, y: 7, width: gripSide, height: gripSide)
        let button = CGRect(
            x: grip.minX - 6 - buttonSize.width,
            y: 5,
            width: buttonSize.width,
            height: buttonSize.height
        )
        // B196：历史入口钮贴最左（「历史」二字 10pt），提示文案让位其右
        let history = CGRect(x: 10, y: 6, width: 30, height: 14)
        let hint = CGRect(x: history.maxX + 5, y: 8, width: max(button.minX - history.maxX - 11, 0), height: 14)
        let scroll = CGRect(x: 12, y: 26, width: size.width - 24, height: size.height - 40)
        let closeSide: CGFloat = 16
        let close = CGRect(x: size.width - closeSide - 5, y: size.height - closeSide - 5, width: closeSide, height: closeSide)
        return (hint, scroll, button, grip, close, history)
    }

    // MARK: 跟随定位（B183：绑定跟随模式）

    /// 目标窗位移 → 气泡新 origin（保持用户看到的相对偏移，拖动过也保拖动偏移）。
    /// AppKit 全局坐标；越界夹取由调用方走 clampedOrigin + 所在屏可视区。
    static func followOrigin(
        bubbleOrigin: CGPoint,
        windowOriginBefore: CGPoint,
        windowOriginNow: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: bubbleOrigin.x + (windowOriginNow.x - windowOriginBefore.x),
            y: bubbleOrigin.y + (windowOriginNow.y - windowOriginBefore.y)
        )
    }
}

// MARK: - 语音气泡让位决策（B186：LazyTyper 录音气泡出现在我们气泡之上）

/// 我们的气泡开在 statusBar+1（保住 LazyTyper 活跃显示器解析=它的气泡出现瞬间读
/// 我们最顶层窗），检测到录音气泡出现后降到 .floating 让其浮在我们之上；录音气泡
/// 消失即恢复。alreadyYielded 即当前让位状态。
enum InputBubbleVoiceYieldPlan {
    enum Action: Equatable { case yield, restore, none }

    static func decide(voiceBubblePresent: Bool, alreadyYielded: Bool) -> Action {
        if voiceBubblePresent, !alreadyYielded { return .yield }
        if !voiceBubblePresent, alreadyYielded { return .restore }
        return .none
    }
}

// MARK: - 失焦处置决策（B183：绑定跟随模式开关）

/// 气泡失焦（windowDidResignKey）处置唯一事实源。
/// - autoHide=false（默认）：绑定跟随模式——失焦不消失，气泡跟随目标窗，
///   仅 ✕ / Esc / 快捷键 / 提交 关闭；
/// - autoHide=true：旧行为——失焦即隐藏。
enum InputBubbleResignPlan {
    enum Action: Equatable { case dismiss, stay }

    static func decide(autoHide: Bool) -> Action {
        autoHide ? .dismiss : .stay
    }
}

/// 注入时序常量唯一事实源（执行器消费）。
enum InputBubbleTiming {
    /// 激活终端后等前台到位的轮询间隔 / 总预算。
    /// B176：预算 800→2000ms——本机切窗延迟实测可超 800ms（iTerm2 多窗 +
    /// 高负载，见 P-INST 卡顿台账），且协作激活可能被推迟逐拍兑现；
    /// 成功路径首个轮询即返回，预算只影响「真失败时的放弃延迟」。
    static let frontmostPollIntervalMs: Int = 50
    static let frontmostPollBudgetMs: Int = 2000
    /// ⌘V 与 Return 之间的间隔（留终端读 pasteboard 并渲染粘贴）
    static let pasteToReturnDelayMs: Int = 80
    /// 注入完成到恢复剪贴板的延迟
    static let clipboardRestoreDelayMs: Int = 500
}
