import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerScriptExecutorTests.swift — 覆盖率批次 47（B283）：
// NSAppleScriptExecutor.execute 真实执行器本体直测——用不触碰任何 app 的
// 纯计算 AppleScript（算术/文本拼接/语法错误），零 Automation 授权风险。
// 成功路径 stringValue 回传；语法错误路径 errorNumber 非 nil。

extension RunnerHarness {
    func runScriptExecutorTests() {
        let executor = TitleEditorService.NSAppleScriptExecutor()

        // 成功路径：纯计算脚本（不 tell 任何 app，零授权风险）。
        let ok = executor.execute(source: "return 21 + 21")
        check("scriptExecutor: 纯计算脚本 stringValue 回传",
              ok.stringValue == "42" && ok.errorNumber == nil)

        // 文本拼接：AppleScript 字符串语义。
        let concat = executor.execute(source: #"return "a" & "b""#)
        check("scriptExecutor: 字符串拼接回传", concat.stringValue == "ab")

        // 语法错误路径：errorNumber 非 nil、stringValue nil。
        let bad = executor.execute(source: "return (((")
        check("scriptExecutor: 语法错误 → errorNumber 非 nil",
              bad.stringValue == nil && bad.errorNumber != nil)
    }
}
