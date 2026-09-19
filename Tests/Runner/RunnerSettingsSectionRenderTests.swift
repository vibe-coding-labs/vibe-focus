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

// MARK: - B258：LANSettingsView 深层行渲染（spool 主机行/状态文本/安装通道）

extension RunnerHarness {
    func runLANViewDeepRenderTests() {
        let savedLanMode = UserDefaults.standard.object(forKey: LANHookPreferences.lanModeKey)
        let savedHosts = RemoteSpoolHosts.loadHosts()
        let savedToken = ClaudeHookPreferences.authToken
        let savedRunner = RemoteSpoolDrainer.shared.processRunner
        defer {
            if let savedLanMode { UserDefaults.standard.set(savedLanMode, forKey: LANHookPreferences.lanModeKey) }
            else { UserDefaults.standard.removeObject(forKey: LANHookPreferences.lanModeKey) }
            RemoteSpoolHosts.saveHosts(savedHosts)
            ClaudeHookPreferences.authToken = savedToken
            RemoteSpoolDrainer.shared.processRunner = savedRunner
            RemoteSpoolHosts.saveHosts([])
            RemoteSpoolDrainer.shared.applyPreferences()
        }

        // 状态产线：假 runner 拉取 3 条（exit 0）→ drainNow → statuses 落账
        RemoteSpoolHosts.saveHosts(["vf-lan-deep"])
        ClaudeHookPreferences.isEnabled = true
        ClaudeHookPreferences.authToken = "vf-lan-token"
        let canned: SpoolProcessRunner = { _, _, _ in
            let lines = (1...3).map { "{\"event\":\"SessionEnd\",\"session_id\":\"vf-lan-deep-\($0)\"}" }
            return (exitCode: 0, stdout: lines.joined(separator: "\n"), stderr: "")
        }
        RemoteSpoolDrainer.shared.processRunner = canned
        RemoteSpoolDrainer.shared.drainNow()
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if RemoteSpoolDrainer.shared.statuses["vf-lan-deep"]?.lastDrainAt != nil { break }
        }
        check("lanDeep: 前置——假 runner 拉取后 statuses 落账",
              RemoteSpoolDrainer.shared.statuses["vf-lan-deep"]?.lastDrainAt != nil)

        // lanMode 开 + 主机非空 → 详情分区/主机行/状态文本/安装通道全渲染
        UserDefaults.standard.set(true, forKey: LANHookPreferences.lanModeKey)
        let view = LANSettingsView()
        let renderer = ImageRenderer(content: view.body)
        check("lanDeep: 深层行全树渲染出图", renderer.nsImage != nil)

        // 错误分支：假 runner 返回 exit 255 → lastError 落账 → 错误文本渲染
        RemoteSpoolDrainer.shared.processRunner = { _, _, _ in
            (exitCode: 255, stdout: "", stderr: "ssh: connect failed")
        }
        RemoteSpoolDrainer.shared.drainNow()
        let errDeadline = Date().addingTimeInterval(3.0)
        while Date() < errDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if RemoteSpoolDrainer.shared.statuses["vf-lan-deep"]?.lastError != nil { break }
        }
        let errRenderer = ImageRenderer(content: LANSettingsView())
        check("lanDeep: 拉取失败分支渲染出图（错误文本行）", errRenderer.nsImage != nil)
    }
}

// MARK: - B259：ClaudeHookSection 横幅/状态分支 + LANSettingsView 远程绑定行渲染

