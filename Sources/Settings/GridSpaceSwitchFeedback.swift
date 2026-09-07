import Foundation

// MARK: - Minimap live 切换反馈（纯映射）
/// 胶囊点击 live 切换结局 → 用户可见反馈文案（镜像 + Runner 真身双锁）。
/// 平台事实（2026-09-06 实测，v7 无 SA）：`space --focus` 直切必败；聚焦带动通道
/// 要求目标 space 上存在可管理窗口——空工作区切换必失败。失败必须如实说明，
/// 不许静默（用户报告的正是「点了没反应」的静默体验）。
enum GridSpaceSwitchFeedback {

    static func message(
        for outcome: RestoreSwitchOrchestration.PerspectiveRefocusOutcome,
        spaceIndex: Int
    ) -> String {
        switch outcome {
        case .noDrift:
            return "Space \(spaceIndex) 已是当前工作区"
        case .refocused:
            return "已切换到 Space \(spaceIndex)"
        case .failed:
            return "无法切换到 Space \(spaceIndex)：该工作区没有可聚焦的窗口（空工作区需要 SA 直切通道，本机未装）"
        }
    }
}
