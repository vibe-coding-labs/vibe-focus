import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTitleEditorChannelsSeamTests.swift
// 靶：TitleEditorService+Channels 的写入通道本体（scriptExecutor 注入缝）——
// 不支持 bundle / 非定向成功 / 定向 matched / 定向未命中 / 脚本报错 /
// Terminal 诊断回读二次执行 / AX 不可写早退 / 两个 tty 捕获函数的三种结果。
// 纪律：零真实 AppleScript 执行、零授权弹窗（不构造 -1743 用例）。

final class TitleScriptMockExecutor: AppleScriptExecuting, @unchecked Sendable {
    var results: [(stringValue: String?, errorNumber: Int?)] = []
    var sources: [String] = []

    func execute(source: String) -> (stringValue: String?, errorNumber: Int?) {
        sources.append(source)
        if results.isEmpty { return (nil, nil) }
        return results.removeFirst()
    }
}

extension RunnerHarness {
    func runTitleEditorChannelsSeamTests() {
        let service = TitleEditorService.shared
        let mock = TitleScriptMockExecutor()
        let original = TitleEditorService.scriptExecutor
        TitleEditorService.scriptExecutor = mock
        defer { TitleEditorService.scriptExecutor = original }

        func reset() {
            mock.results = []
            mock.sources = []
        }

        // A. 不支持的 bundle → 不构造脚本、不执行
        reset()
        check("titleChannels A1: 不支持 bundle → false 且零 AppleScript",
              service.applyViaAppleScript("t", bundleID: "com.example.unknown") == false
              && mock.sources.isEmpty)

        // A2. 非定向（targetTTY=nil）执行成功
        reset()
        mock.results = [("ignored", nil)]
        check("titleChannels A2: 非定向执行成功 → true 且脚本含标题",
              service.applyViaAppleScript("my-title", bundleID: "com.googlecode.iterm2") == true
              && mock.sources.count == 1 && mock.sources[0].contains("my-title"))

        // A3. 定向 + matched 判据 → 成功
        reset()
        mock.results = [("matched", nil)]
        check("titleChannels A3: 定向 tty + matched → true",
              service.applyViaAppleScript("t", bundleID: "com.googlecode.iterm2",
                                          targetTTY: "/dev/ttys001") == true
              && mock.sources.count == 1 && mock.sources[0].contains("/dev/ttys001"))

        // A4. 定向 + 非 matched（即便同时带错误号）→ 判未命中，先于错误分支
        reset()
        mock.results = [(nil, -1728)]
        check("titleChannels A4: 定向未命中 → false（判据先于错误号）",
              service.applyViaAppleScript("t", bundleID: "com.googlecode.iterm2",
                                          targetTTY: "/dev/ttys001") == false)

        // A5. 非定向脚本报错（非 -1743，不触发权限弹窗）→ false
        reset()
        mock.results = [(nil, -1728)]
        check("titleChannels A5: 脚本报错 → false",
              service.applyViaAppleScript("t", bundleID: "com.googlecode.iterm2") == false)

        // A6. Terminal 成功 → 诊断回读二次执行
        reset()
        mock.results = [("matched", nil), ("title|true", nil)]
        check("titleChannels A6: Terminal 成功 → 诊断回读二次执行",
              service.applyViaAppleScript("t", bundleID: "com.apple.Terminal",
                                          targetTTY: "/dev/ttys001") == true
              && mock.sources.count == 2 && mock.sources[1].contains("custom title of"))

        // A7. Terminal 诊断回读为空 → 仍成功
        reset()
        mock.results = [("matched", nil), (nil, nil)]
        check("titleChannels A7: 诊断回读为空不影响主结果",
              service.applyViaAppleScript("t", bundleID: "com.apple.Terminal",
                                          targetTTY: "/dev/ttys001") == true)

        // B. AX 通道：系统级元素非 settable → 早退 false
        check("titleChannels B1: 不可写元素 → false",
              service.applyViaAX("t", to: AXUIElementCreateSystemWide()) == false)

        // C. iTerm2 当前会话 tty 捕获
        reset()
        mock.results = [(nil, -1728)]
        check("titleChannels C1: 捕获报错 → nil",
              TitleEditorService.captureCurrentSessionTTY(executor: mock) == nil)
        reset()
        mock.results = [("", nil)]
        check("titleChannels C2: 捕获空串 → nil",
              TitleEditorService.captureCurrentSessionTTY(executor: mock) == nil)
        reset()
        mock.results = [("/dev/ttys009", nil)]
        check("titleChannels C3: 捕获成功 → tty 且脚本问 iTerm2",
              TitleEditorService.captureCurrentSessionTTY(executor: mock) == "/dev/ttys009"
              && mock.sources.count == 1 && mock.sources[0].contains("iTerm2"))

        // D. Terminal 前窗 tab tty 捕获
        reset()
        mock.results = [(nil, -1728)]
        check("titleChannels D1: 捕获报错 → nil",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock) == nil)
        reset()
        mock.results = [(nil, nil)]
        check("titleChannels D2: 无输出 → nil",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock) == nil)
        reset()
        mock.results = [("/dev/ttys010", nil)]
        check("titleChannels D3: 捕获成功 → tty 且脚本问前窗选中 tab",
              TitleEditorService.captureTerminalFrontTabTTY(executor: mock) == "/dev/ttys010"
              && mock.sources.count == 1 && mock.sources[0].contains("selected tab of front window"))
    }
}
