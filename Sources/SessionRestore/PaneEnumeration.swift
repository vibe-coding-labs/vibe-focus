import CoreGraphics
import Foundation

// MARK: - 窗内 pane 枚举（脚本 + 解析）
/// 旧实现认定「iTerm2 无 tty 映射」是能力误判：iTerm2 的 AppleScript 字典
/// window→tab→session 自带 tty（2026-09-13 真机验证，48 窗全量拿到）。
/// 这里提供两家的 pane 级枚举脚本与输出解析。

/// iTerm2 枚举输出的一个 session 行
struct ITermSessionEntry: Equatable {
    /// iTerm2 的 AppleScript window id（≠ CGWindowNumber，仅 AppleScript 定位用）
    let windowASID: String
    /// 该 window 的 Cocoa bounds {l,t,r,b}（与 CG 窗口就近匹配的 join 键）
    let windowBounds: CGRect
    /// tab 序（1 起）
    let tabIndex: Int
    /// session 序（1 起，同 tab 内 split）
    let sessionIndex: Int
    /// 终端 TTY（/dev/ttysNNN）
    let tty: String
    /// session 名（远端 shell 常设成项目名，是远程会话匹配的后备信号）
    let name: String
}

@MainActor
enum PaneEnumeration {

    // MARK: iTerm2

    /// 枚举全部 window→tab→session：`ASwinID|tabIdx|sessIdx|tty|l,t,r,b|name` 行。
    /// bounds 供与 yabai/CG 窗口就近匹配（iTerm2 window id 与 CGWindowNumber 不同源）；
    /// name 为 session 名（远端 shell 常设成项目名，远程会话匹配的后备信号）。
    static func itermEnumerateSessions() -> String {
        """
        tell application id "com.googlecode.iterm2"
            set output to ""
            repeat with w in windows
                set wb to bounds of w
                set winID to id of w
                set tabIdx to 0
                repeat with t in tabs of w
                    set tabIdx to tabIdx + 1
                    set sessIdx to 0
                    repeat with s in sessions of t
                        set sessIdx to sessIdx + 1
                        set output to output & (winID as string) & "|" & tabIdx & "|" & sessIdx & "|" & (tty of s as string) & "|" & (item 1 of wb as string) & "," & (item 2 of wb as string) & "," & (item 3 of wb as string) & "," & (item 4 of wb as string) & "|" & (name of s as string) & linefeed
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """
    }

    /// 解析 `ASwinID|tabIdx|sessIdx|tty|l,t,r,b|name` 行流。
    /// 边界（Runner 锁定）：字段数<6 跳过；数字段解析失败跳过；tty 缺 /dev/ 前缀补全；
    /// bounds 四元组解析失败整行跳过；name 可为空；name 自身含 `|` 时第 6 段起
    /// 整体拼回（首 5 列定界不受影响）。
    static func parseITermSessions(_ stdout: String) -> [ITermSessionEntry] {
        var result: [ITermSessionEntry] = []
        for rawLine in stdout.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            if fields.count > 6 {
                let name = fields[5...].joined(separator: "|")
                fields = Array(fields.prefix(5)) + [name]
            }
            guard let tabIndex = Int(fields[1]), tabIndex >= 1,
                  let sessionIndex = Int(fields[2]), sessionIndex >= 1 else { continue }
            var tty = fields[3]
            guard !tty.isEmpty else { continue }
            if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
            let boundsParts = fields[4].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard boundsParts.count == 4 else { continue }
            let bounds = CGRect(
                x: boundsParts[0],
                y: boundsParts[1],
                width: boundsParts[2] - boundsParts[0],
                height: boundsParts[3] - boundsParts[1]
            )
            result.append(ITermSessionEntry(
                windowASID: fields[0],
                windowBounds: bounds,
                tabIndex: tabIndex,
                sessionIndex: sessionIndex,
                tty: tty,
                name: fields[5]
            ))
        }
        return result
    }

    // MARK: Terminal.app

    /// Terminal.app 多 tab tty 枚举输出解析：`windowID|tty` 每行一个 tab
    ///（windowID == CGWindowNumber）。同窗多 tab 聚成有序列表。
    /// 边界：窗口 id 非 UInt32 / 缺 `|` / 空行跳过；tty 缺 /dev/ 前缀补全；
    /// 首个 `|` 后整段视为 tty（tty 路径含 | 不撕列）。
    static func parseTerminalTabTTYs(_ stdout: String) -> [UInt32: [String]] {
        var mapping: [UInt32: [String]] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let windowID = UInt32(parts[0]) else { continue }
            var tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty else { continue }
            if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
            mapping[windowID, default: []].append(tty)
        }
        return mapping
    }

    // MARK: 共用

    /// 恢复期向 iTerm2 既有窗口追加 tab 并写入命令（多 pane 重建路径）
    static func itermAppendTab(windowASID: String, command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            tell window id \(windowASID)
                create tab with default profile
                tell current session to write text "\(TerminalAutomationScript.appleScriptEscaped(command))"
            end tell
        end tell
        """
    }

    /// 向 iTerm2 指定 session（tab/pane 序，1 起）注入命令（活窗空闲 pane 注入路径）
    static func itermWriteToSession(windowASID: String, tabIndex: Int, sessionIndex: Int, command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            tell session \(sessionIndex) of tab \(tabIndex) of window id \(windowASID) to write text "\(TerminalAutomationScript.appleScriptEscaped(command))"
        end tell
        """
    }

    /// 向 iTerm2 窗口的当前 session 写命令（pane 序号未知时的注入兜底）
    static func itermWriteToWindow(windowASID: String, command: String) -> String {
        TerminalAutomationScript.itermInjectCommand(windowID: windowASID, command: command)
    }

    /// Terminal.app 向既有窗口注入（do script in window 语义 = 开新 tab；多 tab 重建与活窗注入共用）
    static func terminalWriteToWindow(windowCGID: UInt32, command: String) -> String {
        TerminalAutomationScript.terminalInjectCommand(windowID: windowCGID, command: command)
    }

    /// CG 窗口 ↔ iTerm2 window 就近匹配（两者坐标同空间：左上原点全局）。
    /// 纯决策：候选已由调用方采集。超出容差拒配（宁缺毋错）。
    static func matchITermWindow(
        cgFrame: CGRect,
        candidates: [(windowASID: String, bounds: CGRect)],
        usedASIDs: Set<String>,
        maxDistance: CGFloat = 40
    ) -> String? {
        var best: (asid: String, distance: CGFloat)?
        for candidate in candidates where !usedASIDs.contains(candidate.windowASID) {
            let d = hypot(
                candidate.bounds.midX - cgFrame.midX,
                candidate.bounds.midY - cgFrame.midY
            )
            if best == nil || d < best!.distance {
                best = (candidate.windowASID, d)
            }
        }
        guard let best, best.distance < maxDistance else { return nil }
        return best.asid
    }
}
