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

// MARK: - B256：偏好矩阵 + ImageRenderer 离屏渲染打穿深层行

extension RunnerHarness {
    func runSettingsSectionDeepRenderTests() {
        let view = SettingsView()
        let manager = ScreenOverlayManager.shared
        let sc = SpaceController.shared

        // isEnabled set 缝（B244 accessibilityStatus 先例）+ 偏好快照还原
        let savedIsEnabled = sc.isEnabled
        let savedPrefs = manager.preferences
        defer {
            sc.isEnabled = savedIsEnabled
            manager.preferences = savedPrefs
        }

        func render() -> Bool {
            let renderer = ImageRenderer(content: view.overlaySection)
            return renderer.nsImage != nil
        }

        // 分支 1：yabai 不可用 → 安装提示行（brew tap 横幅）+ 无索引说明
        sc.isEnabled = false
        check("renderDeep: yabai 不可用分支渲染出图", render())

        // 分支 2：yabai 可用 → 全部行（编号模式/显示位置/字号/透明度/缩放/边距/颜色/预览胶囊）
        sc.isEnabled = true
        check("renderDeep: yabai 可用分支渲染出图", render())

        // 偏好矩阵：position 全枚举 × 字号两端 × 透明度两端 × 缩放/边距两端
        var renderOK = true
        for position in IndexPosition.allCases {
            var p = manager.preferences
            p.position = position
            manager.preferences = p
            if !render() { renderOK = false }
        }
        check("renderDeep: position 全枚举渲染", renderOK)

        let extremes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (24, 0.3, 0.8, 4),      // 字号下限/透明度下限/缩放下限/边距下限
            (72, 1.0, 1.6, 40),     // 上限
        ]
        renderOK = true
        for (fontSize, opacity, scale, margin) in extremes {
            var p = manager.preferences
            p.fontSize = fontSize
            p.opacity = opacity
            p.panelScale = scale
            p.panelMargin = margin
            manager.preferences = p
            if !render() { renderOK = false }
        }
        check("renderDeep: 字号/透明度/缩放/边距端值渲染", renderOK)
    }
}

// MARK: - B257：TerminalGridSection / ClaudeHookSection ImageRenderer 全树渲染

extension RunnerHarness {
    func runSettingsSectionDeepRender2Tests() {
        let view = SettingsView()

        // ===== A. TerminalGridSection 全段 + 子面板逐一渲染 =====
        // （GridTargetCode.parse / gridMinimapScreens 真实屏幕数据源；按钮闭包不触发=
        //  安装/捕获/恢复等真机动作留白不变）
        do {
            let whole = ImageRenderer(content: view.terminalGridSection)
            check("renderTG: 全段渲染出图", whole.nsImage != nil)

            let minimap = ImageRenderer(content: view.gridMinimapPanel)
            check("renderTG: minimap 面板渲染出图", minimap.nsImage != nil)

            let session = ImageRenderer(content: view.terminalSessionCard)
            check("renderTG: 会话卡片渲染出图", session.nsImage != nil)
        }

        // ===== B. claudeHookSection ImageRenderer 全树渲染 =====
        // （isHookInstalled 读真身 ~/.claude/settings.json——本机已安装=已安装分支；
        //  未安装分支随真机卸载态。按钮闭包（一键安装/卸载/测试）留白。）
        do {
            let on = view
            on.hookEnabled = true
            let r1 = ImageRenderer(content: on.claudeHookSection)
            check("renderClaude2: hookEnabled=true 全树渲染出图", r1.nsImage != nil)

            let off = view
            off.hookEnabled = false
            let r2 = ImageRenderer(content: off.claudeHookSection)
            check("renderClaude2: hookEnabled=false 全树渲染出图", r2.nsImage != nil)
        }
    }
}
