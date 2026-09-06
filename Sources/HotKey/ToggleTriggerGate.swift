import Foundation
import CoreGraphics

/// 热键触发去重 + fallback 事件路由的纯判定（Batch 17，从
/// HotKeyManager+Monitors 的内联守卫提取——「⌃Q 死键/连发重复触发」是历史
/// 事故类，去重门与路由决策自此可单测穷尽）。
///
/// ## 语义契约（Tests/Runner 真身穷尽锁定）
/// - `ToggleTriggerGate.dedupDecision`：in-flight 最优先（一次触发未完成前一切
///   后续触发忽略）；其后「距上次触发 < dedupInterval 或距上次完成 <
///   cooldownInterval」视为重复丢弃；否则 accept。
/// - `ToggleTriggerGate.fallbackRoute`：isARepeat 一票忽略（系统自动连发不算
///   用户按键）；主热键命中优先于 TitleEditor Ctrl+T 与摆位表；fallback 仅在
///   各自开关开启时可达。
enum ToggleTriggerGate {

    enum DedupDecision: Equatable {
        case skipInFlight
        case skipDuplicate
        case accept
    }

    static func dedupDecision(
        isInFlight: Bool,
        sinceLastTrigger: TimeInterval,
        sinceLastCompletion: TimeInterval,
        dedupInterval: TimeInterval,
        cooldownInterval: TimeInterval
    ) -> DedupDecision {
        if isInFlight { return .skipInFlight }
        if sinceLastTrigger < dedupInterval || sinceLastCompletion < cooldownInterval {
            return .skipDuplicate
        }
        return .accept
    }

    /// fallback NSEvent 的路由结果（返回 false 语义 = ignore）。
    enum FallbackRoute: Equatable {
        case ignore
        case toggle
        case titleEditor
        case layout(LayoutAction)
    }

    /// CGEventTap 事件路由。tapDisabled 双形态触发自恢复（「热键失灵」事故类
    /// 的自愈决策）；非 keyDown / 自动连发放行给系统；命中主热键或摆位表则消费
    /// 事件（返回 nil 语义）；其余原样放行。layoutMatch 由调用方按开关扫描摆位
    /// 表得出（关闭/未命中传 nil）。
    enum CGTapDisableReason: Equatable { case timeout, userInput }

    enum CGHotkeyRoute: Equatable {
        case reenableTap(CGTapDisableReason)
        case ignore
        case toggle
        case layout(LayoutAction)
        case passThrough
    }

    static func cgEventRoute(
        type: CGEventType,
        isAutorepeat: Bool,
        primaryMatch: Bool,
        layoutMatch: LayoutAction?
    ) -> CGHotkeyRoute {
        if type == .tapDisabledByTimeout { return .reenableTap(.timeout) }
        if type == .tapDisabledByUserInput { return .reenableTap(.userInput) }
        guard type == .keyDown else { return .ignore }
        if isAutorepeat { return .ignore }
        if primaryMatch { return .toggle }
        if let layoutMatch { return .layout(layoutMatch) }
        return .passThrough
    }

    /// fallback 路由判定。layoutMatch 由调用方先行扫描摆位表得出（表内容随
    /// 用户配置变化，此处只裁决优先级：repeat 忽略 → 主热键 → TitleEditor → 摆位）。
    static func fallbackRoute(
        isARepeat: Bool,
        matchesPrimaryHotKey: Bool,
        titleEditorEnabledAndMatched: Bool,
        layoutMatch: LayoutAction?
    ) -> FallbackRoute {
        if isARepeat { return .ignore }
        if matchesPrimaryHotKey { return .toggle }
        if titleEditorEnabledAndMatched { return .titleEditor }
        if let layoutMatch { return .layout(layoutMatch) }
        return .ignore
    }
}
