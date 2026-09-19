import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAppleScriptDirectedTests.swift — 覆盖率批次 37（B269）：
// applyViaAppleScript 定向 tty 分支直测（B251 scriptExecutor 静态注入点复用）。
//
// mock executor 编程化响应：定向路径的哨兵判定（result == "matched"）决定成败——
// matched → true（含 Terminal 诊断 readback 段）；非 matched → tty_session_not_found
// false。全程零真实 osascript（不触 Automation 授权、不改终端标题）。

private final class ProgrammaticScriptExecutor: TitleEditorService.AppleScriptExecuting {
    /// 每次 execute 弹出一个响应（result, errorNumber）
    var responses: [(String?, Int?)] = []
    private(set) var executedCount = 0
    func execute(source: String) -> (stringValue: String?, errorNumber: Int?) {
        executedCount += 1
        guard !responses.isEmpty else { return (nil, -1) }
        return responses.removeFirst()
    }
}

extension RunnerHarness {
    func runAppleScriptDirectedTests() {
        let savedExecutor = TitleEditorService.scriptExecutor
        defer { TitleEditorService.scriptExecutor = savedExecutor }

        let manager = TitleEditorService.shared

        // MARK: A. 定向 tty：哨兵 matched → 成功（Terminal 还有诊断 readback 第二次执行）
        let matchedExecutor = ProgrammaticScriptExecutor()
        matchedExecutor.responses = [("matched", nil), ("Custom|1", nil)]
        TitleEditorService.scriptExecutor = matchedExecutor
        let ok = manager.applyViaAppleScript(
            "定向标题", bundleID: "com.apple.Terminal", targetTTY: "/dev/ttys001")
        check("appleScriptDirected: matched 哨兵 → 成功且诊断 readback 走两次执行",
              ok && matchedExecutor.executedCount == 2
              && matchedExecutor.responses.isEmpty)

        // MARK: B. 定向 tty：非 matched → tty_session_not_found 失败
        let missExecutor = ProgrammaticScriptExecutor()
        missExecutor.responses = [("nomatch", nil)]
        TitleEditorService.scriptExecutor = missExecutor
        let miss = manager.applyViaAppleScript(
            "定向标题", bundleID: "com.apple.Terminal", targetTTY: "/dev/ttys999")
        check("appleScriptDirected: 非 matched 哨兵 → false（tty_session_not_found）",
              miss == false)
        // MARK: C. 定向 tty：执行错误 → false
        let errExecutor = ProgrammaticScriptExecutor()
        errExecutor.responses = [(nil, -1743)]
        TitleEditorService.scriptExecutor = errExecutor
        let err = manager.applyViaAppleScript(
            "定向标题", bundleID: "com.apple.Terminal", targetTTY: "/dev/ttys001")
        check("appleScriptDirected: 执行错误 → false（-1743 Automation 拒绝）",
              err == false)

        // MARK: D. unsupported bundle（经 scriptExecutor 真通道）：makeTitleScript nil → false
        let unsupported = manager.applyViaAppleScript(
            "任意", bundleID: "com.example.notaterminal", targetTTY: nil)
        check("appleScriptDirected: 不可识别 bundle → unsupported false",
              unsupported == false)

        // MARK: E. 非定向 Terminal：front window 旧语义成功路径（含诊断 readback）
        let frontExecutor = ProgrammaticScriptExecutor()
        frontExecutor.responses = [("matched", nil), ("Custom|0", nil)]
        TitleEditorService.scriptExecutor = frontExecutor
        let frontOK = manager.applyViaAppleScript(
            "前置语义标题", bundleID: "com.apple.Terminal", targetTTY: nil)
        check("appleScriptDirected: 非定向 Terminal 成功且诊断 readback 触发",
              frontOK && frontExecutor.executedCount == 2
              && frontExecutor.responses.isEmpty)
    }
}
