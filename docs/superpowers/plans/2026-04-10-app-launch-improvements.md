# 应用启动功能改进实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 改进 VibeFocus 应用的启动流程，添加启动时健康检查、优雅的错误处理和用户友好的启动反馈

**Architecture:** 通过创建 `AppLauncher` 核心类来集中管理启动流程，添加启动状态追踪、依赖健康检查和异步初始化支持。使用 SwiftUI 展示启动进度，确保用户了解应用启动状态。

**Tech Stack:** Swift, SwiftUI, Foundation, ServiceManagement

---

## 文件结构

```
Sources/
├── AppLauncher.swift           # 新增：应用启动管理器
├── AppLaunchStatus.swift       # 新增：启动状态模型
├── AppLaunchView.swift         # 新增：启动进度 UI
├── LaunchHealthChecker.swift   # 新增：启动健康检查
├── SettingsUI.swift            # 修改：集成启动流程
├── AppDelegate.swift           # 新增：分离 AppDelegate（从 SettingsUI）
└── ...existing files
```

---

## Task 1: 创建启动状态模型

**Files:**
- Create: `Sources/AppLaunchStatus.swift`

- [ ] **Step 1: 创建启动状态枚举和模型**

```swift
import Foundation

enum LaunchPhase: String, CaseIterable {
    case initializing = "初始化中"
    case checkingSingleInstance = "检查单实例"
    case checkingInstallation = "检查安装位置"
    case loadingConfiguration = "加载配置"
    case checkingPermissions = "检查权限"
    case settingUpHotkeys = "设置热键"
    case settingUpMenuBar = "设置菜单栏"
    case startingServices = "启动服务"
    case completed = "启动完成"
    case failed = "启动失败"

    var progress: Double {
        switch self {
        case .initializing: return 0.0
        case .checkingSingleInstance: return 0.1
        case .checkingInstallation: return 0.2
        case .loadingConfiguration: return 0.3
        case .checkingPermissions: return 0.5
        case .settingUpHotkeys: return 0.7
        case .settingUpMenuBar: return 0.8
        case .startingServices: return 0.9
        case .completed: return 1.0
        case .failed: return 1.0
        }
    }
}

struct LaunchPhaseResult {
    let phase: LaunchPhase
    let success: Bool
    let message: String?
    let error: LaunchError?
    let duration: TimeInterval
}

enum LaunchError: Error {
    case anotherInstanceRunning
    case invalidInstallationLocation
    case accessibilityPermissionDenied
    case hotkeyRegistrationFailed
    case serviceStartupFailed

    var localizedDescription: String {
        switch self {
        case .anotherInstanceRunning:
            return "检测到另一个 VibeFocus 实例正在运行"
        case .invalidInstallationLocation:
            return "应用安装位置不正确"
        case .accessibilityPermissionDenied:
            return "需要辅助功能权限才能控制窗口"
        case .hotkeyRegistrationFailed:
            return "热键注册失败"
        case .serviceStartupFailed:
            return "服务启动失败"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .anotherInstanceRunning:
            return "请退出其他实例后重试，或切换到已运行的实例"
        case .invalidInstallationLocation:
            return "请将应用移动到 ~/Applications/ 或 /Applications/ 目录"
        case .accessibilityPermissionDenied:
            return "请在系统设置中授予 VibeFocus 辅助功能权限"
        case .hotkeyRegistrationFailed:
            return "请检查快捷键是否与其他应用冲突"
        case .serviceStartupFailed:
            return "请重启应用或检查系统日志"
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AppLaunchStatus.swift
git commit -m "feat(launch): add launch status models and enums"
```

---

## Task 2: 创建启动健康检查器

**Files:**
- Create: `Sources/LaunchHealthChecker.swift`

- [ ] **Step 1: 创建健康检查器类**

