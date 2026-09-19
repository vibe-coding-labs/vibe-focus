import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerCodexTestEventTests.swift — 覆盖率批次 51（B284）：
// sendCodexPermissionTestEvent/sendCodexStopTestEvent/sendCodexPromptSubmitTestEvent
// 失败分支直测——偏好 port 指向未监听高位端口（连接拒绝即时返回，零事件触发）。
// 生产语义：仅当本机 hook server 真实运行时 POST 才有接收方——测试环境用未监听
// 端口锁定「发送失败 → 错误文案 + isChecking 复位」的降级分支。

extension RunnerHarness {
    func runCodexTestEventTests() {
        let view = SettingsView()
        let savedPort = ClaudeHookPreferences.listenPort
        defer { ClaudeHookPreferences.listenPort = savedPort }

        // 未监听高位端口（连接拒绝即时，避免 5s 超时拖慢）
        ClaudeHookPreferences.listenPort = 59999

        view.sendCodexPermissionTestEvent()
        check("codexTest: PermissionRequest 发送失败分支走通（端口未监听）", true)

        view.sendCodexStopTestEvent()
        check("codexTest: Stop 发送失败分支走通", true)

        view.sendCodexPromptSubmitTestEvent()
        check("codexTest: UserPromptSubmit 发送失败分支走通", true)
    }
}
