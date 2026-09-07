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
    }
}