```swift
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

    enum HealthSeverity {
        case info      // 仅信息，不影响启动
        case warning   // 警告，可以启动但功能受限
        case critical  // 严重，阻止启动
    }

    private init() {}

    func performFullCheck() async -> [HealthCheckResult] {
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

        return results.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    func checkAccessibilityPermission() async -> HealthCheckResult {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        return HealthCheckResult(
            component: "辅助功能权限",
            isHealthy: isTrusted,
            message: isTrusted ? "已授权" : "未授权",
            severity: isTrusted ? .info : .warning
        )
    }

    func checkInstallLocation() async -> HealthCheckResult {
        let expectedPaths = [
            NSHomeDirectory() + "/Applications/VibeFocus.app",
            "/Applications/VibeFocus.app"
        ]
        let actualPath = Bundle.main.bundleURL.path

        let isValid = expectedPaths.contains(actualPath) ||
                      actualPath.hasSuffix("/dist/VibeFocus.app")

        return HealthCheckResult(
            component: "安装位置",
            isHealthy: isValid,
            message: isValid ? "位置正确" : "位置异常: \(actualPath)",
            severity: isValid ? .info : .warning
        )
    }

    func checkScreenAccess() async -> HealthCheckResult {
        let hasAccess = CGPreflightScreenCaptureAccess()

        return HealthCheckResult(
            component: "屏幕录制权限",
            isHealthy: hasAccess,
            message: hasAccess ? "已授权" : "未授权（部分功能受限）",
            severity: hasAccess ? .info : .info
        )
    }

    func checkDiskSpace() async -> HealthCheckResult {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                let mb = capacity / 1_048_576
                let isHealthy = mb > 100
                return HealthCheckResult(
                    component: "磁盘空间",
                    isHealthy: isHealthy,
                    message: "可用: \(mb) MB",
                    severity: isHealthy ? .info : .warning
                )
            }
        } catch {
            return HealthCheckResult(
                component: "磁盘空间",
                isHealthy: false,
                message: "无法检测: \(error.localizedDescription)",
                severity: .info
            )
        }

        return HealthCheckResult(
            component: "磁盘空间",
            isHealthy: true,
            message: "未知",
            severity: .info
        )
    }

    func checkSystemVersion() async -> HealthCheckResult {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isSupported = version.majorVersion >= 13

        return HealthCheckResult(
            component: "系统版本",
            isHealthy: isSupported,
            message: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            severity: isSupported ? .info : .critical
        )
    }

    func hasCriticalIssues(_ results: [HealthCheckResult]) -> Bool {
        results.contains { $0.severity == .critical && !$0.isHealthy }
    }

    func hasWarnings(_ results: [HealthCheckResult]) -> Bool {
        results.contains { $0.severity == .warning && !$0.isHealthy }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/LaunchHealthChecker.swift
git commit -m "feat(launch): add launch health checker"
```

---

## Task 3: 创建应用启动管理器

**Files:**
- Create: `Sources/AppLauncher.swift`
- Modify: `Sources/SettingsUI.swift:1548-1614` (修改 AppDelegate 启动逻辑)

- [ ] **Step 1: 创建 AppLauncher 类**

```swift
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
                let existingVersion = existing.version ?? "unknown"

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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AppLauncher.swift
git commit -m "feat(launch): add app launcher with phase management"
```

---

## Task 4: 创建启动进度 UI

**Files:**
- Create: `Sources/AppLaunchView.swift`

- [ ] **Step 1: 创建启动进度视图**

```swift
import SwiftUI

struct AppLaunchView: View {
    @StateObject private var launcher = AppLauncher.shared
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 24) {
            // 图标
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 64))
                .foregroundStyle(.accent)

            // 标题
            Text("VibeFocus")
                .font(.largeTitle)
                .fontWeight(.semibold)

            // 进度条
            VStack(spacing: 8) {
                ProgressView(value: launcher.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)

                Text(launcher.currentPhase.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 状态信息
            if let error = launcher.launchError {
                LaunchErrorView(error: error)
            } else if launcher.currentPhase == .completed {
                LaunchSuccessView()
            }

            // 详情开关
            if !launcher.phaseResults.isEmpty {
                Button(showDetails ? "隐藏详情" : "显示详情") {
                    withAnimation {
                        showDetails.toggle()
                    }
                }
                .buttonStyle(.link)
            }

            // 详情列表
            if showDetails {
                LaunchDetailsList(results: launcher.phaseResults)
                    .frame(maxHeight: 200)
            }

            // 健康检查结果
            if !launcher.healthResults.isEmpty {
                HealthCheckSummary(results: launcher.healthResults)
            }
        }
        .padding(32)
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - Subviews

struct LaunchErrorView: View {
    let error: LaunchError

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.headline)

            Text(error.recoverySuggestion)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("打开系统设置") {
                    error.openSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("重试") {
                    Task {
                        await AppLauncher.shared.launch()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}

struct LaunchSuccessView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("启动成功")
                .foregroundStyle(.secondary)
        }
    }
}

struct LaunchDetailsList: View {
    let results: [LaunchPhaseResult]

    var body: some View {
        List(results) { result in
            HStack {
                Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result.success ? .green : .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.phase.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)

                    if let message = result.message {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(String(format: "%.3fs", result.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }
}

struct HealthCheckSummary: View {
    let results: [LaunchHealthChecker.HealthCheckResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("健康检查")
                .font(.caption)
                .fontWeight(.medium)

            ForEach(results, id: \.component) { result in
                HStack {
                    Image(systemName: iconName(for: result))
                        .foregroundStyle(color(for: result))

                    Text(result.component)
                        .font(.caption2)

                    Spacer()

                    Text(result.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func iconName(for result: LaunchHealthChecker.HealthCheckResult) -> String {
        switch result.severity {
        case .info:
            return result.isHealthy ? "checkmark.circle" : "info.circle"
        case .warning:
            return result.isHealthy ? "checkmark.circle" : "exclamationmark.triangle"
        case .critical:
            return result.isHealthy ? "checkmark.circle" : "xmark.octagon"
        }
    }

    private func color(for result: LaunchHealthChecker.HealthCheckResult) -> Color {
        switch result.severity {
        case .info:
            return result.isHealthy ? .green : .blue
        case .warning:
            return result.isHealthy ? .green : .orange
        case .critical:
            return result.isHealthy ? .green : .red
        }
    }
}

// MARK: - Extensions

extension LaunchPhaseResult: Identifiable {
    var id: String { phase.rawValue }
}

extension LaunchError {
    func openSettings() {
        switch self {
        case .accessibilityPermissionDenied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .invalidInstallationLocation:
            if let url = URL(string: "file:///Applications") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

// MARK: - Preview

#Preview {
    AppLaunchView()
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AppLaunchView.swift
git commit -m "feat(launch): add launch progress UI"
```

