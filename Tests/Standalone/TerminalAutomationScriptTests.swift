// Tests/Standalone/TerminalAutomationScriptTests.swift
// Verification: 终端自动化 AppleScript 构建器族（cellCommand 优先级/双层转义/
//               建窗异步轮询回归/注入寻址/bounds 解析）
// Mirrors: Sources/TerminalGrid/TerminalAutomationScript.swift
// Run: swift Tests/Standalone/TerminalAutomationScriptTests.swift
//
// 背景（2026-09-08）：cellCommand 是网格恢复「格子→完整 shell 命令行」的唯一
// 事实源（cwd 工作目录 → sessionID resume → 启动命令的优先级语义）；建窗模板
// 内嵌真机回归史（Terminal 建窗异步——必须轮询窗口数增加后才能取 front window，
// 2026-09-04 实证）；命令注入统一过 appleScriptEscaped（双层转义：AppleScript
// 层只动反斜杠/双引号，shell 层单引号由 shellQuoted 负责，两层不冲突）。
// Runner 主文件正被 runnersplit 会话拆分中，本批先行镜像锁定，直测段随拆分
// 结构补齐。

import CoreGraphics
import Foundation

// MARK: - Mirrors (与源码同步维护)

let mirrorMainScreenHeight: CGFloat = 1117

func cocoaY(fromQuartzY quartzY: CGFloat) -> CGFloat {
    mirrorMainScreenHeight - quartzY
}

func appleScriptEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func cellCommand(sessionID: String?, cwd: String?, launchCommand: String?) -> String? {
    var parts: [String] = []
    if let cwd, !cwd.isEmpty {
        parts.append("cd \(shellQuoted(cwd))")
    }
    if let sessionID, !sessionID.isEmpty {
        parts.append("claude --resume \(sessionID)")
    } else if let launchCommand, !launchCommand.isEmpty {
        parts.append(launchCommand)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " && ")
}

func terminalCreateWindow(command: String?, quartzFrame: CGRect) -> String {
    let escaped = appleScriptEscaped(command ?? "")
    let bounds = "{\(Int(quartzFrame.minX.rounded())), \(Int(cocoaY(fromQuartzY: quartzFrame.maxY).rounded())), \(Int(quartzFrame.maxX.rounded())), \(Int((cocoaY(fromQuartzY: quartzFrame.maxY) + quartzFrame.height).rounded()))}"
    return """
    tell application id "com.apple.Terminal"
        set priorWindowCount to count of windows
        do script "\(escaped)"
        set waited to 0
        repeat until (count of windows) > priorWindowCount or waited > 100
            delay 0.05
            set waited to waited + 1
        end repeat
        set bounds of front window to \(bounds)
        return id of front window
    end tell
    """
}

func terminalInjectCommand(windowID: UInt32, command: String) -> String {
    """
    tell application id "com.apple.Terminal"
        do script "\(appleScriptEscaped(command))" in window id \(windowID)
    end tell
    """
}

func itermInjectCommand(windowID: String, command: String) -> String {
    """
    tell application id "com.googlecode.iterm2"
        tell current session of window id \(windowID) to write text "\(appleScriptEscaped(command))"
    end tell
    """
}

func itermCreateWindow(command: String?, quartzFrame: CGRect) -> String {
    let writeText = (command?.isEmpty ?? true)
        ? ""
        : "tell current session of current window to write text \"\(appleScriptEscaped(command!))\"\n"
    let bounds = "{\(Int(quartzFrame.minX.rounded())), \(Int(cocoaY(fromQuartzY: quartzFrame.maxY).rounded())), \(Int(quartzFrame.maxX.rounded())), \(Int((cocoaY(fromQuartzY: quartzFrame.maxY) + quartzFrame.height).rounded()))}"
    return """
    tell application id "com.googlecode.iterm2"
        create window with default profile
        \(writeText)set bounds of current window to \(bounds)
        return id of current window
    end tell
    """
}