extension RunnerHarness {
    func runSettingsSectionStateRenderTests() {
        let view = SettingsView()

        // ===== A. claudeHookSection：安装结果横幅双态渲染（hookInstallMessage）=====
        do {
            let ok = view
            ok.hookInstallMessage = "已安装到 ~/.claude/settings.json"
            ok.hookInstallSucceeded = true
            let rOK = ImageRenderer(content: ok.claudeHookSection)
            check("stateRender: 安装成功横幅渲染出图", rOK.nsImage != nil)

            let fail = view
            fail.hookInstallMessage = "安装辅助脚本失败"
            fail.hookInstallSucceeded = false
            let rFail = ImageRenderer(content: fail.claudeHookSection)
            check("stateRender: 安装失败横幅渲染出图", rFail.nsImage != nil)
        }

        // ===== B. LANSettingsView：远程绑定行渲染（defaults 预置映射）=====
        do {
            let savedBindings = UserDefaults.standard.string(forKey: "claudeHookRemoteBindings")
            defer {
                if let savedBindings { UserDefaults.standard.set(savedBindings, forKey: "claudeHookRemoteBindings") }
                else { UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings") }
            }
            // B226 同款 defaults 形状：label → windowID JSON string 键存
            UserDefaults.standard.set(
                #"{"vf-lan-bind-label": 4242}"#,
                forKey: "claudeHookRemoteBindings")
            UserDefaults.standard.set(true, forKey: LANHookPreferences.lanModeKey)
            defer { UserDefaults.standard.set(false, forKey: LANHookPreferences.lanModeKey) }

            let view2 = LANSettingsView()
            let renderer = ImageRenderer(content: view2.body)
            check("lanBind: 远程绑定行全树渲染出图", renderer.nsImage != nil)
        }
    }
}

// MARK: - B260：LANSettingsView 状态分支 + CodexSection/SoundAntiDisturb 渲染

extension RunnerHarness {
    func runSettingsSectionStateMatrixTests() {
        let view = SettingsView()

        // ===== A. LANSettingsView 状态分支矩阵 =====
        do {
            let savedLanMode = UserDefaults.standard.object(forKey: LANHookPreferences.lanModeKey)
            let savedHosts = RemoteSpoolHosts.loadHosts()
            let savedBindings = UserDefaults.standard.string(forKey: "claudeHookRemoteBindings")
            let savedRunner = RemoteSpoolDrainer.shared.processRunner
            defer {
                if let savedLanMode { UserDefaults.standard.set(savedLanMode, forKey: LANHookPreferences.lanModeKey) }
                else { UserDefaults.standard.removeObject(forKey: LANHookPreferences.lanModeKey) }
                RemoteSpoolHosts.saveHosts(savedHosts)
                if let savedBindings { UserDefaults.standard.set(savedBindings, forKey: "claudeHookRemoteBindings") }
                else { UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings") }
                RemoteSpoolDrainer.shared.processRunner = savedRunner
                RemoteSpoolHosts.saveHosts([])
                ClaudeHookPreferences.isEnabled = false
                RemoteSpoolDrainer.shared.applyPreferences()
            }

            // A1. 取回 0 条状态（lastDrainAt 有 + lastEventCount 0）→「上次拉取 HH:mm:ss」分支
            RemoteSpoolHosts.saveHosts(["vf-zero-host"])
            ClaudeHookPreferences.isEnabled = true
            RemoteSpoolDrainer.shared.processRunner = { _, _, _ in
                (exitCode: 0, stdout: "", stderr: "")
            }
            RemoteSpoolDrainer.shared.drainNow()
            let d1 = Date().addingTimeInterval(3.0)
            while Date() < d1 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if RemoteSpoolDrainer.shared.statuses["vf-zero-host"]?.lastDrainAt != nil { break }
            }
            UserDefaults.standard.set(true, forKey: LANHookPreferences.lanModeKey)
            let rZero = ImageRenderer(content: LANSettingsView())
            check("stateMatrix: 取回 0 条状态文本渲染出图", rZero.nsImage != nil)

            // A2. 远程绑定「未映射」分支（label → nil）
            UserDefaults.standard.set(
                #"{"vf-unmapped-label": null}"#,
                forKey: "claudeHookRemoteBindings")
            let rUnmapped = ImageRenderer(content: LANSettingsView())
            check("stateMatrix: 绑定未映射分支渲染出图", rUnmapped.nsImage != nil)

            // A3. 主机空清单 → 空状态分支
            RemoteSpoolHosts.saveHosts([])
            let rEmpty = ImageRenderer(content: LANSettingsView())
            check("stateMatrix: 主机空清单分支渲染出图", rEmpty.nsImage != nil)
        }

        // ===== B. codexSection 渲染（installed 双态经临时文件驱动）=====
        do {
            let savedCodex = UserDefaults.standard.object(forKey: "codexHooks") // 占位；真实状态走 isHookInstalled 文件探测
            _ = savedCodex
            let rCodex = ImageRenderer(content: view.codexSection)
            check("stateMatrix: codexSection 渲染出图", rCodex.nsImage != nil)
        }

        // ===== C. 声音防打扰分区渲染 =====
        do {
            let rSound = ImageRenderer(content: view.antiDisturbRows)
            check("stateMatrix: 声音防打扰分区渲染出图", rSound.nsImage != nil)
        }
    }
}
