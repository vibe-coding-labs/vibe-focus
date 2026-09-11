import Foundation

// MARK: - Minimap live 切换反馈（纯映射）
/// 胶囊点击 live 切换结局 → 用户可见反馈文案（Runner 真身直测）。
/// 平台事实（2026-09-06 实测；2026-09-12 复核）：本机 yabai SA 被 SIP 拦截
/// （`space --focus` 报 "error with the scripting-addition"，exit 1）；聚焦带动通道
/// 要求目标 space 上存在可管理窗口——空工作区且不可见时切换必失败。失败必须如实
/// 说明，不许静默（用户报告的正是「点了没反应」的静默体验）。
/// 已可见的目标（B164 按目标屏可见性判定）走 noDrift 成功，不再误入失败文案。
/// 工作区标注语言 =「屏号-位次」（调用方经 ScreenLayoutMapper.userVisibleSpaceLabel
/// 解出后传入；快照缺失时调用方回退 "Space 全局号"）。
enum GridSpaceSwitchFeedback {

    static func message(
        for outcome: RestoreSwitchOrchestration.PerspectiveRefocusOutcome,
        label: String
    ) -> String {
        switch outcome {
        case .noDrift:
            return "\(label) 已是当前工作区"
        case .refocused:
            return "已切换到 \(label)"
        case .failed:
            return "无法切换到 \(label)：该工作区没有可聚焦的窗口，且 SA 直切通道不可用（SIP 拦截）——空工作区只能通过 SA 切换"
        }
    }
}
