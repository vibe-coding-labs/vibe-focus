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

/// 气泡热键 ⌥⌘B 常量与匹配（kVK_ANSI_B = 11）。
enum InputBubbleHotKey {
    static let keyCode: UInt32 = 11
    static let carbonModifiers: UInt32 = UInt32(optionKey | cmdKey)

    /// 纯匹配：Carbon / NSEvent fallback 通道用（carbon 修饰位语义）。
    /// CGEventTap 通道冲突感知（主键/摆位键让位）在 handleCGEvent 内联判定。
    static func matches(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        keyCode == Self.keyCode && carbonModifiers == Self.carbonModifiers
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