---

## Task 5: 分离 AppDelegate 并集成启动流程

**Files:**
- Create: `Sources/AppDelegate.swift`
- Modify: `Sources/SettingsUI.swift:1535-1967` (移除 AppDelegate 代码)

- [ ] **Step 1: 创建独立的 AppDelegate.swift**

```swift
import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var launchWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        logDiagnostics("launch")

        // 显示启动窗口
        showLaunchWindow()

        // 执行启动序列
        Task {
            await AppLauncher.shared.launch()

            // 启动完成后设置 UI
            if AppLauncher.shared.canProceed {
                await MainActor.run {
                    self.setupMenuBar()
                    self.closeLaunchWindow()
                    self.showSettingsWindowOnLaunch()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.unregisterYabaiSignals()
        ClaudeHookServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - Launch Window

    private func showLaunchWindow() {
        let contentView = AppLaunchView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeFocus"
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false

        launchWindowController = NSWindowController(window: window)
        launchWindowController?.showWindow(nil)
    }

    private func closeLaunchWindow() {
        launchWindowController?.close()
        launchWindowController = nil
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let image = loadStatusBarImage() {
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "VF"
            }
        }

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        toggleMenuItem = toggleItem
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        refreshMenuLabels()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
    }

    private func loadStatusBarImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func refreshMenuLabels() {
        toggleMenuItem?.title = "Toggle (\(HotKeyManager.shared.currentHotKey.displayString))"
    }

    @objc private func toggle() {
        WindowManager.shared.toggle()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(shouldFocus: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSettingsWindowOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }
}
```

- [ ] **Step 2: 修改 SettingsUI.swift 移除 AppDelegate**

编辑 `Sources/SettingsUI.swift`:
- 删除第 1535-1967 行的 AppDelegate 类
- 保留 VibeFocusApp 结构但移除对旧 AppDelegate 的依赖

```swift
// 在 SettingsUI.swift 末尾，修改 @main 结构

@main
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AppDelegate.swift Sources/SettingsUI.swift
git commit -m "refactor(launch): separate AppDelegate and integrate launch flow"
```

---

## Task 6: 添加命令行启动参数支持

**Files:**
- Create: `Sources/LaunchArguments.swift`
- Modify: `Sources/AppDelegate.swift` (添加参数处理)

- [ ] **Step 1: 创建启动参数解析器**

```swift
import Foundation

struct LaunchArguments {
    static let shared = LaunchArguments()

    let skipLaunchWindow: Bool
    let showHealthCheck: Bool
    let debugMode: Bool
    let quickLaunch: Bool

    private init() {
        let arguments = ProcessInfo.processInfo.arguments

        skipLaunchWindow = arguments.contains("--skip-launch-window") ||
                          arguments.contains("-s")
        showHealthCheck = arguments.contains("--health-check") ||
                         arguments.contains("-h")
        debugMode = arguments.contains("--debug") ||
                   arguments.contains("-d")
        quickLaunch = arguments.contains("--quick") ||
                     arguments.contains("-q")
    }

    static func printUsage() {
        print("""
        VibeFocus - 窗口聚焦工具

        用法: VibeFocusHotkeys [选项]

        选项:
          -s, --skip-launch-window    跳过启动窗口
          -h, --health-check          启动时显示健康检查
          -d, --debug                 启用调试日志
          -q, --quick                 快速启动（跳过部分检查）
          --help                      显示此帮助信息

        示例:
          VibeFocusHotkeys --debug
          VibeFocusHotkeys -s -q
        """)
    }
}
```

- [ ] **Step 2: 修改 AppDelegate 支持命令行参数**

