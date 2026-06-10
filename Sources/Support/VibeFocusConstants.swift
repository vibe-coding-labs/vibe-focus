// VibeFocusConstants.swift
// VibeFocus — 全局常量集中管理
// 所有硬编码值统一在此定义，禁止在业务代码中出现 magic number

import Foundation

/// VibeFocus 全局常量
enum VFConstants {

    // MARK: - Hook Server

    /// Hook HTTP 服务器默认端口
    static let defaultHookServerPort: UInt16 = 39277

    /// 有效端口范围下限
    static let minValidPort: UInt16 = 1024

    /// 有效端口范围上限
    static let maxValidPort: UInt16 = 65535

    // MARK: - File Paths

    /// 配置目录名（相对于 $HOME）
    static let configDirName = ".vibefocus"

    /// 应用锁文件路径（防止多实例）
    static let appLockFilePath = "/tmp/VibeFocus.lock"

    /// 崩溃快照日志路径
    static let crashSnapshotLogPath = "/tmp/vibefocus-crash-snapshot.log"

    /// 崩溃上下文 JSON 状态文件
    static let crashContextStatePath = "/tmp/vibefocus-crash-context.json"

    /// 普通日志文件路径
    static let plainLogFilePath = "/tmp/vibefocus.log"

    /// 结构化日志文件路径
    static let structuredLogFilePath = "/tmp/vibefocus-events.jsonl"

    /// 崩溃尾部普通日志
    static let plainCrashTailPath = "/tmp/vibefocus-crash-tail.log"

    /// 崩溃尾部结构化日志
    static let structuredCrashTailPath = "/tmp/vibefocus-crash-tail-events.jsonl"

    /// Claude settings 相对路径
    static let claudeSettingsRelativePath = ".claude/settings.json"

    // MARK: - File Permissions

    /// 文件权限：读写（644）
    static let filePermissionReadWrite: mode_t = 0o644

    /// 文件权限：可执行（755）
    static let filePermissionExecutable: mode_t = 0o755

    // MARK: - Time Constants (seconds)

    /// 已完成绑定保留时间：4 小时
    static let completedRetentionSeconds: TimeInterval = 4 * 60 * 60

    /// 活跃绑定保留时间：24 小时
    static let activeRetentionSeconds: TimeInterval = 24 * 60 * 60

    /// 绑定最大有效年龄：30 分钟
    static let bindingMaxAgeSeconds: TimeInterval = 1800

    // MARK: - Buffer & Size Limits

    /// 崩溃快照缓冲区大小
    static let crashSnapshotBufferSize = 16384

    /// 日志文件最大大小：25MB
    static let maxLogSizeBytes: UInt64 = 25 * 1024 * 1024

    /// 结构化日志尾部行数限制
    static let structuredLogLineLimit = 1200
}
