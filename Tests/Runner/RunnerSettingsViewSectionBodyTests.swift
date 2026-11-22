import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsViewSectionBodyTests.swift — 覆盖率批次 5（B229）：
// SettingsView 各 section 的 body 构建期求值直测（A/B/C 三组风险分级）。
//
// 分级依据（单例 init 副作用逐个审计，2026-09-19）：
// - A 组零单例：构建表达式只读 UserDefaults 偏好 → 直接求值；
// - B 组安全单例：soundManager/voiceAnnouncementManager 的 init 只 loadPreferences
//   （不预载音频、不启播放）→ 可求值；
// - C 组低风险：overlayManager（init 装信号 handler+注册 yabai 信号——Runner 进程
//   正常 exit 不受影响）+ spaceController（init 的 asyncAfter 重试与 60s health-check
//   Timer 在无运行 RunLoop 的同步测试进程里永不 fire，零 yabai fork）→ 可求值；
// - D 组留白：PermissionsSection（loginItemManager init 的 Task 触发 SMAppService
//   XPC+AppleScript）、SessionLists/ClaudeHookSection（sessionRegistry → WindowStateStore
//   .shared 打开生产 DB）、SettingsUI 主体 body（聚合全部 tab 会碰全组单例）。
// 危险调用（NSPasteboard/NSWorkspace/Process/install 系）均在按钮 action 闭包内，
// 构建期不执行——CodexSection 构建期仅 isHookInstalled() 读 ~/.codex/hooks.json（只读）。

extension RunnerHarness {
    // MARK: - 会话卡片的条件分支真渲染（2026-11-23 补口）
    //
    // terminalSessionCard 的「自动检测结果」反馈行（gridResultMessage 有值 →
    // 红/灰双色文本）与「检测到同类窗口管理器」提示横幅（gridFavoriteWarning）
    // 都是纯 @State，裸求值只构建外层结构、条件分支不进渲染树；必须 ImageRenderer
    // 真渲染 + init 缝注入初值才能覆盖。
    func runTerminalSessionCardRenderTests() {
        var withResult = SettingsView.ResultMessages()
        withResult.gridResult = "已恢复到「双屏双工作区」（2 窗 / 2 屏）"
        withResult.gridResultIsError = false
        withResult.gridFavoriteWarning = "检测到 Rectangle 正在运行，摆位热键已让位"
        let okView = SettingsView(gridTargetCode: "d1s1", resultMessages: withResult)
        let okRenderer = ImageRenderer(content: okView.terminalSessionCard)
        okRenderer.proposedSize = ProposedViewSize(width: 620, height: 640)
        check("sessionCard: 成功结果行 + 偏好警告横幅渲染出图", okRenderer.nsImage != nil)

        var withError = SettingsView.ResultMessages()
        withError.gridResult = "创建网格失败：终端未就绪"
        withError.gridResultIsError = true
        let errView = SettingsView(gridTargetCode: "main", resultMessages: withError)
        let errRenderer = ImageRenderer(content: errView.terminalSessionCard)
        errRenderer.proposedSize = ProposedViewSize(width: 620, height: 640)
        check("sessionCard: 失败结果行（红字分支）渲染出图", errRenderer.nsImage != nil)
    }

    func runSettingsViewSectionBodyTests() {
        let view = SettingsView()

        // MARK: A 组：零单例 section（构建期只读 UserDefaults）
        // 留白三件：①hotKeySection/layoutHotKeySection/inputBubbleSection——构建表达式
        // 直接读 @EnvironmentObject hotKeyManager，脱离渲染树求值必崩（SIGTRAP 实测）；
        // ②terminalGridSection/gridParamsSection——引用 gridMinimapHeartbeat
        // （autoconnect TimerPublisher 包装视图），body 求值触发
        // 「body() should not be called on SubscriptionView」fatal（实测）。
        print("[SECTION-PROBE] A6 terminalSessionCard")
        let _ = view.terminalSessionCard
        print("[SECTION-PROBE] A7 savedLayoutsCard")
        let _ = view.savedLayoutsCard
        print("[SECTION-PROBE] A8 codexSection")
        let _ = view.codexSection
        check("settingsSection: selectionDetailText 默认态非空文案",
              !view.selectionDetailText.isEmpty)

        // MARK: B 组：安全单例（init 只读偏好）
        print("[SECTION-PROBE] B1 soundSection")
        let _ = view.soundSection
        print("[SECTION-PROBE] B2 antiDisturbRows")
        let _ = view.antiDisturbRows
        print("[SECTION-PROBE] B3 projectRulesSection")
        let _ = view.projectRulesSection
        print("[SECTION-PROBE] B4 customAudioFileRows")
        let _ = view.customAudioFileRows
        print("[SECTION-PROBE] B5 voiceAnnouncementSection")
        let _ = view.voiceAnnouncementSection

        // MARK: C 组：overlay/space（死 timer + 信号 handler，同步进程内不 fire）
        print("[SECTION-PROBE] C1 overlaySection")
        let _ = view.overlaySection
        print("[SECTION-PROBE] C2 workspaceSection")
        let _ = view.workspaceSection
        print("[SECTION-PROBE] 全部 section 求值完成")
        check("settingsSection: 三组 section body 求值全程无异常", true)
    }

