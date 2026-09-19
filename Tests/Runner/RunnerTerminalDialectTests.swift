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

extension RunnerHarness {
    /// B217：脚本构建器族零覆盖散点收编——parseBounds 解析器、Terminal 枚举/读界脚本、
    /// PaneEnumeration 双构建器（此前直测只覆盖同族其余成员）。
    func runTerminalScriptStragglerTests() {
        print("\n=== TerminalScriptStragglers (B217) ===")

        // --- parseBounds："l, t, r, b" 逗号串 → Quartz frame（宽高=右下减左上） ---
        let parsed = TerminalAutomationScript.parseBounds("872, 578, 1726, 1118")
        check("straggler: parseBounds 四元组换算 frame",
              parsed == CGRect(x: 872, y: 578, width: 854, height: 540))
        check("straggler: parseBounds 容忍换行与多余空白",
              TerminalAutomationScript.parseBounds("\n  0, 0 , 100,  50 \n") == CGRect(x: 0, y: 0, width: 100, height: 50))
        check("straggler: parseBounds 非数字 → nil",
              TerminalAutomationScript.parseBounds("a, b, c, d") == nil)
        check("straggler: parseBounds 不足四数 → nil",
              TerminalAutomationScript.parseBounds("1, 2, 3") == nil)
        check("straggler: parseBounds 空串 → nil",
              TerminalAutomationScript.parseBounds("") == nil)

        // --- Terminal.app 枚举/读界脚本：结构关键位（id|tty 行格式 + window id 定位） ---
        let enumScript = TerminalAutomationScript.terminalEnumerateWindowTTYs()
        check("straggler: 枚举脚本指名 Terminal + 产出 id|tty 行",
              enumScript.contains("com.apple.Terminal")
              && enumScript.contains("(id of w as string) & \"|\" & (tty of t)"))
        let boundsScript = TerminalAutomationScript.terminalGetBounds(windowID: 42)
        check("straggler: 读界脚本 return bounds of window id 42",
              boundsScript.contains("return bounds of window id 42"))

        // --- PaneEnumeration：追加 tab / 定向 session 注入构建器 ---
        let appendTab = PaneEnumeration.itermAppendTab(windowASID: "7", command: "echo hi")
        check("straggler: itermAppendTab 挂窗 7 + create tab + 写命令",
              appendTab.contains("tell window id 7")
              && appendTab.contains("create tab with default profile")
              && appendTab.contains("write text \"echo hi\""))
        let escaped = PaneEnumeration.itermAppendTab(windowASID: "7", command: "say \"quoted\"")
        check("straggler: itermAppendTab 命令内引号转义",
              escaped.contains("\\\"quoted\\\"") && !escaped.contains("say \"quoted\""))
        let toSession = PaneEnumeration.itermWriteToSession(windowASID: "9", tabIndex: 2, sessionIndex: 3, command: "cd /tmp")
        check("straggler: itermWriteToSession 定位 session 3 of tab 2 of window 9",
              toSession.contains("tell session 3 of tab 2 of window id 9 to write text \"cd /tmp\""))
    }
}

extension RunnerHarness {
    /// B219：itermEnumerateSessions 构建器结构关键位（winID|tab|sess|tty|bounds|name 行格式）。
    func runItermEnumerateSessionsScriptTests() {
        print("\n=== ItermEnumerateSessions (B219) ===")
        let script = PaneEnumeration.itermEnumerateSessions()
        check("itermEnum: 指名 iTerm2 + 三层 repeat（windows/tabs/sessions）",
              script.contains("com.googlecode.iterm2")
              && script.contains("repeat with w in windows")
              && script.contains("repeat with t in tabs of w")
              && script.contains("repeat with s in sessions of t"))
        check("itermEnum: 行格式五字段管道（id|tab|sess|tty|bounds|name）",
              script.contains("\"|\" & tabIdx & \"|\" & sessIdx & \"|\" & (tty of s as string)")
              && script.contains("(name of s as string) & linefeed"))
    }
}
