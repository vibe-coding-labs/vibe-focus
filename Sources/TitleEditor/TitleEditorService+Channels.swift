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
    /// - iTerm2：设 current session name（session 级名称会覆盖 OSC 序列，
    ///   编排层据此跳过 TTY 写避免闪烁）。
    /// - Automation 权限被拒（error -1743）时弹系统设置引导（showAutomationPermissionAlert）。
    func applyViaAppleScript(_ title: String, bundleID: String) -> Bool {
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
        case "com.googlecode.iterm2":
            let escaped = Self.escapingAppleScriptString(title)
            script = "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
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
        appleScript?.executeAndReturnError(&error)

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

        // Diagnostic: read back Terminal.app title state after setting
        if bundleID == "com.apple.Terminal" {
            let diagScript = """
                tell application "Terminal"
                    set ct to custom title of selected tab of front window
                    set s to current settings of front window
                    set ws to title displays window size of s
                    set dvc to title displays device name of s
                    set c to title displays custom title of s
                    return ct & "|" & ws & "|" & dvc & "|" & c
                end tell
                """
            let diagAS = NSAppleScript(source: diagScript)
            var diagErr: NSDictionary?
            if let result = diagAS?.executeAndReturnError(&diagErr), let desc = result.stringValue {
                let parts = desc.components(separatedBy: "|")
                log(
                    "[TitleEditorService] applyViaAppleScript: diagnostic readback",
                    fields: [
                        "customTitle": parts.count > 0 ? parts[0] : "?",
                        "windowSizeEnabled": parts.count > 1 ? parts[1] : "?",
                        "deviceNameEnabled": parts.count > 2 ? parts[2] : "?",
                        "customTitleEnabled": parts.count > 3 ? parts[3] : "?"
                    ]
                )
            }
        }

        return true
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
    /// NSAlert.runModal 模态阻塞主线程直到用户操作，仅在权限真正缺失时进入。
    private func showAutomationPermissionAlert(bundleID: String) {
        // P-INST-192: Automation 权限弹窗耗时（NSAlert.runModal 模态阻塞主线程 + 用户确认后 NSWorkspace.shared.open 启动 System Settings；applyTitle 检测到 Automation 权限缺失调用，runModal 阻塞直到用户操作）。
        let sapaStart = Date()
        let terminalName: String
        switch bundleID {
        case "com.googlecode.iterm2": terminalName = "iTerm2"
        case "com.apple.Terminal": terminalName = "Terminal"
        default: terminalName = "terminal"
        }

        DispatchQueue.main.async {
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
            let durMs = elapsedMilliseconds(since: sapaStart)
            if durMs >= 50 { log("[TitleEditor] showAutomationPermissionAlert slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
    }
}