    // MARK: - B249：TerminalGridSection 域（gridMinimapPanel 构建期求值 + 摘要与刷新）
    //
    // terminalGridSection 本体含 gridMinimapHeartbeat（SubscriptionView 包装），
    // body 求值必崩（B229 实测）——继续留白；本块只碰同文件的安全面：
    // gridMinimapPanel（静态视图栈，读 @State 初始值）、refreshGridMinimap
    // （真实屏幕快照 + yabai 只读查询，先例 RunnerSpaceQueryYabaiTests）、
    // gridTargetSummary（纯计算，环境态诚实断言）。
    func runGridSectionPanelTests() {
        let view = SettingsView()

        // A. gridMinimapPanel 构建期求值（不订阅心跳，静态视图栈）
        print("[SECTION-PROBE] D1 gridMinimapPanel")
        let _ = view.gridMinimapPanel
        check("gridSection: gridMinimapPanel body 求值无异常", true)

        // B. refreshGridMinimap 烟测：真实屏幕快照 + yabai 只读查询（先例
        //    RunnerSpaceQueryYabaiTests）。⚠️B249 实测：未安装视图的 @State 写入
        //    不回读（读恒初始值）——快照落账效果在脱离渲染树时不可观察，只断言
        //    全链不崩；回读语义由真机设置页验证。
        //    B314：刷新已异步化（querySpaces fork 下放 WindowWorkExecutor）——
        //    泵主 RunLoop 等异步拍真实落地，断言语义从「同步链不崩」升级为
        //    「含下放 hop 的全链不崩」。
        view.refreshGridMinimap()
        for _ in 0..<100 {  // ~2s：fork + executor hop + @State 落账拍
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check("gridSection: minimap 刷新全链不崩（B314 fork 下放后含异步落地拍）", true)

        // C. gridTargetSummary：解析成败与真实偏好一致（nil 分支或对应形态分支）
        let summary = view.gridTargetSummary
        let parses = GridTargetCode.parse(TerminalGridPreferences.target) != nil
        check("gridSection: 摘要与目标码解析态一致",
              (summary != nil) == parses)
        if let summary, parses {
            check("gridSection: 摘要含箭头标注", summary.hasPrefix("→ "))
        }
    }

    // MARK: - B263：SoundProjectRules 行级求值（规则非空 ForEach + customSoundStatus 双分支）
    //
    // B229 只测了空规则态求值；本块经 SoundManager 公开 API 注入规则/自定义音频后
    // 再求值，覆盖行级视图体与状态分支。偏好走 B84 家法快照-还原（UserDefaults 键）。
    func runSoundRulesBodyTests() {
        let view = SettingsView()
        let sm = SoundManager.shared

        // 还原走公开 API 往返（内存 + defaults didSet 同步落盘，无需裸键操作）
        let savedCustomPath = sm.preferences.customSoundPath
        let savedRuleCount = sm.preferences.projectRules.count
        let savedRules = sm.preferences.projectRules
        defer {
            sm.updateCustomSoundPath(savedCustomPath)
            while sm.preferences.projectRules.count > savedRuleCount {
                sm.removeProjectRule(at: sm.preferences.projectRules.count - 1)
            }
            // 若初始态已有规则且名字被动过，按序还原名字
            for (i, rule) in savedRules.enumerated() where i < sm.preferences.projectRules.count {
                sm.setProjectRuleName(at: i, rule.projectName)
            }
        }

        // A. customSoundStatus：真实存在的临时 wav → 非 missing 分支；再切到缺失路径 → missing 分支
        let tmpWav = "/tmp/vibefocus-b263-\(UUID().uuidString).wav"
        try? Data([0x52, 0x49, 0x46, 0x46]).write(to: URL(fileURLWithPath: tmpWav))
        defer { try? FileManager.default.removeItem(atPath: tmpWav) }
        sm.updateCustomSoundPath(tmpWav)
        let okStatus = view.customSoundStatus
        check("soundRules: 存在的自定义音频 → 非 missing", okStatus != .missing)
        print("[SECTION-PROBE] E1 customAudioFileRows(ok)")
        let _ = view.customAudioFileRows

        sm.updateCustomSoundPath("/nonexistent/b263/missing.wav")
        check("soundRules: 缺失音频 → missing 分支命中", view.customSoundStatus == .missing)
        print("[SECTION-PROBE] E2 customAudioFileRows(missing)")
        let _ = view.customAudioFileRows

        // B. 规则注入后行级求值：add 两条 + 命名 + ForEach 行体/绑定 getter 执行
        sm.updateCustomSoundPath(nil)
        sm.addProjectRule()
        sm.addProjectRule()
        sm.setProjectRuleName(at: 0, "B263 项目甲")
        sm.setProjectRuleName(at: 1, "B263 项目乙")
        check("soundRules: 规则注入与命名回读",
              sm.preferences.projectRules.count == 2
              && sm.preferences.projectRules[0].projectName == "B263 项目甲")
        print("[SECTION-PROBE] E3 projectRulesSection(2 rules)")
        let _ = view.projectRulesSection
        check("soundRules: 规则态 body 求值无异常", true)

        // E4：裸求值只构建外层 VStack，ForEach 行体（项目名 TextField / 音效 Picker /
        // 迷你试听 / 删除钮）不会实例化——必须交给 SwiftUI 真渲染。这是规则行的
        // 唯一渲染通道（SoundProjectRules 49-101 曾因此整段零覆盖）。
        let renderer = ImageRenderer(
            content: SettingsView(gridTargetCode: TerminalGridPreferences.target)
                .projectRulesSection)
        renderer.proposedSize = ProposedViewSize(width: 620, height: 420)
        check("soundRules: 两条规则的 ForEach 行体真渲染出图", renderer.nsImage != nil)

        // E5：规则音效类型切换（Picker 绑定 get 分支随规则态变化）
        sm.setProjectRuleSound(at: 0, .builtinDing)
        sm.setProjectRuleSound(at: 1, .systemDefault)
        let renderer2 = ImageRenderer(
            content: SettingsView(gridTargetCode: TerminalGridPreferences.target)
                .projectRulesSection)
        renderer2.proposedSize = ProposedViewSize(width: 620, height: 420)
        check("soundRules: 规则音效异态双 row 渲染出图", renderer2.nsImage != nil)
    }

    // MARK: - B269：WorkspaceSection 条件分支注入求值（availability 可写 @Published）
    //
    // B229 只测了真实态求值；本块经 @Published availability 注入 .notInstalled /
    // .available 双态，覆盖安装引导分支（brew 指引 CodeBlock/按钮行）与已装态分支。
    // 快照-还原，只动 Runner 进程内 SpaceController 实例（生产 app 独立进程不受影响）。
    func runWorkspaceSectionBranchTests() {
        let view = SettingsView()
        let sc = SpaceController.shared
        let savedAvailability = sc.availability
        let savedEnabled = sc.isEnabled
        defer {
            sc.availability = savedAvailability
            sc.isEnabled = savedEnabled
        }

        sc.availability = .notInstalled
        print("[SECTION-PROBE] F1 workspaceSection(notInstalled)")
        let _ = view.workspaceSection
        check("workspace: 未安装态安装引导分支求值无异常", true)

        sc.availability = .available
        sc.isEnabled = true
        print("[SECTION-PROBE] F2 workspaceSection(available)")
        let _ = view.workspaceSection
        check("workspace: 已装态分支求值无异常", true)

        // F3/F4. .unavailable 分支（yabai 装了但没权限）：SIP 指引段；
        // 再带 lastErrorMessage → 「yabai 返回：…」诊断行 + 「加载 scripting-addition」钮。
        // spaceController 是 @StateObject（引用类型，写 @Published 立即生效），可直注。
        let savedMessage = sc.lastErrorMessage
        defer { sc.lastErrorMessage = savedMessage }
        sc.availability = .unavailable
        sc.lastErrorMessage = nil
        print("[SECTION-PROBE] F3 workspaceSection(unavailable, 无错误)")
        let _ = view.workspaceSection
        check("workspace: 权限不足态 SIP 指引分支求值无异常", true)

        sc.lastErrorMessage = "error with the scripting-addition"
        print("[SECTION-PROBE] F4 workspaceSection(unavailable, 带错误)")
        let _ = view.workspaceSection
        check("workspace: 权限不足 + 错误文本 → 诊断行与加载钮分支求值无异常", true)

        sc.availability = .available
        sc.lastErrorMessage = savedMessage

        // refreshInstallations 烟测：后台只读扫描（findAppBundlePaths）+ 主线程回填
        view.refreshInstallations()
        Thread.sleep(forTimeInterval: 0.5)
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        check("workspace: 安装扫描全链不崩", true)
    }
}
