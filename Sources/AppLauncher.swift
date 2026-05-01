import Foundation
import AppKit
import Combine

@MainActor
final class AppLauncher: ObservableObject {
    static let shared = AppLauncher()

    @Published private(set) var currentPhase: LaunchPhase = .initializing
    @Published private(set) var phaseResults: [LaunchPhaseResult] = []
    @Published private(set) var isLaunching = false
    @Published private(set) var launchError: LaunchError?
    @Published private(set) var healthResults: [LaunchHealthChecker.HealthCheckResult] = []

    var overallProgress: Double {
        currentPhase.progress
    }

    var canProceed: Bool {
        launchError == nil && !LaunchHealthChecker.shared.hasCriticalIssues(healthResults)
    }

    private init() {}

    func launch() async {
        log("AppLauncher.launch() entered", level: .debug, fields: ["isLaunching": String(isLaunching)])
        guard !isLaunching else {
            log("AppLauncher.launch() early return: already launching", level: .debug)
            return
        }
        isLaunching = true
        launchError = nil
        phaseResults.removeAll()

        log("=== VibeFocus 启动序列开始 ===")

        // 执行健康检查
        await executePhase(.checkingPermissions) {
            let results = await LaunchHealthChecker.shared.performFullCheck()
            self.healthResults = results
            return (true, "检查完成: \(results.filter { $0.isHealthy }.count)/\(results.count) 通过", nil)
        }

        // 检查单实例
        await executePhase(.checkingSingleInstance) {
            if let existing = self.findExistingInstance() {
                let currentVersion = self.currentAppVersion()

                if existing.version == nil || existing.version == currentVersion {
                    self.requestExistingInstanceOpenSettings()
                    existing.app.activate(options: [.activateAllWindows])
                    return (false, "同版本实例已在运行", .anotherInstanceRunning)
                }

                existing.app.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if !self.acquireExclusiveLock() {
                return (false, "无法获取独占锁", .anotherInstanceRunning)
            }

            return (true, "单实例检查通过", nil)
        }

        // 检查安装位置
        await executePhase(.checkingInstallation) {
            let actualPath = Bundle.main.bundleURL.path
            let expectedPaths = [
                NSHomeDirectory() + "/Applications/VibeFocus.app",
                "/Applications/VibeFocus.app"
            ]

            if expectedPaths.contains(actualPath) || actualPath.hasSuffix("/dist/VibeFocus.app") {
                return (true, "安装位置正确", nil)
            }

            return (false, "安装位置异常: \(actualPath)", .invalidInstallationLocation)
        }

        // 加载配置
        await executePhase(.loadingConfiguration) {
            HotKeyManager.shared.refreshAccessibilityStatus()
            return (true, "配置加载完成", nil)
        }

        // 设置热键
        await executePhase(.settingUpHotkeys) {
            HotKeyManager.shared.setup()
            return (true, "热键设置完成", nil)
        }

        // 设置菜单栏
        await executePhase(.settingUpMenuBar) {
            // 由 AppDelegate 处理
            return (true, "菜单栏设置完成", nil)
        }

        // 启动服务
        await executePhase(.startingServices) {
            ScreenOverlayManager.shared.refreshOverlays()
            ClaudeHookServer.shared.applyPreferences()
            return (true, "服务启动完成", nil)
        }

        // 完成
        if launchError == nil {
            currentPhase = .completed
            log("=== VibeFocus 启动成功 ===")
        } else {
            currentPhase = .failed
            log("=== VibeFocus 启动失败 ===")
        }

        log("AppLauncher.launch() completed", level: .debug, fields: [
            "currentPhase": currentPhase.rawValue,
            "hasError": String(launchError != nil),
            "phaseResults": String(phaseResults.count)
        ])
        isLaunching = false
    }

    private func executePhase(
        _ phase: LaunchPhase,
        action: () async -> (success: Bool, message: String, error: LaunchError?)
    ) async {
        log("AppLauncher.executePhase() entered", level: .debug, fields: ["phase": phase.rawValue])
        currentPhase = phase
        let startTime = Date()

        let (success, message, error) = await action()
        let duration = Date().timeIntervalSince(startTime)

        let result = LaunchPhaseResult(
            phase: phase,
            success: success,
            message: message,
            error: error,
            duration: duration
        )

        phaseResults.append(result)

        if !success && error != nil {
            launchError = error
        }

        log("[Launch] \(phase.rawValue): \(success ? "✓" : "✗") \(message) (\(String(format: "%.3f", duration))s)")
    }

    func reset() {
        log("AppLauncher.reset() entered", level: .debug, fields: [
            "currentPhase": currentPhase.rawValue,
            "phaseResults": String(phaseResults.count),
            "isLaunching": String(isLaunching)
        ])
        currentPhase = .initializing
        phaseResults.removeAll()
        isLaunching = false
        launchError = nil
        healthResults.removeAll()
        log("AppLauncher.reset() completed", level: .debug)
    }

    // MARK: - Helpers

    private func findExistingInstance() -> (app: NSRunningApplication, version: String?)? {
        log("AppLauncher.findExistingInstance() entered", level: .debug)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        if let bundleID = bundleID {
            for app in NSWorkspace.shared.runningApplications {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    let version = installedVersion(for: app)
                    log("AppLauncher.findExistingInstance() found existing instance", level: .debug, fields: [
                        "pid": String(app.processIdentifier),
                        "version": version ?? "unknown"
                    ])
                    return (app, version)
                }
            }
        }

        log("AppLauncher.findExistingInstance() no existing instance found", level: .debug)
        return nil
    }

    private func installedVersion(for app: NSRunningApplication) -> String? {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppVersion.current
    }

    private let lockFilePath = "/tmp/VibeFocusHotkeys.lock"

    private func acquireExclusiveLock() -> Bool {
        log("AppLauncher.acquireExclusiveLock() entered", level: .debug, fields: ["lockFilePath": lockFilePath])
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            log("AppLauncher.acquireExclusiveLock() failed to open lock file", level: .debug, fields: ["fd": "-1"])
            return false
        }
        let result = flock(fd, LOCK_EX | LOCK_NB) != -1
        log("AppLauncher.acquireExclusiveLock() result", level: .debug, fields: ["acquired": String(result)])
        return result
    }

    private let openSettingsNotification = Notification.Name("com.openai.vibe-focus.open-settings")

    private func requestExistingInstanceOpenSettings() {
        log("AppLauncher.requestExistingInstanceOpenSettings() posting notification", level: .debug, fields: [
            "notification": openSettingsNotification.rawValue
        ])
        DistributedNotificationCenter.default().post(
            name: openSettingsNotification,
            object: nil
        )
    }
}
