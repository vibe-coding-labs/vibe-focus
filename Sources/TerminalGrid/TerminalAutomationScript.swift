import CoreGraphics
import Foundation

// MARK: - 终端自动化 AppleScript 生成器（纯字符串，无 I/O）
/// 坐标注记：AppleScript `bounds` 是 Cocoa 全局坐标 {left, top, right, bottom}；
/// 本仓内部 frame 是 Quartz（Y 向下）。换算走 CoordinateKit.cocoaY(fromQuartzY:)，
/// 本文件只负责把换算好的 cocoaTop 拼进脚本。
/// 命令注入防御：所有插值字符串先过 appleScriptEscaped。
@MainActor
enum TerminalAutomationScript {

    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Quartz frame → Cocoa {l, t, r, b} 四元组字符串
    static func cocoaBoundsTuple(quartzFrame: CGRect) -> String {
        let cocoaTop = CoordinateKit.cocoaY(fromQuartzY: quartzFrame.maxY)
        let left = Int(quartzFrame.minX.rounded())
        let top = Int(cocoaTop.rounded())
        let right = Int(quartzFrame.maxX.rounded())
        let bottom = Int((cocoaTop + quartzFrame.height).rounded())
        return "{\(left), \(top), \(right), \(bottom)}"
    }

    // MARK: Terminal.app

    /// 新建窗口并摆到指定 bounds，返回新窗口 id（即 CGWindowNumber）。
    /// command 为 nil/空时只开 shell。
    /// 真机实证（2026-09-04）：`do script` 建窗是异步的——Terminal 零窗口时
    /// 紧跟的 `front window` 会报 Invalid index(-1719)，必须轮询等窗口数增加。
    static func terminalCreateWindow(command: String?, quartzFrame: CGRect) -> String {
        let escaped = appleScriptEscaped(command ?? "")
        return """
        tell application id "com.apple.Terminal"
            set priorWindowCount to count of windows
            do script "\(escaped)"
            set waited to 0
            repeat until (count of windows) > priorWindowCount or waited > 100
                delay 0.05
                set waited to waited + 1
            end repeat
            set bounds of front window to \(cocoaBoundsTuple(quartzFrame: quartzFrame))
            return id of front window
        end tell
        """
    }

    /// 全量枚举窗口→tab→tty 映射："windowID|tty" 行。Terminal.app 的 AppleScript
    /// window id == CGWindowNumber（仓库 TerminalContext 链路既有实证）。
    static func terminalEnumerateWindowTTYs() -> String {
        """
        tell application id "com.apple.Terminal"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (id of w as string) & "|" & (tty of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
    }

    /// 读回窗口 bounds（{l,t,r,b} 逗号串）——读回值与 Quartz 同为左上原点 Y 向下
    static func terminalGetBounds(windowID: UInt32) -> String {
        """
        tell application id "com.apple.Terminal"
            return bounds of window id \(windowID)
        end tell
        """
    }

    /// 向既有窗口注入命令（自动恢复"活窗口复用"路径——不重建窗口，防重复）
    static func terminalInjectCommand(windowID: UInt32, command: String) -> String {
        """
        tell application id "com.apple.Terminal"
            do script "\(appleScriptEscaped(command))" in window id \(windowID)
        end tell
        """
    }

    static func itermInjectCommand(windowID: String, command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            tell current session of window id \(windowID) to write text "\(appleScriptEscaped(command))"
        end tell
        """
    }

    static func itermGetBounds(windowID: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            return bounds of window id \(windowID)
        end tell
        """
    }

    /// "872, 578, 1726, 1118" → CGRect(l, t, w, h)（Quartz/左上原点语义）
    static func parseBounds(_ stdout: String) -> CGRect? {
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

    // MARK: iTerm2

    static func itermCreateWindow(command: String?, quartzFrame: CGRect) -> String {
        let writeText = (command?.isEmpty ?? true)
            ? ""
            : "tell current session of current window to write text \"\(appleScriptEscaped(command!))\"\n"
        return """
        tell application id "com.googlecode.iterm2"
            create window with default profile
            \(writeText)set bounds of current window to \(cocoaBoundsTuple(quartzFrame: quartzFrame))
            return id of current window
        end tell
        """
    }

    // MARK: 通用

    /// POSIX 单引号包裹（内部单引号走 `'\''` 惯用法）
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 恢复某个格子的完整 shell 命令行：cwd → 工作目录、sessionID → `claude --resume`、
    /// 否则启动命令。返回原始 shell 串；AppleScript 层逃逸由脚本构建处统一做
    /// （appleScriptEscaped 只动反斜杠/双引号，不碰 shell 单引号，两层不冲突）。
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

    static func isSupported(appBundleID: String) -> Bool {
        appBundleID == "com.apple.Terminal" || appBundleID == "com.googlecode.iterm2"
    }
}