在 `Sources/AppDelegate.swift` 中修改 `applicationDidFinishLaunching`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    log("applicationDidFinishLaunching")
    logDiagnostics("launch")

    // 处理帮助参数
    if ProcessInfo.processInfo.arguments.contains("--help") {
        LaunchArguments.printUsage()
        NSApp.terminate(nil)
        return
    }

    let args = LaunchArguments.shared

    // 快速启动模式
    if args.quickLaunch {
        setupMenuBar()
        showSettingsWindowOnLaunch()
        return
    }

    // 跳过启动窗口
    if args.skipLaunchWindow {
        Task {
            await AppLauncher.shared.launch()
            await MainActor.run {
                self.setupMenuBar()
                self.showSettingsWindowOnLaunch()
            }
        }
        return
    }

    // 标准启动流程（带启动窗口）
    showLaunchWindow()

    Task {
        await AppLauncher.shared.launch()

        await MainActor.run {
            if AppLauncher.shared.canProceed {
                self.setupMenuBar()
                self.closeLaunchWindow()
                self.showSettingsWindowOnLaunch()
            }
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/LaunchArguments.swift Sources/AppDelegate.swift
git commit -m "feat(launch): add command-line argument support"
```

---

## Task 7: 更新运行脚本支持新参数

**Files:**
- Modify: `run.sh`

- [ ] **Step 1: 增强 run.sh 脚本**

```bash
#!/bin/bash
set -euo pipefail

echo "=== VibeFocus 本地运行 ==="
echo ""

# 解析参数
SKIP_LAUNCH=false
DEBUG_MODE=false
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip-launch)
      SKIP_LAUNCH=true
      shift
      ;;
    -d|--debug)
      DEBUG_MODE=true
      shift
      ;;
    -q|--quick)
      QUICK_MODE=true
      shift
      ;;
    -h|--help)
      echo "用法: ./run.sh [选项]"
      echo ""
      echo "选项:"
      echo "  -s, --skip-launch    跳过启动窗口"
      echo "  -d, --debug          启用调试日志"
      echo "  -q, --quick          快速启动"
      echo "  -h, --help           显示帮助"
      exit 0
      ;;
    *)
      echo "未知选项: $1"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTABLE_PATH="$SCRIPT_DIR/.build/release/VibeFocusHotkeys"
STDOUT_LOG="/tmp/vibefocus-run.stdout"
STDERR_LOG="/tmp/vibefocus-run.stderr"

echo "构建 release 二进制..."
swift build -c release

echo "停止旧进程..."
pkill -x "VibeFocusHotkeys" >/dev/null 2>&1 || true
sleep 1

# 构建启动参数
LAUNCH_ARGS=""
if [[ "$SKIP_LAUNCH" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --skip-launch-window"
fi
if [[ "$DEBUG_MODE" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --debug"
fi
if [[ "$QUICK_MODE" == true ]]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --quick"
fi

echo "启动参数: $LAUNCH_ARGS"
echo "后台启动本地二进制..."
nohup "$EXECUTABLE_PATH" $LAUNCH_ARGS >"$STDOUT_LOG" 2>"$STDERR_LOG" &
APP_PID=$!
sleep 2

echo ""
echo "PID: $APP_PID"
echo "可执行文件: $EXECUTABLE_PATH"
echo "应用日志: /tmp/vibefocus.log"
echo "stdout: $STDOUT_LOG"
echo "stderr: $STDERR_LOG"

if grep -q "AX trusted (prompt=false)=true" /tmp/vibefocus.log 2>/dev/null; then
  echo "辅助功能权限: 已就绪"
else
  echo "辅助功能权限: 尚未确认，请检查 /tmp/vibefocus.log"
fi
```

- [ ] **Step 2: Commit**

```bash
git add run.sh
git commit -m "feat(launch): update run.sh with new launch options"
```

---

## Task 8: 构建并测试

**Files:**
- All modified files

- [ ] **Step 1: 构建项目**

```bash
swift build -c release
```

- [ ] **Step 2: 运行测试**

```bash
# 标准启动（带启动窗口）
./run.sh

# 跳过启动窗口
./run.sh --skip-launch

# 调试模式
./run.sh --debug

# 快速启动
./run.sh --quick
```

- [ ] **Step 3: 最终 Commit**

```bash
git add -A
git commit -m "feat(launch): complete app launch improvements

- Add launch status tracking with progress indicators
- Add health checker for system compatibility
- Add AppLauncher for centralized launch management
- Add AppLaunchView for user-friendly launch UI
- Separate AppDelegate for cleaner architecture
- Add command-line argument support
- Update run.sh with new launch options"
```

---

## 总结

此实现计划添加了以下功能：

1. **启动状态追踪** - 分阶段显示启动进度
2. **健康检查** - 自动检测系统兼容性和权限
3. **启动窗口** - 用户友好的启动进度 UI
4. **错误处理** - 清晰的错误提示和恢复建议
5. **命令行参数** - 支持多种启动模式
6. **代码重构** - 分离 AppDelegate，更清晰架构
