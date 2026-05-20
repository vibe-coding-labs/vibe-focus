import AppKit
import Foundation

/// 终端应用名单一事实来源 — 委托到 TerminalRegistry
/// 保留此类型以保持向后兼容，新代码应直接使用 TerminalRegistry
enum TerminalAppRegistry {
    static var appNames: Set<String> { TerminalRegistry.terminalAppNames }
    static var bundleIDs: Set<String> { TerminalRegistry.terminalBundleIDs }

    static func isTerminalPID(_ pid: Int32) -> Bool {
        TerminalRegistry.isTerminalPID(pid)
    }

    static func findTerminalPID(from startPID: Int32) -> Int32? {
        TerminalRegistry.findTerminalPID(from: startPID)
    }
}
