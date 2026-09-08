import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalDialectTests.swift — B64：网格自动化终端身份单一事实源直测
// （automationBundleIDs / usesITermDialect / isAutomationSupported；与 TerminalRegistry
//  的「终端识别超集」语义边界用 ⊆ 不变量锁定）

extension RunnerHarness {
    func runTerminalDialectTests() {
        check("terminalDialect: 支持集恰为 iTerm2 + Apple Terminal",
              TerminalAutomationScript.automationBundleIDs == ["com.apple.Terminal", "com.googlecode.iterm2"])
        check("terminalDialect: usesITermDialect 真值表",
              TerminalAutomationScript.usesITermDialect("com.googlecode.iterm2")
              && !TerminalAutomationScript.usesITermDialect("com.apple.Terminal")
              && !TerminalAutomationScript.usesITermDialect("dev.warp.Warp-Stable")
              && !TerminalAutomationScript.usesITermDialect(""))
        check("terminalDialect: isAutomationSupported 真值表",
              TerminalAutomationScript.isAutomationSupported("com.apple.Terminal")
              && TerminalAutomationScript.isAutomationSupported("com.googlecode.iterm2")
              && !TerminalAutomationScript.isAutomationSupported("dev.warp.Warp-Stable")
              && !TerminalAutomationScript.isAutomationSupported("com.mitchellh.ghostty")
              && !TerminalAutomationScript.isAutomationSupported(""))
        check("terminalDialect: usesITermDialect ⇒ isAutomationSupported（一致性）",
              TerminalAutomationScript.usesITermDialect("com.googlecode.iterm2")
              == TerminalAutomationScript.isAutomationSupported("com.googlecode.iterm2"))
        let subsetOK = TerminalAutomationScript.automationBundleIDs.allSatisfy { id in
            TerminalRegistry.terminalBundleIDs.contains(id)
        }
        check("terminalDialect: 自动化支持集 ⊆ TerminalRegistry 终端识别集（语义边界不变量）", subsetOK)

        // B70：B41 构建器族最后两个零直测成员补齐（镜像 TerminalAutomationScriptTests 退役）。
        check("terminalDialect: itermInjectCommand 按 window id 的 current session 寻址 + AppleScript 转义",
              TerminalAutomationScript.itermInjectCommand(windowID: "11513", command: "htop")
              .contains("tell current session of window id 11513 to write text \"htop\"")
              && TerminalAutomationScript.itermInjectCommand(windowID: "7", command: #"ls "x""#)
              .contains(#"write text "ls \"x\"""#))
        check("terminalDialect: itermGetBounds 模板按 window id 取 bounds",
              TerminalAutomationScript.itermGetBounds(windowID: "11513")
              .contains("return bounds of window id 11513"))
        check("terminalDialect: itermCreateWindow 空命令 → 无 writeText 行（只开 shell）",
              !TerminalAutomationScript.itermCreateWindow(command: nil, quartzFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)).contains("write text")
              && !TerminalAutomationScript.itermCreateWindow(command: "", quartzFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)).contains("write text"))
    }
}
