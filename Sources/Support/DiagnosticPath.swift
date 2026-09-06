import Foundation

// MARK: - 诊断文件路径角色隔离
//
// 背景（2026-09-06 排查「莫名其妙退出」实证）：/tmp/vibefocus-crash-fatal.log 是机器
// 全局路径，所有 VibeFocus 派生二进制（历史旧构建、各 worktree 的 TestRunner/
// HistoryTests/UnitTestRunner）链接同一份 CrashSignalHandler 都会读写它——
// 2026-07-12 的 SIGSEGV 记录曾以新 mtime 在文件里「复活」，把 keepalive wrapper
// 的崩溃判定搅成误报。教训：/tmp 全局诊断文件 + 多二进制共享 = 取证不可归因。
//
// 规则：仅主应用二进制（VibeFocusHotkeys）使用规范路径（keepalive wrapper 依赖）；
// 其余进程一律落到 <base>-<进程名> 后缀路径，从根上消除跨进程污染。

/// 按进程名派生诊断文件路径：主应用用规范路径，其它进程加 `-{进程名}` 后缀。
func diagnosticFilePath(base: String, processName: String) -> String {
    if processName.isEmpty || processName == "VibeFocusHotkeys" {
        return base
    }
    return "\(base)-\(processName)"
}

/// 本进程应使用的 fatal 记录路径（CrashSignalHandler 与 CrashContextRecorder 共用，
/// 保证「写」与「启动归档读」指向同一文件）。
func diagnosticFatalLogPath() -> String {
    diagnosticFilePath(
        base: "/tmp/vibefocus-crash-fatal.log",
        processName: ProcessInfo.processInfo.processName
    )
}

/// 本进程应使用的崩溃快照路径。
func diagnosticSnapshotLogPath() -> String {
    diagnosticFilePath(
        base: "/tmp/vibefocus-crash-snapshot.log",
        processName: ProcessInfo.processInfo.processName
    )
}
