import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - 标题写入通道层（2026-08-31 从 TitleEditorService.swift 抽出，行为不变）
// 三条标题写入通道：AX 属性写 / AppleScript（Terminal、iTerm2 专属脚本）/ Automation
// 权限弹窗。编排见主文件 applyTitle（三路写 + iTerm2 跳过 TTY 的顺序约束）。

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

    /// 经 AppleScript 写 Terminal/iTerm2 标题；其他 bundleID 直接跳过。
    ///
    /// ## 场景
    /// - applyTitle 三路写之一；NSAppleScript 执行为同步 fork，可阻塞 100-500ms。
    /// - Terminal：设 tab custom title 并关掉 device name/path/size 等干扰显示项；
    ///   成功后附带一次诊断 readback（排查 title 显示项被重置的历史问题遗留）。
    /// - iTerm2：设 session name（session 级名称会覆盖 OSC 序列，编排层据此跳过 TTY 写
    ///   避免闪烁）。
    /// - 定向写入（2026-09-07 v2）：targetTTY（弹框前捕获的会话 tty）为两终端统一的
    ///   寻址键——tab/session 的 tty 是唯一稳定身份。**禁止用 AppleScript window id 或
    ///   current window 定位**：window id 与 CGWindowNumber 不同源（真机实测 5576 vs
    ///   5584），current window 在弹框后会被焦点切换污染（用户实测「设置名字」落空）。
    ///   targetTTY 为 nil 时回退 front window 旧语义（capture 失败的保守路径，日志可见）。
    /// - Automation 权限被拒（error -1743）时弹系统设置引导（showAutomationPermissionAlert）。
    func applyViaAppleScript(_ title: String, bundleID: String, targetTTY: String? = nil) -> Bool {
        // P-INST-48: AppleScript title 写入耗时（NSAppleScript fork，可阻塞 100-500ms；Terminal 还有 diagnostic readback 二次 fork；applyTitle P-INST-40 总耗时无法区分哪一路，此埋点归因 AppleScript 路）。
        let appleScriptStart = Date()
        var scriptOutcome = "default_skip"
        defer {
            log("[TitleEditorService] applyViaAppleScript finished", level: .debug, fields: [
                "bundleID": bundleID,
                "outcome": scriptOutcome,
                "durationMs": String(elapsedMilliseconds(since: appleScriptStart))
            ])
        }
        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            let escaped = Self.escapingAppleScriptString(title)
            if let tty = targetTTY {
                script = """
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
                script = """
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
            let escaped = Self.escapingAppleScriptString(title)
            if let tty = targetTTY {
                script = """
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
                script = "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
            }
        default:
            scriptOutcome = "unsupported_bundle"
            return false
        }

        log(
            "[TitleEditorService] applyViaAppleScript: setting title",
            fields: ["bundleID": bundleID, "title": truncateForLog(title, limit: 60)]
        )

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)

        // 定向路径：脚本返回 "matched"/"not_found" 区分命中——repeat 走完没命中在
        // AppleScript 层不算错误，必须显式识别为失败，否则会重演
        // 「success 但没落进窗口」（2026-09-07 用户实测「设置名字」落空）。
        if targetTTY != nil {
            let verdict = result?.stringValue
            if verdict != "matched" {
                scriptOutcome = "tty_session_not_found"
                log(
                    "[TitleEditorService] applyViaAppleScript: targeted session not found by tty",
                    level: .warn,
                    fields: ["bundleID": bundleID, "verdict": verdict ?? "nil"]
                )
                return false
            }
        }

        if let error {
            let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[TitleEditorService] applyViaAppleScript: FAILED",
                level: .warn,
                fields: ["errorMsg": errorMsg, "errorNum": String(errorNum)]
            )
            scriptOutcome = "error_\(errorNum)"
            if errorNum == -1743 {
                showAutomationPermissionAlert(bundleID: bundleID)
            }
            return false
        }

        scriptOutcome = "success"
        log("[TitleEditorService] applyViaAppleScript: success")

        // Diagnostic: read back Terminal.app title state after setting（best-effort，跟随 tty 定向目标）
        if bundleID == "com.apple.Terminal" {
            let diagScript: String
            if let tty = targetTTY {
                diagScript = """
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
                diagScript = """
                    tell application "Terminal"
                        set s to current settings of front window
                        return (custom title of selected tab of front window) & "|" & (title displays custom title of s)
                    end tell
                    """
            }
            let diagAS = NSAppleScript(source: diagScript)
            var diagErr: NSDictionary?
            if let result = diagAS?.executeAndReturnError(&diagErr), let desc = result.stringValue {
                let parts = desc.components(separatedBy: "|")
                log(
                    "[TitleEditorService] applyViaAppleScript: diagnostic readback",
                    fields: [
                        "customTitle": parts.count > 0 ? parts[0] : "?",
                        "customTitleEnabled": parts.count > 1 ? parts[1] : "?"
                    ]
                )
            }
        }

        return true
    }

    /// 弹框前捕获 iTerm2 焦点会话的 tty（定向写入的寻址键）。
    ///
    /// ## 场景
    /// - 仅 editTitle 弹框前调用——此刻终端仍在前台持焦，`current window` 语义与用户
    ///   所见一致；弹框后再取即被 VibeFocus 污染。
    /// - 失败返回 nil（调用方回退 front window 旧语义，日志可见）。
    static func captureCurrentSessionTTY() -> String? {
        let script = "tell application \"iTerm2\" to get tty of current session of current window"
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if let error {
            log(
                "[TitleEditorService] captureCurrentSessionTTY: FAILED",
                level: .warn,
                fields: ["errorNum": String(error[NSAppleScript.errorNumber] as? Int ?? -1)]
            )
            return nil
        }
        guard let tty = result?.stringValue, !tty.isEmpty else { return nil }
        log("[TitleEditorService] captureCurrentSessionTTY", fields: ["tty": tty])
        return tty
    }

    /// 弹框前捕获 Terminal 前窗选中 tab 的 tty（定向写入的寻址键）。
    ///
    /// ## 场景
    /// - 仅 editTitle 弹框前调用——此刻终端仍在前台持焦，`front window` 语义与用户
    ///   所见一致；弹框后再取即被 VibeFocus 污染。
    /// - **不要改回 AppleScript window id 定位**：它与 CGWindowNumber 不同源
    ///   （真机实测 AppleScript 5576 vs CG 5584），且只在窗口关闭前后漂移，无交叉校验价值。
    /// - 失败返回 nil（调用方回退 front window 旧语义，日志可见）。
    static func captureTerminalFrontTabTTY() -> String? {
        let script = "tell application \"Terminal\" to get tty of selected tab of front window"
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if let error {
            log(
                "[TitleEditorService] captureTerminalFrontTabTTY: FAILED",
                level: .warn,
                fields: ["errorNum": String(error[NSAppleScript.errorNumber] as? Int ?? -1)]
            )
            return nil
        }
        guard let tty = result?.stringValue, !tty.isEmpty else {
            log("[TitleEditorService] captureTerminalFrontTabTTY: empty tty", level: .warn)
            return nil
        }
        log("[TitleEditorService] captureTerminalFrontTabTTY", fields: ["tty": tty])
        return tty
    }

    /// 经 AX kAXTitleAttribute 写标题（所有支持 AX title 的终端通用）。
    func applyViaAX(_ title: String, to window: AXUIElement) -> Bool {
        // P-INST-48: AX title 写入耗时（isAttributeSettable + AXUIElementSetAttributeValue；applyTitle P-INST-40 总耗时归因 AX 路）。
        let axTitleStart = Date()
        var axOutcome = "unknown"
        defer {
            log("[TitleEditorService] applyViaAX finished", level: .debug, fields: [
                "outcome": axOutcome,
                "durationMs": String(elapsedMilliseconds(since: axTitleStart))
            ])
        }
        guard WindowManager.shared.isAttributeSettable(window, attribute: kAXTitleAttribute as String) else {
            axOutcome = "not_settable"
            log(
                "[TitleEditorService] applyViaAX: kAXTitleAttribute not settable",
                level: .debug
            )
            return false
        }

        let result = AXUIElementSetAttributeValue(window, kAXTitleAttribute as CFString, title as CFTypeRef)
        let success = result == .success
        if !success {
            axOutcome = "set_failed_\(result.rawValue)"
            log(
                "[TitleEditorService] applyViaAX: AXUIElementSetAttributeValue failed",
                level: .warn,
                fields: ["axStatus": String(result.rawValue)]
            )
        } else {
            axOutcome = "success"
        }
        return success
    }

    /// Automation 权限缺失引导弹窗（error -1743 时由 applyViaAppleScript 触发）。
    ///
    /// ## 场景
    /// - applyViaAppleScript 检测到 -1743 调用；调用链（editTitle/autoSetTitle → applyTitle →
    ///   applyViaAppleScript → 本方法）全程在主线程上下文，直接同步 runModal。
    /// - 历史教训：曾包 DispatchQueue.main.async —— 在 GCD main queue drain 点开模态
    ///   会导致弹窗静默不显示（2026-08-31 实测复现后修复）。
    /// - 每次进程生命周期只弹一次（hasShownAutomationPermissionAlert），避免用户
    ///   未授权期间每次改名都被弹窗打断。
    private func showAutomationPermissionAlert(bundleID: String) {
        // P-INST-192: Automation 权限弹窗耗时（NSAlert.runModal 模态阻塞主线程 + 用户确认后 NSWorkspace.shared.open 启动 System Settings；applyTitle 检测到 Automation 权限缺失调用，runModal 阻塞直到用户操作）。
        #if PERF_INSTRUMENT
        let sapaStart = Date()
        #endif
        guard !hasShownAutomationPermissionAlert else {
            log("[TitleEditorService] Automation permission alert already shown this session, skipping", level: .debug)
            return
        }
        hasShownAutomationPermissionAlert = true

        let terminalName: String
        switch bundleID {
        case "com.googlecode.iterm2": terminalName = "iTerm2"
        case "com.apple.Terminal": terminalName = "Terminal"
        default: terminalName = "terminal"
        }

        log("[TitleEditorService] showing Automation permission alert", fields: ["bundleID": bundleID])

        let alert = NSAlert()
        alert.messageText = "需要 Automation 权限"
        alert.informativeText = "VibeFocus 需要授权才能修改 \(terminalName) 的窗口标题。\n\n请前往：系统设置 → 隐私与安全性 → Automation → 勾选 VibeFocus 对 \(terminalName) 的控制权限。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        alert.window.level = .floating

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
        #if PERF_INSTRUMENT
        let durMs = elapsedMilliseconds(since: sapaStart)
        if durMs >= 50 { log("[TitleEditor] showAutomationPermissionAlert slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        #endif
    }
}
