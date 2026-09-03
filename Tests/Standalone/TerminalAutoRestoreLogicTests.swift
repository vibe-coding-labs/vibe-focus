// Tests/Standalone/TerminalAutoRestoreLogicTests.swift
// Verification: Terminal 网格自动恢复纯逻辑——cellCommand cwd 层 / shell 引号 / 规划器三态
// Mirrors: Sources/TerminalGrid/TerminalAutomationScript.swift, Sources/TerminalGrid/TerminalAutoRestorePlan.swift
// Run: swift Tests/Standalone/TerminalAutoRestoreLogicTests.swift

import CoreGraphics
import Foundation

// MARK: - Mirrored logic

struct TerminalGridCellSnapshot {
    var index: Int
    var sessionID: String?
    var cwd: String?
}

enum TerminalAutomationScript {
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func cellCommand(sessionID: String?, cwd: String?, launchCommand: String?) -> String? {
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
}

struct TerminalLiveWindow { let windowID: Int; let frame: CGRect; let hasLiveClaude: Bool }
enum TerminalAutoRestoreCellAction: Equatable { case create; case inject(windowID: Int); case skipRunning }

enum TerminalAutoRestorePlanner {
    static let frameTolerance: CGFloat = 15
    static func plan(cells: [TerminalGridCellSnapshot], frames: [CGRect], live: [TerminalLiveWindow], injectEnabled: Bool = true) -> [TerminalAutoRestoreCellAction] {
        var used = Set<Int>()
        var actions: [TerminalAutoRestoreCellAction] = []
        for (index, _) in cells.enumerated() {
            guard index < frames.count else { break }
            let frame = frames[index]
            let matched = live.first { l in
                !used.contains(l.windowID)
                    && hypot(l.frame.midX - frame.midX, l.frame.midY - frame.midY) <= frameTolerance
            }
            if let l = matched {
                used.insert(l.windowID)
                if !injectEnabled { actions.append(.skipRunning) }
                else if l.hasLiveClaude { actions.append(.skipRunning) }
                else { actions.append(.inject(windowID: l.windowID)) }
            } else {
                actions.append(.create)
            }
        }
        return actions
    }
}

// MARK: - Harness

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// cellCommand：cwd 层
check("命令: cd + resume 组合", TerminalAutomationScript.cellCommand(sessionID: "s1", cwd: "/Users/x/My Dir", launchCommand: nil) == "cd '/Users/x/My Dir' && claude --resume s1")
check("命令: 纯 shell 只 cd", TerminalAutomationScript.cellCommand(sessionID: nil, cwd: "/tmp", launchCommand: nil) == "cd '/tmp'")
check("命令: 无 session 回落启动命令（带 cwd）", TerminalAutomationScript.cellCommand(sessionID: nil, cwd: "/tmp", launchCommand: "claude") == "cd '/tmp' && claude")
check("命令: 全空 → nil", TerminalAutomationScript.cellCommand(sessionID: nil, cwd: nil, launchCommand: nil) == nil)
check("引号: 单引号 POSIX 转义", TerminalAutomationScript.shellQuoted("it's here") == "'it'\\''s here'")
check("引号: 常规路径包裹", TerminalAutomationScript.shellQuoted("/Users/cc/code") == "'/Users/cc/code'")

// 规划器三态
let frames = [CGRect(x: 0, y: 0, width: 800, height: 500), CGRect(x: 808, y: 0, width: 800, height: 500)]
let cells = [TerminalGridCellSnapshot(index: 0, sessionID: "s1", cwd: "/a"),
             TerminalGridCellSnapshot(index: 1, sessionID: nil, cwd: nil)]
let liveClaude = TerminalLiveWindow(windowID: 101, frame: frames[0], hasLiveClaude: true)
let liveIdle = TerminalLiveWindow(windowID: 102, frame: CGRect(x: 810, y: 2, width: 800, height: 500), hasLiveClaude: false)
let actions = TerminalAutoRestorePlanner.plan(cells: cells, frames: frames, live: [liveClaude, liveIdle])
check("规划器: claude 在跑 → skip", actions[0] == .skipRunning)
check("规划器: 空闲窗口 → inject", actions[1] == .inject(windowID: 102))
check("规划器: 格位空 → create", TerminalAutoRestorePlanner.plan(cells: cells, frames: frames, live: []) == [.create, .create])
check("规划器: 距离超容差不匹配", TerminalAutoRestorePlanner.plan(cells: [cells[0]], frames: [frames[0]], live: [TerminalLiveWindow(windowID: 9, frame: CGRect(x: 5000, y: 5000, width: 800, height: 500), hasLiveClaude: false)]) == [.create])
check("规划器: 禁注入时匹配→skip 缺失→create", TerminalAutoRestorePlanner.plan(cells: cells, frames: frames, live: [liveClaude], injectEnabled: false) == [.skipRunning, .create])
let stacked = TerminalAutoRestorePlanner.plan(cells: cells, frames: [frames[0], frames[0]], live: [TerminalLiveWindow(windowID: 201, frame: frames[0], hasLiveClaude: false)])
check("规划器: 同窗口不被重复认领", stacked == [.inject(windowID: 201), .create])

print("")
print("TerminalAutoRestoreLogicTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
