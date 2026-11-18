import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTitleEditorSeamTests.swift
// 靶：TitleEditorService 标题写入编排（TitleEditorEnvironment 注入）——
// 空标题早退、三路写（AX/AppleScript/TTY）、iTerm2 跳过 TTY、
// autoSetTitle 用户命名优先跳过与自动应用、autoTitle 纯函数模板。
// 零 AX 写入、零 AppleScript/TTY fork。

final class TitleEditorSeamState: @unchecked Sendable {
    var handle: UInt32? = 9001
    var axResult = true
    var scriptResult = true
    var ttyResult = true
    var axTitles: [String] = []
    var scriptTitles: [(title: String, bundleID: String, tty: String?)] = []
    var ttyTitles: [(title: String, pid: pid_t)] = []
}

extension RunnerHarness {
    func runTitleEditorSeamTests() {
        let state = TitleEditorSeamState()
        let ax = AXUIElementCreateSystemWide()

        func makeEnv() -> TitleEditorEnvironment {
            TitleEditorEnvironment(
                windowHandle: { _ in state.handle },
                applyViaAX: { title, _ in
                    state.axTitles.append(title)
                    return state.axResult
                },
                applyViaAppleScript: { title, bundleID, tty in
                    state.scriptTitles.append((title, bundleID, tty))
                    return state.scriptResult
                },
                applyViaTTY: { title, pid in
                    state.ttyTitles.append((title, pid))
                    return state.ttyResult
                }
            )
        }
        func reset() {
            state.handle = 9001
            state.axResult = true
            state.scriptResult = true
            state.ttyResult = true
            state.axTitles = []
            state.scriptTitles = []
            state.ttyTitles = []
            TitleEditorService.shared.userRenamedWindowIDs = []
        }
        let service = TitleEditorService.shared

        // A. 空标题早退
        reset()
        service.applyTitle("   ", to: ax, pid: 4242, bundleID: "com.apple.Terminal",
                            targetTTY: nil, environment: makeEnv())
        check("titleEditor A1: 空白标题 → 三路均不写",
              state.axTitles.isEmpty && state.scriptTitles.isEmpty && state.ttyTitles.isEmpty)

        // B. 非 iTerm2：三路全写（title 去空白）
        reset()
        service.applyTitle("  hi  ", to: ax, pid: 4242, bundleID: "com.apple.Terminal",
                            targetTTY: "/dev/ttys001", environment: makeEnv())
        check("titleEditor B1: AX + AppleScript + TTY 各一次且标题已 trim",
              state.axTitles == ["hi"] && state.scriptTitles.count == 1
              && state.scriptTitles[0].title == "hi" && state.ttyTitles.count == 1)
        check("titleEditor B2: 定向写入键 targetTTY 透传",
              state.scriptTitles[0].tty == "/dev/ttys001")

        // C. iTerm2 + AppleScript 成功 → 跳过 TTY
        reset()
        service.applyTitle("iterm", to: ax, pid: 4242, bundleID: "com.googlecode.iterm2",
                            targetTTY: nil, environment: makeEnv())
        check("titleEditor C1: iTerm2 AppleScript 成功 → 跳过 TTY",
              state.scriptTitles.count == 1 && state.ttyTitles.isEmpty)

        // D. iTerm2 + AppleScript 失败 → TTY 兜底
        reset()
        state.scriptResult = false
        service.applyTitle("iterm2", to: ax, pid: 4242, bundleID: "com.googlecode.iterm2",
                            targetTTY: nil, environment: makeEnv())
        check("titleEditor D1: iTerm2 AppleScript 失败 → TTY 仍执行",
              state.ttyTitles.count == 1 && state.ttyTitles[0].title == "iterm2")

        // E. autoSetTitle：用户已手动命名 → 跳过
        reset()
        service.userRenamedWindowIDs = [9001]
        service.autoSetTitle(cwd: "/tmp/proj", pid: 4242, bundleID: "com.apple.Terminal",
                             window: ax, environment: makeEnv())
        check("titleEditor E1: 用户命名优先 → 自动标题整链跳过",
              state.axTitles.isEmpty && state.scriptTitles.isEmpty && state.ttyTitles.isEmpty)

        // F. autoSetTitle：未命名 → 按 cwd 末段生成并三路写
        reset()
        service.autoSetTitle(cwd: "/Users/me/proj", pid: 4242, bundleID: "com.apple.Terminal",
                             window: ax, environment: makeEnv())
        check("titleEditor F1: 自动标题 = 项目名 — Claude Code",
              state.axTitles == ["proj — Claude Code"])

        // G. autoSetTitle：拿不到窗口句柄 → 不跳过，仍写
        reset()
        state.handle = nil
        service.autoSetTitle(cwd: "/tmp/proj", pid: 4242, bundleID: "com.apple.Terminal",
                             window: ax, environment: makeEnv())
        check("titleEditor G1: 句柄缺失 → 不误判用户命名，照常写",
              state.axTitles.count == 1)

        // H. autoTitle 模板纯函数
        check("titleEditor H1: cwd 末段作为项目名",
              TitleEditorService.autoTitle(forCWD: "/a/b/c") == "c — Claude Code")
        check("titleEditor H2: cwd 空/nil 兜底 Claude",
              TitleEditorService.autoTitle(forCWD: nil) == "Claude — Claude Code"
              && TitleEditorService.autoTitle(forCWD: "") == "Claude — Claude Code")
    }
}
