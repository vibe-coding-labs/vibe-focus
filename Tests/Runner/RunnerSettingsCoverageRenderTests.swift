import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsCoverageRenderTests.swift — 2026-11-03 覆盖率批次：
// 把此前只在「裸 body 求值」里被外层表达式扫到、内层 SettingsCard/ForEach 内容
// 从未求值的两个分区接通真实渲染：
//
// - voiceAnnouncementSection：四种播报模式（none/template/audioFile/llmSummary），
//   逐模式 ImageRenderer 求值，覆盖各自条件分支（音量/语速/模板/音频/LLM 字段）；
// - layoutHotKeySection：Section 依赖 @EnvironmentObject hotKeyManager，裸求值必崩，
//   经 NSHostingView 注入环境后渲染；同时切换总开关与冲突横幅两个 @State 分支。
//
// 偏好一律快照-还原（VoiceAnnouncementManager 走公开 update* 往返；Layout 走
// @State 本地值，不落盘）。渲染期不触发任何 action 闭包（安装/Finder/录音等）。

extension RunnerHarness {
    /// 单分区渲染：每个分区独立成域，逐域采集下某一段挂起只损失该段，
    /// 不会把同批其余分区一起陪葬（B288 SettingsCommon 一次渲染 8 段，CI 上
    /// 整域超时导致全部无 profraw 的教训）。
    private func renderSectionImage(_ name: String, _ content: any View) -> Bool {
        let renderer = ImageRenderer(content: AnyView(content))
        let ok = renderer.nsImage != nil
        check("renderCov: \(name) 真实渲染出图", ok)
        return ok
    }

    func runSettingsRenderOverlaySectionTests() {
        let view = SettingsView()
        let saved = ScreenOverlayManager.shared.preferences
        defer { ScreenOverlayManager.shared.preferences = saved }
        _ = renderSectionImage("overlay/开", view.overlaySection)
        var off = saved
        off.isEnabled = false
        ScreenOverlayManager.shared.preferences = off
        _ = renderSectionImage("overlay/关", view.overlaySection)
    }

    func runSettingsRenderWorkspaceSectionTests() {
        let view = SettingsView()
        _ = renderSectionImage("workspace", view.workspaceSection)
    }

    func runSettingsRenderAntiDisturbTests() {
        let view = SettingsView()
        _ = renderSectionImage("antiDisturb", view.antiDisturbRows)
    }

    func runSettingsRenderProjectRulesTests() {
        let view = SettingsView()
        _ = renderSectionImage("projectRules", view.projectRulesSection)
    }

    func runSettingsRenderCustomAudioTests() {
        let view = SettingsView()
        _ = renderSectionImage("customAudio", view.customAudioFileRows)
    }

    func runSettingsRenderCodexTests() {
        let view = SettingsView()
        _ = renderSectionImage("codex", view.codexSection)
    }

