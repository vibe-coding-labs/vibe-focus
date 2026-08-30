import AppKit
import Foundation

// MARK: - 崩溃诊断运行时快照层（2026-08-31 从 CrashContext.swift 拆分，行为不变）
// 崩溃诊断体系三层之三（全景见 CrashSignalHandler.swift 文件头）：
// toggle / hook 双热路径入口每次调用，把进程关键状态刷进 CrashSnapshotBuffer——
// 崩溃时信号层把这份快照随 FATAL SIGNAL 一起落盘，是 PRE-CRASH STATE 的数据来源。

@MainActor
func updateCrashSnapshotFromRuntime() {
    // P-INST-117: 运行时崩溃快照更新耗时（NSWorkspace.frontmostApplication + NSScreen.screens.count + WindowManager/HotKeyManager 状态读取 + 写入 crash snapshot buffer；toggle 入口 WindowManager+Toggle:32 + hook 请求 ClaudeHookServer:137 双热路径调用，每次 toggle/hook 都执行）。
    let ucsrStart = Date()
    defer {
        log("CrashContext.updateCrashSnapshotFromRuntime finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: ucsrStart))
        ])
    }
    updateCrashSnapshot { buf, capacity in
        var pos = 0
        func append(_ str: String) {
            str.withCString { ptr in
                var i = 0
                while ptr[i] != 0 && pos < capacity - 1 {
                    buf[pos] = ptr[i]
                    pos += 1
                    i += 1
                }
            }
        }
        func appendField(_ key: String, _ value: String) {
            append("\(key)=\(value) ")
        }

        append("pid=\(ProcessInfo.processInfo.processIdentifier)")
        append(" ppid=\(getppid())")

        // 用 HotKeyManager 缓存的 accessibilityGranted 代替同步 AXIsProcessTrustedWithOptions。
        // 后者是同步权限服务查询，WindowServer 繁忙时可达数百 ms，每次 toggle 调用会阻塞入口。
        // AX 权限状态运行期间不变，缓存值足够用于 crash 诊断。
        let hkm = HotKeyManager.shared
        appendField("axTrusted", String(hkm.accessibilityGranted))

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            appendField("frontPID", String(frontApp.processIdentifier))
            appendField("frontBundleID", frontApp.bundleIdentifier ?? "nil")
        }

        appendField("screenCount", String(NSScreen.screens.count))

        let wm = WindowManager.shared

        appendField("hotkey", hkm.currentHotKey.displayString)
        appendField("axGranted", String(hkm.accessibilityGranted))

        let hookServer = ClaudeHookServer.shared
        appendField("hookRunning", String(hookServer.isRunning))

        appendField("eventCount", "0")

        buf[pos] = 0
        return pos
    }
}

@MainActor
func logRuntimeStateSnapshot(context: String) {
    // P-INST-118: 运行时状态快照日志耗时（WindowManager/HotKeyManager/ClaudeHookServer 状态读取 + 字段字典构造 + log 写；toggle 入口 WindowManager+Toggle:33 + hook 请求 ClaudeHookServer:138 双热路径调用，每次 toggle/hook 都执行）。
    let lrssStart = Date()
    defer {
        log("CrashContext.logRuntimeStateSnapshot finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: lrssStart)),
            "context": context
        ])
    }
    let wm = WindowManager.shared
    let hkm = HotKeyManager.shared
    let hookServer = ClaudeHookServer.shared

    var fields: [String: String] = [
        "context": context,
        "hotkey": hkm.currentHotKey.displayString,
        "axGranted": String(hkm.accessibilityGranted),
        "hookRunning": String(hookServer.isRunning),
        "screenCount": String(NSScreen.screens.count),
        "frontmost": frontmostAppDescriptor()
    ]

    log("[STATE_SNAPSHOT] \(context)", level: .debug, fields: fields)
}
