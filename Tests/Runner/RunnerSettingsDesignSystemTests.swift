import AppKit
import Carbon
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsDesignSystemTests.swift — 覆盖率批次 1（C1）：设计系统与零依赖设置组件直测。
//
// 背景：llvm-cov 基线（2026-09-19，Runner 2063）行覆盖 28.67%，Settings UI 层近乎全零——
// DesignSystem.swift / SettingsComponents*.swift 均为纯值类型组件（无 .shared 单例依赖、
// 无副作用），在 CLI Runner 进程里直接求值 body / 计算 token 是安全的（不渲染、不进
// runloop，onHover/onAppear 等生命周期闭包不会执行）。本文件按「token 契约锁 + body
// 求值 + 分支参数化」三层吃掉这些文件的可测行：
//   - token 契约锁：颜色分量/圆角数值/文案逐值断言，改值必红（防止视觉 token 被静默改动）；
//   - NSColor 动态 provider：resolvedColor(with: aqua/darkAqua) 强制触发亮暗双分支；
//   - body 求值：SwiftUI View body 是纯函数式构建，求值即覆盖全部构建分支
//     （三元/if-let 由参数化实例覆盖双分支）。
// 诚实留白（不可直测）：VibeProminentButtonStyle.makeBody（ButtonStyleConfiguration
// 无法在测试里构造，渲染期才调用）；DotGridPattern 的 Canvas 闭包（渲染期才执行）；
// CodeBlockView 的 @State isCopied=true 分支与剪贴板 action（private 状态，UI 触发）；
// AppLogoBadge 的 icns 成功分支（Runner bundle 无 AppIcon 资源）。

/// performAsCurrentDrawingAppearance 的 block 无返回值（AppKit SDK 签名 Void），
/// 用引用盒子把解析结果带出闭包。
private final class ResolvedColorBox {
    var value: NSColor?
}

