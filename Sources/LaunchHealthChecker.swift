import Foundation
import AppKit

@MainActor
final class LaunchHealthChecker {
    static let shared = LaunchHealthChecker()

    struct HealthCheckResult {
        let component: String
        let isHealthy: Bool
        let message: String
        let severity: HealthSeverity
    }

    enum HealthSeverity: Int, Comparable {
        case info = 0      // 仅信息，不影响启动
        case warning = 1   // 警告，可以启动但功能受限
        case critical = 2  // 严重，阻止启动

        static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private init() {}

    func performFullCheck() async -> [HealthCheckResult] {
        log("LaunchHealthChecker.performFullCheck() entered", level: .debug)
        var results: [HealthCheckResult] = []

        await withTaskGroup(of: HealthCheckResult.self) { group in
            group.addTask { await self.checkAccessibilityPermission() }
            group.addTask { await self.checkInstallLocation() }
            group.addTask { await self.checkScreenAccess() }
            group.addTask { await self.checkDiskSpace() }
            group.addTask { await self.checkSystemVersion() }

            for await result in group {
                results.append(result)
            }
        }

        let sorted = results.sorted { $0.severity > $1.severity }
        log("LaunchHealthChecker.performFullCheck() completed", level: .debug, fields: [
            "totalChecks": String(sorted.count),
            "healthy": String(sorted.filter(\.isHealthy).count),
            "hasCritical": String(hasCriticalIssues(sorted))
        ])
        return sorted
    }

    nonisolated func checkAccessibilityPermission() async -> HealthCheckResult {
        log("LaunchHealthChecker.checkAccessibilityPermission() entered", level: .debug)
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        log("LaunchHealthChecker.checkAccessibilityPermission() result", level: .debug, fields: [
            "isTrusted": String(isTrusted)
        ])
        return HealthCheckResult(
            component: "辅助功能权限",
            isHealthy: isTrusted,
            message: isTrusted ? "已授权" : "未授权",
            severity: isTrusted ? .info : .warning
        )
    }

    func checkInstallLocation() async -> HealthCheckResult {
        log("LaunchHealthChecker.checkInstallLocation() entered", level: .debug)
        let expectedPaths = [
            NSHomeDirectory() + "/Applications/VibeFocus.app",
            "/Applications/VibeFocus.app"
        ]
        let actualPath = Bundle.main.bundleURL.path

        let isValid = expectedPaths.contains(actualPath) ||
                      actualPath.hasSuffix("/dist/VibeFocus.app")

        log("LaunchHealthChecker.checkInstallLocation() result", level: .debug, fields: [
            "actualPath": actualPath,
            "isValid": String(isValid)
        ])
        return HealthCheckResult(
            component: "安装位置",
            isHealthy: isValid,
            message: isValid ? "位置正确" : "位置异常: \(actualPath)",
            severity: isValid ? .info : .warning
        )
    }

    func checkScreenAccess() async -> HealthCheckResult {
        log("LaunchHealthChecker.checkScreenAccess() entered", level: .debug)
        let hasAccess = CGPreflightScreenCaptureAccess()

        log("LaunchHealthChecker.checkScreenAccess() result", level: .debug, fields: [
            "hasAccess": String(hasAccess)
        ])
        return HealthCheckResult(
            component: "屏幕录制权限",
            isHealthy: hasAccess,
            message: hasAccess ? "已授权" : "未授权（部分功能受限）",
            severity: hasAccess ? .info : .info
        )
    }

    func checkDiskSpace() async -> HealthCheckResult {
        log("LaunchHealthChecker.checkDiskSpace() entered", level: .debug)
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                let mb = capacity / 1_048_576
                let isHealthy = mb > 100
                log("LaunchHealthChecker.checkDiskSpace() result", level: .debug, fields: [
                    "availableMB": String(mb),
                    "isHealthy": String(isHealthy)
                ])
                return HealthCheckResult(
                    component: "磁盘空间",
                    isHealthy: isHealthy,
                    message: "可用: \(mb) MB",
                    severity: isHealthy ? .info : .warning
                )
            }
        } catch {
            log("LaunchHealthChecker.checkDiskSpace() error", level: .debug, fields: [
                "error": error.localizedDescription
            ])
            return HealthCheckResult(
                component: "磁盘空间",
                isHealthy: false,
                message: "无法检测: \(error.localizedDescription)",
                severity: .info
            )
        }

        log("LaunchHealthChecker.checkDiskSpace() capacity unavailable", level: .debug)
        return HealthCheckResult(
            component: "磁盘空间",
            isHealthy: true,
            message: "未知",
            severity: .info
        )
    }

    func checkSystemVersion() async -> HealthCheckResult {
        log("LaunchHealthChecker.checkSystemVersion() entered", level: .debug)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isSupported = version.majorVersion >= 13

        log("LaunchHealthChecker.checkSystemVersion() result", level: .debug, fields: [
            "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "isSupported": String(isSupported)
        ])
        return HealthCheckResult(
            component: "系统版本",
            isHealthy: isSupported,
            message: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            severity: isSupported ? .info : .critical
        )
    }

    func hasCriticalIssues(_ results: [HealthCheckResult]) -> Bool {
        let has = results.contains { $0.severity == .critical && !$0.isHealthy }
        log("LaunchHealthChecker.hasCriticalIssues() evaluated", level: .debug, fields: ["result": String(has)])
        return has
    }

    func hasWarnings(_ results: [HealthCheckResult]) -> Bool {
        let has = results.contains { $0.severity == .warning && !$0.isHealthy }
        log("LaunchHealthChecker.hasWarnings() evaluated", level: .debug, fields: ["result": String(has)])
        return has
    }
}
