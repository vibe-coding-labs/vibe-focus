// Tests/Runner/RunnerSettingsSectionRenderTests.swift — SettingsView 大分区 body 求值直测
// （B255）。先例：B214 SettingsView() 构造安全、B238 ScreenMinimapView 式 body 求值、
// 并行线 RunnerSettingsRenderPilotTests。覆盖 SettingsView+OverlaySection /
// +ClaudeHookSection 两个扩展分区文件的构建机器：SettingsCard/SettingsRow/InfoBanner/
// Toggle 绑定族。偏好双态经 Runner 自有 defaults/内存 save-restore 驱动；真机交互
// （按钮动作：安装/卸载/打开设置等）维持留白归口。

import SwiftUI
@testable import VibeFocusKit

extension RunnerHarness {
    func runSettingsSectionRenderTests() {
        let view = SettingsView()

        // ===== A. overlaySection：关闭/开启双态 =====
        do {
            let savedEnabled = ScreenOverlayManager.shared.preferences.isEnabled
            defer { ScreenOverlayManager.shared.preferences.isEnabled = savedEnabled }

            // 关态：只有 Toggle 行
            ScreenOverlayManager.shared.preferences.isEnabled = false
            _ = view.overlaySection
            check("renderOverlay: 关态 body 求值零崩溃", true)

            // 开态：+ yabai 检测 InfoBanner 双分支之一（spaceController.isEnabled 环境定）
            ScreenOverlayManager.shared.preferences.isEnabled = true
            _ = view.overlaySection
            check("renderOverlay: 开态 body 求值零崩溃（yabai 横幅分支随环境）", true)
        }

        // ===== B. claudeHookSection：默认态 + hook 开关双态 =====
        do {
            let savedEnabled = ClaudeHookPreferences.isEnabled
            defer { ClaudeHookPreferences.isEnabled = savedEnabled }

            ClaudeHookPreferences.isEnabled = false
            _ = view.claudeHookSection
            check("renderClaude: 关态 body 求值零崩溃", true)

            ClaudeHookPreferences.isEnabled = true
            _ = view.claudeHookSection
            check("renderClaude: 开态 body 求值零崩溃", true)
        }
    }
}
