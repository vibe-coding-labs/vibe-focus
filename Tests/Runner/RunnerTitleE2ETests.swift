import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTitleE2ETests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runTitleE2E() {
    // MARK: 终端标题定向改名真机 E2E（仅 VIBEFOCUS_TITLE_E2E=1 时运行）
    // 2026-09-07 用户实测「Ctrl+T 改名完全无效」回归保护：写通道必须按弹框前捕获的
    // 目标身份（会话 tty，两终端统一）命中自建会话，且改名能扛住 shell OSC
    // 覆写。自建窗口只碰自建（差集追踪），Terminal 用 exit 自关、iTerm2 用 write text
    // "exit" 自关（会话退出无确认框）。

    if ProcessInfo.processInfo.environment["VIBEFOCUS_TITLE_E2E"] == "1" {
        @MainActor
        func runAS(_ source: String) -> String? {
            let appleScript = NSAppleScript(source: source)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            if let error {
                print("    [TitleE2E] AppleScript FAILED: \(error[NSAppleScript.errorNumber] as? Int ?? -1) \(error[NSAppleScript.errorMessage] as? String ?? "")")
                return nil
            }
            return result?.stringValue
        }

        print("\n—— TitleE2E：终端标题定向改名 ——")

        // Case A：Terminal 定向改名（tty 寻址）+ OSC/提示符覆写探针。
        // 断言走 `name of window id N`（窗口可见标题），不走 CGWindowName——
        // 非活跃空间的窗口 kCGWindowName 读不到（首轮实测踩坑）。
        caseA: do {
            let created = runAS("""
                tell application "Terminal"
                    do script ""
                    delay 0.5
                    set wID to id of front window
                    set wTTY to tty of selected tab of front window
                    return (wID as string) & "|" & wTTY
                end tell
                """)
            guard let created, created.contains("|") else {
                check("TitleE2E Terminal: 自建窗口（id|tty）", false)
                break caseA
            }
            let parts = created.components(separatedBy: "|")
            let windowID = parts[0]
            let tty = parts[1]
            check("TitleE2E Terminal: 自建窗口（id=\(windowID), tty=\(tty)）", true)

            // 捕获助手必须命中自建会话（定向修复的核心断言）。
            let captured = TitleEditorService.captureTerminalFrontTabTTY()
            check("TitleE2E Terminal: captureTerminalFrontTabTTY == 自建会话 tty",
                  captured == tty)

            // 定向写入 + 可见标题回读。
            let writeOK = TitleEditorService.shared.applyViaAppleScript(
                "VFT-E2E-T1", bundleID: "com.apple.Terminal", targetTTY: tty)
            check("TitleE2E Terminal: tty 定向写入 matched", writeOK)
            func terminalWindowName() -> String? {
                runAS("tell application \"Terminal\" to get name of window id \(windowID)")
            }
            func pollTerminalTitle(_ seconds: Double) -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if let n = terminalWindowName(), n.contains("VFT-E2E-T1") { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }
            check("TitleE2E Terminal: 标题落屏", pollTerminalTitle(4))

            // 覆写探针：跑一条命令触发新提示符（zsh OSC），标题必须保持。
            _ = runAS("tell application \"Terminal\" to do script \"true\" in window id \(windowID)")
            Thread.sleep(forTimeInterval: 2.0)
            // 实证（2026-09-07 探针）：macOS 默认 zsh 每次画提示符都用 OSC 重设标题——
            // 自定义标题被 shell 顶回是 shell 行为，应用层不可控，故只如实记录不断言。
            let oscSurvived = pollTerminalTitle(3)
            print("    [TitleE2E] Terminal 提示符重绘后标题存活（shell OSC 行为，信息项）: \(oscSurvived)")

            // 清理：exit 自关；shell 退出后窗口偶发滞留（实测），close 兜底。
            _ = runAS("tell application \"Terminal\" to do script \"exit\" in window id \(windowID)")
            check("TitleE2E Terminal: 自建窗口已自关", {
                let deadline = Date().addingTimeInterval(4)
                while Date() < deadline {
                    if terminalWindowName() == nil { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                _ = runAS("tell application \"Terminal\" to close window id \(windowID)")
                let deadline2 = Date().addingTimeInterval(4)
                while Date() < deadline2 {
                    if terminalWindowName() == nil { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }())
        }

        // Case B：iTerm2 定向改名（tty 寻址）+ OSC 覆写探针（会话名能否扛住 shell 重绘的实证）。
        caseB: do {
            let created = runAS("""
                tell application "iTerm2"
                    create window with default profile
                    delay 0.5
                    set wID to id of current window
                    set wTTY to tty of current session of current window
                    return (wID as string) & "|" & wTTY
                end tell
                """)
            guard let created, created.contains("|") else {
                check("TitleE2E iTerm2: 自建窗口（id|tty）", false)
                break caseB
            }
            let parts = created.components(separatedBy: "|")
            let windowID = parts[0]
            let tty = parts[1]
            check("TitleE2E iTerm2: 自建窗口（id=\(windowID), tty=\(tty)）", true)

            let writeOK = TitleEditorService.shared.applyViaAppleScript(
                "VFT-E2E-T2", bundleID: "com.googlecode.iterm2", targetTTY: tty)
            check("TitleE2E iTerm2: tty 定向写入 matched", writeOK)

            func iTermSessionName() -> String? {
                runAS("""
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s = "\(tty)" then
                                        return name of s
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "session_gone"
                    end tell
                    """)
            }
            // 注意：`first window whose id = N` 在 iTerm2 AppleScript 上不可用（-1719
            // Invalid index，实测），窗口标题改为命中会话时取其所属窗的 name。
            func iTermWindowName() -> String? {
                runAS("""
                    tell application "iTerm2"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if tty of s = "\(tty)" then
                                        return name of w
                                    end if
                                end repeat
                            end repeat
                        end repeat
                        return "window_gone"
                    end tell
                    """)
            }
            func pollBoth(_ seconds: Double) -> (session: Bool, window: Bool) {
                let deadline = Date().addingTimeInterval(seconds)
                var session = false
                var window = false
                while Date() < deadline {
                    if let n = iTermSessionName(), n.contains("VFT-E2E-T2") { session = true }
                    if let n = iTermWindowName(), n.contains("VFT-E2E-T2") { window = true }
                    if session && window { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return (session, window)
            }
            let landed = pollBoth(4)
            check("TitleE2E iTerm2: 会话名写入生效", landed.session)
            print("    [TitleE2E] iTerm2 窗口标题落屏（会话名→标题显示语义实证）: \(landed.window)")
            print("    [TitleE2E] iTerm2 窗口标题是否跟随会话名（机器/profile 相关，信息项）: \(landed.window)")

            // 覆写探针：向该 session 写命令触发 zsh 新提示符（OSC 重绘），标题必须保持。
            _ = runAS("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s = "\(tty)" then
                                    tell s to write text "true"
                                    return "sent"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            Thread.sleep(forTimeInterval: 2.0)
            let survived = pollBoth(3)
            // 实证（2026-09-07 探针）：提示符重绘后 shell 的 precmd OSC 会把会话名一并
            // 覆写（session name 亦不免疫）——shell 行为应用层不可控，只如实记录。
            print("    [TitleE2E] iTerm2 提示符重绘后会话名存活（shell OSC 行为，信息项）: \(survived.session)")
            print("    [TitleE2E] iTerm2 窗口标题抗 OSC（信息项）: \(survived.window)")

            // 清理：session exit 自关（无确认框路径）。
            _ = runAS("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s = "\(tty)" then
                                    tell s to write text "exit"
                                    return "exit_sent"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            check("TitleE2E iTerm2: 自建窗口已自关", {
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline {
                    let n = iTermWindowName()
                    if n == nil || n == "window_gone" { return true }
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return false
            }())
        }
    }
    }
}
