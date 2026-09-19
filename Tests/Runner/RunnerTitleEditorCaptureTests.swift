import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTitleEditorCaptureTests.swift — 覆盖率批次 20（B251）：
// TitleEditor capture 系（captureCurrentSessionTTY/captureTerminalFrontTabTTY）
// NSAppleScript 执行器协议抽象直测——B251 提缝后测试注入 mock executor，
// 消除对 iTerm2/Terminal 的真实 Automation 授权弹窗风险，三态分支全锁。

private final class MockScriptExecutor: TitleEditorService.AppleScriptExecuting {
    var result: String?
    var errorNumber: Int?
    private(set) var executedSources: [String] = []
    func execute(source: String) -> (stringValue: String?, errorNumber: Int?) {
        executedSources.append(source)
        return (result, errorNumber)
    }
}

extension RunnerHarness {
    func runTitleEditorCaptureTests() {
        // A. captureCurrentSessionTTY：成功/错误/空串三态
        let mock1 = MockScriptExecutor()
        mock1.result = "/dev/ttys004"
        check("titleEditorCapture: iTerm2 tty 成功回传",
              TitleEditorService.captureCurrentSessionTTY(executor: mock1) == "/dev/ttys004")
        check("titleEditorCapture: iTerm2 脚本确为 current session 语义",
              mock1.executedSources[0].contains("iTerm2")
              && mock1.executedSources[0].contains("current session"))
        mock1.errorNumber = -1743
        mock1.result = nil
        check("titleEditorCapture: iTerm2 错误 -1743 → nil（授权失败语义）",
              TitleEditorService.captureCurrentSessionTTY(executor: mock1) == nil)
        mock1.errorNumber = nil
        mock1.result = ""
        check("titleEditorCapture: iTerm2 空串 tty → nil",
              TitleEditorService.captureCurrentSessionTTY(executor: mock1) == nil)

        // B. captureTerminalFrontTabTTY：同三态 + front window 语义
        let mock2 = MockScriptExecutor()
        mock2.result = "/dev/ttys007"
        check("titleEditorCapture: Terminal 前窗 tty 成功回传",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock2) == "/dev/ttys007")
        check("titleEditorCapture: Terminal 脚本确为 front window/selected tab 语义",
              mock2.executedSources[0].contains("Terminal")
              && mock2.executedSources[0].contains("front window"))
        mock2.errorNumber = -1728
        mock2.result = nil
        check("titleEditorCapture: Terminal 错误 → nil",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock2) == nil)
        mock2.errorNumber = nil
        // 实现现状：只挡 isEmpty，空白串原样透传（后续 ssh/write 自然失败）——锁现状。
        mock2.result = "   "
        check("titleEditorCapture: Terminal 空白 tty 原样透传（仅挡 isEmpty）",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock2) == "   ")
    }
}
