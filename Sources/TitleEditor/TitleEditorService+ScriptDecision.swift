import Foundation

// MARK: - 标题写入脚本决策层（纯函数，编排见 +Channels.swift）
// 提取自 applyViaAppleScript 内联模板（2026-09-07，行为不变）：AppleScript 模板构造、
// 定向 verdict 哨兵判定、Terminal 诊断回读模板均为纯字符串决策，与 NSAppleScript 执行
// 分离。模板内嵌真实回归史（tty 寻址铁律/verdict 哨兵/转义），Tests/Standalone/
// 四分支模板与全部铁律不变量由 Runner 真身直测锁定（makeTitleScript/isMatchedVerdict
// 等：RunnerPureSweepBTests/RunnerHookWalkTests；B112 镜像退役）。

@MainActor
extension TitleEditorService {

    /// AppleScript 字符串字面量转义（反斜杠与双引号）。
    ///
    /// ## 样例
    /// ```
    /// `my \proj "x"` → `my \\proj \"x\"`
    /// ```
    static func escapingAppleScriptString(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 标题写入 AppleScript 模板决策表（纯函数）。
    /// - Returns: bundleID 支持时返回可执行脚本；不支持返回 nil（调用方按 unsupported_bundle 结局）。
    ///
    /// ## 模板契约（回归史，改动需过真机 TITLE_E2E）
    /// - 定向寻址只用 tty（tab/session 的 tty 是唯一稳定身份）；**禁止 window id /
    ///   current window 定向**（window id 与 CGWindowNumber 不同源，current window
    ///   会被弹框焦点污染）。
    /// - 定向模板以 return "matched" / "not_found" 哨兵收尾——repeat 未命中在
    ///   AppleScript 层不算错误，必须由 verdict 判定（isMatchedVerdict）。
    /// - targetTTY=nil 回退 front 语义（capture 失败的保守路径）。
    /// - Terminal 额外关掉 device name/path/size 等干扰显示项；iTerm2 设 session name。
    static func makeTitleScript(bundleID: String, title: String, targetTTY: String?) -> String? {
        let escaped = escapingAppleScriptString(title)
        switch bundleID {
        case "com.apple.Terminal":
            if let tty = targetTTY {
                return """
                    tell application "Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t = "\(tty)" then
                                    set custom title of t to "\(escaped)"
                                    tell current settings of w
                                        set title displays custom title to true
                                        set title displays device name to false
                                        set title displays shell path to false
                                        set title displays window size to false
                                        set title displays settings name to false
                                    end tell
                                    return "matched"
                                end if
                            end repeat
                        end repeat
                        return "not_found"
                    end tell
                    """
            } else {
                return """
                    tell application "Terminal"
                        set custom title of selected tab of front window to "\(escaped)"
                        tell current settings of front window
                            set title displays custom title to true
                            set title displays device name to false
                            set title displays shell path to false
                            set title displays window size to false
                            set title displays settings name to false
                        end tell
                    end tell
                    """
            }
        case "com.googlecode.iterm2":
            if let tty = targetTTY {
                return """
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s = "\(tty)" then
                                        set name of s to "\(escaped)"
                                        return "matched"
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "not_found"
                    end tell
                    """
            } else {
                return "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
            }
        default:
            return nil
        }
    }

    /// 定向写入 verdict 判定（纯函数）：只有 "matched" 算命中——repeat 走完没命中在
    /// AppleScript 层不算错误，必须显式识别为失败，否则会重演
    /// 「success 但没落进窗口」（2026-09-07 用户实测「设置名字」落空）。
    static func isMatchedVerdict(_ verdict: String?) -> Bool {
        verdict == "matched"
    }

    /// Terminal 诊断回读脚本模板（纯函数，best-effort，跟随 tty 定向目标）。
    /// 返回 `custom title "|" + title displays custom title` 供日志排查显示项被重置。
    static func makeTerminalDiagnosticScript(targetTTY: String?) -> String {
        if let tty = targetTTY {
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t = "\(tty)" then
                                set s to current settings of w
                                return (custom title of t) & "|" & (title displays custom title of s)
                            end if
                        end repeat
                    end repeat
                    return "target_gone"
                end tell
                """
        } else {
            return """
                tell application "Terminal"
                    set s to current settings of front window
                    return (custom title of selected tab of front window) & "|" & (title displays custom title of s)
                end tell
                """
        }
    }
}
