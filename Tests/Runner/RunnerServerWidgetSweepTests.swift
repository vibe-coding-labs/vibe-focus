import AppKit
import Carbon
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerServerWidgetSweepTests.swift — B231 服务端守卫与设置组件扫尾
// 靶：ClaudeHookServer 禁用/非法端口守卫分支（不启动真服务）/ GridSnapshotWidgets
// 纯参数视图离屏渲染 / ShortcutRecorderButton 直构与按键透传。
// 纪律：绝不调用 setEnabled/register 等会触系统对话框或真实登录项注册的通道；
// hook 服务只走非法端口守卫（不 bind 任何端口）。

extension RunnerHarness {
    func runServerWidgetSweepTests() {
        runHookServerGuardBranches()
        runGridSnapshotWidgetRendering()
        runShortcutButtonDirectTests()
    }

    // MARK: - ClaudeHookServer：禁用短路 + 非法端口守卫

    private func runHookServerGuardBranches() {
        let server = ClaudeHookServer.shared
        let savedEnabled = ClaudeHookPreferences.isEnabled
        defer { ClaudeHookPreferences.isEnabled = savedEnabled }

        // 禁用分支：isEnabled=false → stop() 短路，不写脚本不装配置不起服务
        ClaudeHookPreferences.isEnabled = false
        server.applyPreferences()
        check("server A1: 禁用态 applyPreferences → 未运行", !server.isRunning)

        // 非法端口守卫：port=0 → 状态明示「端口无效」，不起服务
        ClaudeHookPreferences.isEnabled = true
        server.startIfNeeded(port: 0, token: "ut100-tok")
        check("server A2: port=0 → 端口无效守卫（isRunning=false + 错误文案）",
              !server.isRunning
              && server.statusDescription == "端口无效"
              && server.lastErrorMessage?.contains("Invalid port") == true)
        server.startIfNeeded(port: -5, token: "ut100-tok")
        check("server A3: 负端口同样被守卫", !server.isRunning)

        // 收尾：恢复禁用态短路（不留监听）
        ClaudeHookPreferences.isEnabled = false
        server.applyPreferences()
        check("server A4: 收尾恢复禁用 → 未运行", !server.isRunning)
    }

    // MARK: - GridSnapshotWidgets：纯参数视图离屏渲染

    private func runGridSnapshotWidgetRendering() {
        let thumb = GridSnapshotThumbnail(rows: 2, cols: 3)
        let thumbRender = ImageRenderer(content: thumb.frame(width: 120, height: 80))
        thumbRender.scale = 1
        check("widget B1: 快照缩略图离屏渲染成功", thumbRender.nsImage != nil)

        var stepped: [Int] = []
        let stepper = CompactStepper(value: 5, range: 2...8, onChange: { stepped.append($0) })
        let stepperRender = ImageRenderer(content: stepper.frame(width: 140, height: 28))
        stepperRender.scale = 1
        check("widget B2: 步进器离屏渲染成功", stepperRender.nsImage != nil)
        _ = stepped
    }

    // MARK: - ShortcutRecorderButton：直构 + 非修饰键 keyDown 透传

    private func runShortcutButtonDirectTests() {
        let button = ShortcutRecorderButton()
        button.frame = NSRect(x: 0, y: 0, width: 100, height: 24)

        // displayedShortcut 字符串读写往返（NSViewRepresentable 同款赋值语义）
        let config = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey))
        button.displayedShortcut = config.displayString
        check("shortcut C1: displayedShortcut 赋值往返",
              button.displayedShortcut == config.displayString)

        // 零修饰 keyDown → 纯修饰键兜底透传 super（不捕获、不崩溃）
        func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: keyCode
            )!
        }
        button.keyDown(with: keyEvent(keyCode: UInt16(kVK_ANSI_A), modifiers: []))
        check("shortcut C2: 零修饰 keyDown 透传不崩", true)

        // 带修饰 keyDown：录制态之外不消费（onShortcutCaptured 未挂 → 静默）
        button.keyDown(with: keyEvent(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command]))
        check("shortcut C3: 修饰键 keyDown 未挂回调安全", true)
    }
}
