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
        guard !isLaunching else { return }
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

        isLaunching = false
    }

    private func executePhase(
        _ phase: LaunchPhase,
        action: () async -> (success: Bool, message: String, error: LaunchError?)
    ) async {
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
        currentPhase = .initializing
        phaseResults.removeAll()
        isLaunching = false
        launchError = nil
        healthResults.removeAll()
    }

    // MARK: - Helpers

    private func findExistingInstance() -> (app: NSRunningApplication, version: String?)? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        if let bundleID = bundleID {
            for app in NSWorkspace.shared.runningApplications {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    return (app, installedVersion(for: app))
                }
            }
        }

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
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else { return false }
        return flock(fd, LOCK_EX | LOCK_NB) != -1
    }

    private let openSettingsNotification = Notification.Name("com.openai.vibe-focus.open-settings")

    private func requestExistingInstanceOpenSettings() {
        DistributedNotificationCenter.default().post(
            name: openSettingsNotification,
            object: nil
        )
    }
}