    /// 单 tab 渲染：B239 把 7 个 tab 塞进同一域，CI 上整域超时（12min+）导致
    /// 连已渲染完的 tab 也随 profraw 一起丢失。拆域后每个 tab 独立成败。
    private func renderSettingsTab(_ tab: SettingsTab) {
        let view = SettingsView()
        view.selectedTab = tab
        let host = NSHostingView(rootView: view.environmentObject(HotKeyManager.shared))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 940)
        host.layoutSubtreeIfNeeded()
        check("renderCov: \(tab.rawValue) tab 渲染非退化", host.subviews.count > 0)
        host.layoutSubtreeIfNeeded()
    }

    func runSettingsTabGeneralRenderTests() { renderSettingsTab(.general) }
    func runSettingsTabWorkspaceRenderTests() { renderSettingsTab(.workspace) }
    func runSettingsTabOrchestrationRenderTests() { renderSettingsTab(.orchestration) }
    func runSettingsTabClaudeIntegrationRenderTests() { renderSettingsTab(.claudeIntegration) }
    func runSettingsTabCodexIntegrationRenderTests() { renderSettingsTab(.codexIntegration) }
    func runSettingsTabAgentAccessRenderTests() { renderSettingsTab(.agentAccess) }
    func runSettingsTabAppearanceRenderTests() { renderSettingsTab(.appearance) }

    func runSettingsRenderPermissionsDuplicatesTests() {
        // 权限分区读 SettingsView 自身的 @EnvironmentObject hotKeyManager，独立求值
        // `view.permissionsSection` 会 fatal（CI 实证 Trace/BPT）；改渲染整棵
        // SettingsView（general tab），由外层注入环境。
        var allOK = true
        for duplicates in [["/tmp/VibeFocus-Copy-A.app", "/tmp/VibeFocus-Copy-B.app"], []] {
            let view = SettingsView()
            view.selectedTab = .general
            view.duplicateAppPaths = duplicates
            let renderer = ImageRenderer(
                content: SettingsViewHost(view: view).environmentObject(HotKeyManager.shared))
            renderer.proposedSize = ProposedViewSize(width: 680, height: 940)
            if renderer.nsImage == nil { allOK = false }
        }
        check("renderCov: 权限分区 有/无副本 两态渲染出图", allOK)
    }

    func runSettingsCoverageRenderTests() {
        // MARK: A. 语音播报分区：全模式渲染
        do {
            let manager = VoiceAnnouncementManager.shared
            let saved = manager.preferences
            defer {
                manager.updateMode(saved.mode)
                manager.updateTemplateText(saved.templateText)
                manager.updateAudioFilePath(saved.audioFilePath)
                manager.updateVolume(saved.volume)
                manager.updateSpeechRate(saved.speechRate)
                manager.updateLLMApiBase(saved.llmApiBase)
                manager.updateLLMApiKey(saved.llmApiKey)
                manager.updateLLMModel(saved.llmModel)
                manager.updateLLMMaxChars(saved.llmMaxChars)
            }

            // 每次渲染用**新的 SettingsView 实例**：CI 实证复用同一实例时 SwiftUI 会
            // 命中 body 缓存（游离的 @StateObject 不订阅 @Published），后三次渲染根本
            // 不求值 `if mode != .none` 分支——实测 30~205 行整段未覆盖。
            var allRendered = true
            for mode in VoiceAnnouncementMode.allCases {
                manager.updateMode(mode)
                let renderer = ImageRenderer(content: SettingsView().voiceAnnouncementSection)
                if renderer.nsImage == nil { allRendered = false }
            }
            check("renderCov: 语音播报四模式全渲染出图", allRendered)
            check("renderCov: 语音播报模式偏好随 updateMode 生效",
                  manager.preferences.mode == VoiceAnnouncementMode.allCases.last)

            // 边界值：模板非空/空、音频路径有/无、LLM 字段端值（覆盖 Text/TextField 绑定读取）
            manager.updateMode(.template)
            manager.updateTemplateText("")
            manager.updateVolume(0)
            manager.updateSpeechRate(100)
            let emptyTemplate = ImageRenderer(content: SettingsView().voiceAnnouncementSection)
            check("renderCov: 语音模板空文案渲染出图", emptyTemplate.nsImage != nil)

            manager.updateMode(.audioFile)
            manager.updateAudioFilePath("/tmp/nonexistent-audio.wav")
            let audio = ImageRenderer(content: SettingsView().voiceAnnouncementSection)
            check("renderCov: 语音音频文件路径渲染出图", audio.nsImage != nil)

            manager.updateMode(.llmSummary)
            manager.updateVolume(1)
            manager.updateSpeechRate(300)
            manager.updateLLMApiBase("https://example.invalid/v1")
            manager.updateLLMApiKey("sk-test")
            manager.updateLLMModel("gpt-test")
            manager.updateLLMMaxChars(100)
            let llm = ImageRenderer(content: SettingsView().voiceAnnouncementSection)
            check("renderCov: 语音 LLM 端值渲染出图", llm.nsImage != nil)
        }

        // MARK: B. 摆位快捷键分区：注入 EnvironmentObject 渲染 + 状态双分支
        //
        // 2026-11-03 CI 实证：直接求值 `view.layoutHotKeySection` 会 fatal
        // （No ObservableObject of type HotKeyManager）——该分区读的是 **SettingsView
        // 自身的 @EnvironmentObject**，注入到子视图上无效（属性包装器在父实例上未安装）。
        // 改为把整棵 SettingsView 交给 SwiftUI 求值：外层注入环境、选中编排 tab、
        // ImageRenderer 触发完整布局（ScrollView 子内容随之实例化）。
        do {
            var allOK = true
            for enabled in [false, true] {
                let conflicts: [String?] = [nil, "Rectangle"]
                for conflict in conflicts {
                    let view = SettingsView()
                    view.selectedTab = .orchestration
                    view.layoutHotKeysEnabled = enabled
                    view.layoutConflictSummary = conflict
                    let renderer = ImageRenderer(
                        content: SettingsViewHost(view: view)
                            .environmentObject(HotKeyManager.shared))
                    renderer.proposedSize = ProposedViewSize(width: 680, height: 900)
                    if renderer.nsImage == nil { allOK = false }
                }
            }
            check("renderCov: 摆位分区 开关×冲突横幅 四态渲染非退化", allOK)
        }
    }
}

/// 让 SwiftUI 真正求值 SettingsView.body（其 @EnvironmentObject 才能被安装）。
private struct SettingsViewHost: View {
    let view: SettingsView
    var body: some View { view }
}