func parseBounds(_ stdout: String) -> CGRect? {
    let parts = stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { return nil }
    return CGRect(
        x: parts[0],
        y: parts[1],
        width: parts[2] - parts[0],
        height: parts[3] - parts[1]
    )
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Tests

// A. cellCommand 优先级矩阵：cwd → session resume → launchCommand，" && " 连接。
check("cellCmd A1: cwd+session 双段按序连接",
      cellCommand(sessionID: "sid-1", cwd: "/home/prj", launchCommand: nil)
      == "cd '/home/prj' && claude --resume sid-1")
check("cellCmd A2: 仅 cwd；session 为空串视同缺省回退 launchCommand",
      cellCommand(sessionID: nil, cwd: "/home/prj", launchCommand: nil) == "cd '/home/prj'"
      && cellCommand(sessionID: "", cwd: "", launchCommand: "htop") == "htop")
check("cellCmd A3: 全缺省 → nil（格子不注入）",
      cellCommand(sessionID: nil, cwd: nil, launchCommand: nil) == nil
      && cellCommand(sessionID: "", cwd: "", launchCommand: "") == nil)
check("cellCmd A4: cwd 含单引号走 shellQuoted 惯用法（不破 AppleScript 双引号层）",
      cellCommand(sessionID: nil, cwd: "/home/o'brien", launchCommand: nil)
      == #"cd '/home/o'\''brien'"#)

// B. shellQuoted / appleScriptEscaped 双层转义各司其职。
check("esc B1: shellQuoted 单引号惯用法",
      shellQuoted("a'b") == #"'a'\''b'"# && shellQuoted("x") == "'x'")
check("esc B2: AppleScript 层反斜杠与双引号翻倍",
      appleScriptEscaped(#"a\b"c"#) == #"a\\b\"c"#)

// C. 建窗模板：Terminal 异步轮询回归 + iTerm2 条件 writeText。
let qf = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
let tw = terminalCreateWindow(command: #"echo "hi""#, quartzFrame: qf)
check("create C1: Terminal 模板含异步轮询（repeat until count 增加后才取 front window）",
      tw.contains("repeat until (count of windows) > priorWindowCount")
      && tw.contains("set bounds of front window") && tw.contains("return id of front window"))
check("create C2: 命令过 AppleScript 转义后插值",
      tw.contains(#"do script "echo \"hi\"""#))
check("create C3: iTerm2 空命令 → 无 writeText 行（只开 shell）",
      !itermCreateWindow(command: nil, quartzFrame: qf).contains("write text")
      && !itermCreateWindow(command: "", quartzFrame: qf).contains("write text"))
check("create C4: iTerm2 带命令 → writeText 转义注入",
      itermCreateWindow(command: #"say "ok""#, quartzFrame: qf)
      .contains(#"write text "say \"ok\"""#))

// D. 注入模板寻址：Terminal in window id / iTerm2 current session of window id。
check("inject D1: Terminal 注入按 window id 寻址 + 转义",
      terminalInjectCommand(windowID: 42, command: #"ls "x""#)
      .contains(#"do script "ls \"x\"" in window id 42"#))
check("inject D2: iTerm2 注入按 window id 的 current session 寻址",
      itermInjectCommand(windowID: "11513", command: "htop")
      .contains("tell current session of window id 11513 to write text \"htop\""))

// E. parseBounds：四段数值解析 + 宽高差值语义 + 畸形回退。
check("bounds E1: 四段解析 → CGRect(l,t,w=r-l,h=b-t)",
      parseBounds("872, 578, 1726, 1118") == CGRect(x: 872, y: 578, width: 854, height: 540))
check("bounds E2: 非数值段/段数不足 → nil",
      parseBounds("a, b, c, d") == nil && parseBounds("1, 2") == nil)

// MARK: - Summary

print("\nTerminalAutomationScriptTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