extension RunnerHarness {
    func runSettingsDesignSystemTests() {
        // MARK: A. NSColor(rgbHex:) 解析契约
        func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b, a)
        }
        func rgbHex(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            rgb(NSColor(rgbHex: value))
        }
        check("designSystem: NSColor(rgbHex:) 三通道分量精确解析",
              rgbHex(0xE64A33) == (0xE6 / 255.0, 0x4A / 255.0, 0x33 / 255.0, 1.0))
        check("designSystem: NSColor(rgbHex:) 黑白两极",
              rgbHex(0x000000) == (0, 0, 0, 1.0) && rgbHex(0xFFFFFF) == (1, 1, 1, 1.0))

        // MARK: B. NSColor 动态 provider 亮暗双分支强制解析
        // Color(light:dark:) 的 provider 闭包在 SwiftUI 渲染期求值，此处对四个
        // NSColor 版 token 用 performAsCurrentDrawingAppearance 强制触发，
        // 亮暗 8 分支全覆盖（NSColor 无 UIColor.resolvedColor(with:) 等价物，
        // CLI 进程走外观上下文通道）。
        func resolved(_ c: NSColor, _ name: NSAppearance.Name) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            let box = ResolvedColorBox()
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                box.value = c.usingColorSpace(.sRGB)
            }
            return rgb(box.value!)
        }
        func hex4(_ value: UInt32) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
            (CGFloat((value >> 16) & 0xFF) / 255.0, CGFloat((value >> 8) & 0xFF) / 255.0,
             CGFloat(value & 0xFF) / 255.0, 1.0)
        }
        check("designSystem: accentNS 亮色珊瑚红/暗色亮珊瑚（provider 双分支）",
              resolved(VibeColors.accentNS, .aqua) == hex4(0xE64A33)
              && resolved(VibeColors.accentNS, .darkAqua) == hex4(0xFF8266))
        check("designSystem: backgroundNS 亮色奶油米/暗色暖棕近黑",
              resolved(VibeColors.backgroundNS, .aqua) == hex4(0xF6F1E7)
              && resolved(VibeColors.backgroundNS, .darkAqua) == hex4(0x211C18))
        check("designSystem: cardNS 亮色暖白/暗色暖深棕",
              resolved(VibeColors.cardNS, .aqua) == hex4(0xFFFCF5)
              && resolved(VibeColors.cardNS, .darkAqua) == hex4(0x2C2721))
        let hairlineLight = resolved(VibeColors.hairlineNS, .aqua)
        let hairlineDark = resolved(VibeColors.hairlineNS, .darkAqua)
        check("designSystem: hairlineNS 亮色暖发丝线精确分量",
              hairlineLight == hex4(0xE8DDCB))
        check("designSystem: hairlineNS 暗色 = 白 8% 透明覆盖",
              hairlineDark.0 == 1 && hairlineDark.1 == 1 && hairlineDark.2 == 1
              && abs(hairlineDark.3 - 0.08) < 1e-6)

        // Color(light: UInt32, dark: UInt32) 便捷通道（转调 NSColor(rgbHex:) 双参版）
        let _ = Color(light: 0xE64A33, dark: 0xFF8266)
        let _ = Color(light: NSColor(rgbHex: 0xE64A33), dark: NSColor(rgbHex: 0xFF8266))

        // MARK: C. SwiftUI token 存在性与区分性
        check("designSystem: VibeColors 十三 token 两两区分（抽样不等链）",
              VibeColors.accent != VibeColors.accentPeach
              && VibeColors.accent != VibeColors.danger
              && VibeColors.success != VibeColors.warning
              && VibeColors.background != VibeColors.card
              && VibeColors.ink != VibeColors.background
              && VibeColors.neutral != VibeColors.accent
              && VibeColors.shadow != VibeColors.ink)
        let _ = VibeColors.headerWash
        let _ = VibeColors.prominentGradient

        // MARK: D. VibeRadius 圆角 token 契约锁
        check("designSystem: VibeRadius 四档圆角逐值锁定",
              VibeRadius.card == 16 && VibeRadius.panel == 12
              && VibeRadius.control == 9 && VibeRadius.chip == 7)

        // MARK: E. InfoBanner.Style 语义五态
        check("infoBanner: Style.tint 五态逐一定色",
              InfoBanner<EmptyView>.Style.info.tint == VibeColors.accent
              && InfoBanner<EmptyView>.Style.tip.tint == VibeColors.warning
              && InfoBanner<EmptyView>.Style.danger.tint == VibeColors.danger
              && InfoBanner<EmptyView>.Style.success.tint == VibeColors.success
              && InfoBanner<EmptyView>.Style.warning.tint == Color.orange)
        check("infoBanner: Style.icon 五态 SF Symbol 逐一定名",
              InfoBanner<EmptyView>.Style.info.icon == "info.circle.fill"
              && InfoBanner<EmptyView>.Style.tip.icon == "lightbulb.fill"
              && InfoBanner<EmptyView>.Style.warning.icon == "exclamationmark.triangle.fill"
              && InfoBanner<EmptyView>.Style.danger.icon == "exclamationmark.octagon.fill"
              && InfoBanner<EmptyView>.Style.success.icon == "checkmark.circle.fill")

        // MARK: F. SettingsTab 导航契约
        check("settingsTab: allCases 六页顺序契约",
              SettingsTab.allCases == [.general, .workspace, .orchestration,
                                       .claudeIntegration, .codexIntegration, .appearance])
        check("settingsTab: rawValue 中文文案逐页锁定",
              SettingsTab.general.rawValue == "通用"
              && SettingsTab.workspace.rawValue == "工作区"
              && SettingsTab.orchestration.rawValue == "编排"
              && SettingsTab.claudeIntegration.rawValue == "Claude 集成"
              && SettingsTab.codexIntegration.rawValue == "Codex 集成"
              && SettingsTab.appearance.rawValue == "外观与反馈")
        check("settingsTab: icon 六态 SF Symbol 逐页锁定",
              SettingsTab.general.icon == "gearshape"
              && SettingsTab.workspace.icon == "macwindow"
              && SettingsTab.orchestration.icon == "rectangle.split.2x2"
              && SettingsTab.claudeIntegration.icon == "link"
              && SettingsTab.codexIntegration.icon == "terminal.fill"
              && SettingsTab.appearance.icon == "paintbrush")

        // MARK: G. 零依赖组件 body 求值（分支参数化）
        // SectionIconChip / CapsuleTag：默认参 + 全参两条构建路径。
        let _ = SectionIconChip(icon: "number").body
        let _ = SectionIconChip(icon: "number", tint: VibeColors.success).body
        let _ = CapsuleTag(text: "sh").body
        let _ = CapsuleTag(text: "LIVE", tint: VibeColors.danger, isOutlined: true).body

        // InfoBanner：五态 × title 有无 × accessory 有无双分支。
        for style in [InfoBanner<EmptyView>.Style.info, .tip, .warning, .danger, .success] {
            let _ = InfoBanner(style: style, title: "标题", text: "正文").body
            let _ = InfoBanner(style: style, title: nil, text: "正文").body
        }
        let _ = InfoBanner(style: .info, title: nil, text: "带尾部按钮", accessory: { Text("重置") }).body

        // VibeCardStyle：ViewModifier 的 body(content:) 参数类型 _ViewModifier_Content
        // 无法在测试里构造（渲染期生成），body 本体诚实留白——vibeCardStyle() 链路只求值装配。

        // SettingsCard：icon nil / 非 nil 双分支 + 自定义 content。
        let _ = SettingsCard(title: "t", subtitle: "s", icon: nil) { Text("c") }.body
        let _ = SettingsCard(title: "t", subtitle: "s", icon: "number") {
            SettingsRow(title: "行", detail: "说明") { Text("配件") }
        }.body

        // SettingsStatusPill / SidebarInfoCard：纯展示。
        let _ = SettingsStatusPill(title: "已连接", tint: VibeColors.success).body
        let _ = SidebarInfoCard(title: "版本", value: "0.0.77").body

        // SettingsTabBar：六 tab 求值，isSelected 三元 true(选中页)/false(其余五页) 双分支。
        let _ = SettingsTabBar(selection: .constant(.general)).body
        let _ = SettingsTabBar(selection: .constant(.appearance)).body

        // MARK: H. 音频组件（SettingsComponents+Audio）
        let _ = VolumeSliderRow(volume: .constant(0.5)).body
        let _ = VolumeSliderRow(volume: .constant(0)).body
        let _ = PreviewPlaybackButton(isPlaying: .constant(false), resetAfter: 3,
                                      onPlay: {}, onStop: {}).body
        let _ = PreviewPlaybackButton(isPlaying: .constant(true), resetAfter: 5,
                                      onPlay: {}, onStop: {}).body
        let _ = AudioFilePickerRow(title: "自定义提示音", detail: "路径或未选择文件", path: nil,
                                   onPick: { _ in }, onClear: {}).body
        let _ = AudioFilePickerRow(title: "自定义提示音", detail: "路径或未选择文件", path: "/tmp/a.wav",
                                   onPick: { _ in }, onClear: {}).body

        // MARK: I. 品牌图标（SettingsComponents+Navigation）
        // Runner 可执行 bundle 无 AppIcon.icns/png 资源 → 双查找 miss 走 return nil 兜底。
        check("navigation: bundledAppIconImage 在无图标 bundle 走 nil 兜底",
              bundledAppIconImage() == nil)
        let _ = AppLogoBadge().body
        let _ = AppLogoBadge(size: 40).body

        // MARK: J. 快捷键录制按钮（SettingsComponents+Shortcuts，NSButton 真身）
        // 无窗口 CLI 进程里 makeFirstResponder(window=nil) 是 no-op，录制状态机可全流程驱动。
        let captured = CaptureBox()
        let button = ShortcutRecorderButton()
        check("shortcutRecorder: 初始态展示默认快捷键、非录制态样式",
              button.displayedShortcut == HotKeyConfiguration.default.displayString
              && button.attributedTitle.string == HotKeyConfiguration.default.displayString)
        button.displayedShortcut = "⌃X"
        check("shortcutRecorder: displayedShortcut didSet 立即重绘标题",
              button.attributedTitle.string == "⌃X")
        check("shortcutRecorder: resignFirstResponder 复位不崩",
              button.resignFirstResponder())

        // 非录制态 keyDown → super 默认路径。
        if let plainEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_A)) {
            button.keyDown(with: plainEvent)
        }

        // 录制态：mouseDown 进入录制 → 裸 Esc 取消（B165 语义）。
        let mouseEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let mouseEvent {
            button.mouseDown(with: mouseEvent)
            check("shortcutRecorder: mouseDown 进入录制态样式",
                  button.attributedTitle.string == "录制快捷键…")
            if let esc = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: UInt16(kVK_Escape)) {
                button.keyDown(with: esc)
                check("shortcutRecorder: 裸 Esc 退出录制并复位标题",
                      button.attributedTitle.string == "⌃X")
            }
        }

        // 录制态：组合键经 from(event:) 捕获（B164 Carbon 位语义）→ 回调 + 复位。
        if let mouseEvent {
            button.onShortcutCaptured = { captured.value = $0 }
            button.mouseDown(with: mouseEvent)
            if let ctrlQ = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{11}", charactersIgnoringModifiers: "q",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_Q)) {
                button.keyDown(with: ctrlQ)
                check("shortcutRecorder: ⌃Q 捕获回调送达且展示同步",
                      button.displayedShortcut == "⌃Q"
                      && captured.value?.displayString == "⌃Q"
                      && button.attributedTitle.string == "⌃Q")
            }
        }
        button.viewDidChangeEffectiveAppearance()

        // SwiftUI 包装器 ShortcutRecorderView：NSViewRepresentableContext 无公开 init，
        // makeNSView/updateNSView 属渲染装配缝，诚实留白——真身 ShortcutRecorderButton
        // 的行为已在本组全流程直测。

        // DraggableSlider：body 构建（set 闭包属 Slider 内部 Binding，渲染期触发，诚实留白）。
        let _ = DraggableSlider(value: .constant(0.5), minValue: 0, maxValue: 1, step: 0.1).body
        let _ = DraggableSlider(value: .constant(0.5), minValue: 0, maxValue: 1, step: 0).body

        // MARK: K. SettingsView 展示助手（SettingsUI+Helpers，纯 Bundle 读取）
        // @StateObject 初始值是 autoclosure（首次渲染才求值），SettingsView() 构造
        // 不触发 SpaceController/HookServer 等单例——本组断言同时是该契约的守护。
        let settingsView = SettingsView()
        check("settingsHelpers: appVersionDisplay 无 plist 时回落 AppVersion.current",
              settingsView.appVersionDisplay == "v\(AppVersion.current)")
        check("settingsHelpers: bundleIdentifier 无 plist 时回落 AppIdentity.bundleID",
              settingsView.bundleIdentifier == AppIdentity.bundleID)
        check("settingsHelpers: currentAppPath 指向存在的 Runner 可执行",
              !settingsView.currentAppPath.isEmpty
              && FileManager.default.fileExists(atPath: settingsView.currentAppPath))
        check("settingsHelpers: expectedAppPath = ~/Applications/VibeFocus.app",
              settingsView.expectedAppPath
              == (settingsView.expectedAppPath as NSString).deletingLastPathComponent
              || settingsView.expectedAppPath.hasSuffix("/Applications/VibeFocus.app"))
        check("settingsHelpers: resetAccessCommand 拼出 tccutil 重置命令",
              settingsView.resetAccessCommand == "tccutil reset Accessibility \(AppIdentity.bundleID)")
        check("settingsHelpers: otherInstallations 默认空表",
              settingsView.otherInstallations.isEmpty)

        // MARK: L. 标题编辑区块（零单例依赖，偏好走 UserDefaults）
        let _ = settingsView.titleEditorSection.body

        // MARK: M. 网格编排页通用控件（GridSnapshotWidgets）
        let _ = GridSnapshotThumbnail(rows: 2, cols: 3).body
        let _ = GridSnapshotThumbnail(rows: 1, cols: 1).body
        let _ = CompactStepper(value: 3, range: 1...8, onChange: { _ in }).body
        let _ = CompactStepper(value: 1, range: 1...8, onChange: { _ in }).body
        let _ = CompactStepper(value: 8, range: 1...8, onChange: { _ in }).body
    }
}

/// keyDown 捕获回调的送达盒子。
private final class CaptureBox {
    var value: HotKeyConfiguration?
}
