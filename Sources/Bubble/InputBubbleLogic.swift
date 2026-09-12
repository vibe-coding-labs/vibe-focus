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

/// 气泡唤起热键计划（B162：默认 ⌘B + 设置页可自定义；三通道共用匹配）。
/// 组合键唯一事实源在 InputBubblePreferences.hotKey（持久化），此处的默认值
/// 与匹配纯函数供 Carbon/CGEventTap/NSEvent fallback 与 Runner 直测共用。
/// 冲突让位（主键/摆位键占用组合时不注册/不消费）在各注册通道内联判定。
enum InputBubbleHotKeyPlan {
    /// B162 默认 ⌘B（历史 ⌥⌘B 退役——用户指定默认改 ⌘B）。
    static let defaultConfig = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(cmdKey)
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

    /// 气泡底部快捷键提示文案（随回车语义同步，防文案与行为漂移）。
    static func hintText(submitOnEnter: Bool) -> String {
        submitOnEnter
            ? "Enter 注入并提交 · Shift+Enter 换行 · ⌘Enter 仅粘贴 · Esc 关闭"
            : "Enter 换行 · ⌘Enter 注入并提交 · Esc 关闭"
    }

    /// B162：气泡打开的初始文本 = 目标窗草稿优先（输入跟窗绑定，关了再开不丢）；
    /// 无草稿（含空白草稿）回落默认前缀。
    static func resolveInitialText(savedDraft: String?, prefix: String) -> String {
        if let draft = savedDraft,
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return draft
        }
        return prefix
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
/// toggle 记录的原位——与 UPS 的 userPlacedSkip 不冲突：B126 保护的是 ambient
/// hook 事件（语音流/后台提交）不得 Undo 用户放置，气泡提交是用户当下的动作
/// （2026-09-12 用户实测：SSH 窗手动移主屏 → 气泡提交 → 期望自动回副屏）。
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

    // MARK: 气泡内容布局（B175：提示文案 + 滚动输入区 + 提交钮 + 缩放把手）

    /// 按面板尺寸摆内容（唯一事实源：builtPanel 初建 / 拖拽 relayout / 设置页联动
    /// relayout 三方共用）。底栏右端依次提交钮、缩放把手；提示文案让位左对齐。
    static func contentFrames(for size: CGSize) -> (hint: CGRect, scroll: CGRect, button: CGRect, grip: CGRect) {
        let gripSide: CGFloat = 14
        let buttonSize = CGSize(width: 58, height: 18)
        let grip = CGRect(x: size.width - gripSide - 6, y: 7, width: gripSide, height: gripSide)
        let button = CGRect(
            x: grip.minX - 6 - buttonSize.width,
            y: 5,
            width: buttonSize.width,
            height: buttonSize.height
        )
        let hint = CGRect(x: 14, y: 8, width: max(button.minX - 14 - 6, 0), height: 14)
        let scroll = CGRect(x: 12, y: 26, width: size.width - 24, height: size.height - 40)
        return (hint, scroll, button, grip)
    }
}

/// 注入时序常量唯一事实源（执行器消费）。
enum InputBubbleTiming {
    /// 激活终端后等前台到位的轮询间隔 / 总预算
    static let frontmostPollIntervalMs: Int = 50
    static let frontmostPollBudgetMs: Int = 800
    /// ⌘V 与 Return 之间的间隔（留终端读 pasteboard 并渲染粘贴）
    static let pasteToReturnDelayMs: Int = 80
    /// 注入完成到恢复剪贴板的延迟
    static let clipboardRestoreDelayMs: Int = 500
}
