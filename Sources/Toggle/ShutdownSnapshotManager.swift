import Foundation
import AppKit

@MainActor
final class ShutdownSnapshotManager {
    static let shared = ShutdownSnapshotManager()

    /// 快照文件路径
    private let snapshotDir: String
    private let snapshotPath: String

    /// 定时快照间隔（秒）
    private let periodicInterval: TimeInterval = 10 * 60 // 10 分钟
    private var periodicTimer: Timer?

    /// 统一默认值（唯一源）
    static let defaultAutoRestoreOnBoot = true
    static let defaultShutdownSnapshotEnabled = true

    /// 是否已启用关机快照
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shutdownSnapshotEnabled") as? Bool ?? Self.defaultShutdownSnapshotEnabled }
        set {
            UserDefaults.standard.set(newValue, forKey: "shutdownSnapshotEnabled")
            PreferencesSync.persistToDisk()
        }
    }

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        snapshotDir = dir
        snapshotPath = (dir as NSString).appendingPathComponent("shutdown-snapshot.json")
    }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled else {
            log("[ShutdownSnapshot] disabled, skipping startup")
            return
        }
        registerShutdownNotifications()
        startPeriodicSnapshot()
        log("[ShutdownSnapshot] started — monitoring shutdown events + periodic snapshots every \(Int(periodicInterval/60))min")
    }

    func stop() {
        unregisterShutdownNotifications()
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Shutdown Notifications

    private func registerShutdownNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // NSApplication.willTerminateNotification 必须通过 NotificationCenter.default 注册
        // NSWorkspace.shared.notificationCenter 不会分发 NSApplication 通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        log("[ShutdownSnapshot] registered shutdown notifications")
    }

    private func unregisterShutdownNotifications() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handlePowerOff(_ notification: Notification) {
        log("[ShutdownSnapshot] power-off event received: \(notification.name.rawValue)")
        captureAndSave(reason: "shutdown_\(notification.name.rawValue)")
    }

    // MARK: - Periodic Snapshot

    private func startPeriodicSnapshot() {
        // 启动时立即采集一次，确保即使没有关机事件也有快照可用
        captureAndSave(reason: "startup")

        periodicTimer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureAndSave(reason: "periodic")
            }
        }
    }

    // MARK: - Snapshot Capture

    func captureAndSave(reason: String) {
        let startTime = Date()
        log("[ShutdownSnapshot] capturing snapshot (reason: \(reason))")

        let snapshot = captureSnapshot()
        let elapsed = Date().timeIntervalSince(startTime)

        guard saveSnapshot(snapshot) else {
            log("[ShutdownSnapshot] failed to save snapshot", level: .error)
            return
        }

        log("[ShutdownSnapshot] captured \(snapshot.terminalWindows.count) terminal windows in \(String(format: "%.0f", elapsed * 1000))ms (reason: \(reason))")
    }

    /// 采集当前所有终端窗口快照
    func captureSnapshot() -> ShutdownSnapshot {
        var terminalWindows: [TerminalWindowSnapshot] = []

        // 获取所有终端类 App 的窗口
        let isTerminalApp = { (bundleID: String?) in
            bundleID.map { TerminalRegistry.isTerminalBundleID($0) } ?? false
        }

        let windowList = cgWindowListAll()

        // 按 PID 分组，过滤终端 App
        var pidToBundleID: [pid_t: String] = [:]
        var pidToAppName: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, isTerminalApp(bundleID) {
                pidToBundleID[app.processIdentifier] = bundleID
                pidToAppName[app.processIdentifier] = app.localizedName ?? bundleID
            }
        }

        let runningTerminalApps = Set(pidToBundleID.values)

        // 逐窗口采集
        for entry in windowList {
            guard let bundleID = pidToBundleID[entry.ownerPID],
                  let appName = pidToAppName[entry.ownerPID] else {
                continue
            }

            guard entry.layer == 0 else { continue }

            guard let frame = entry.bounds else { continue }
            guard frame.width > 200, frame.height > 150 else { continue }

            let title = entry.name

            // 获取屏幕 ID
            // CGWindowListCopyWindowInfo 返回 Quartz 坐标（原点在主屏幕左上角，Y 向下）
            // NSScreen 使用 AppKit 坐标（原点在主屏幕左下角，Y 向上）
            // 需要转换 Y 坐标才能正确匹配屏幕
            let mainScreenHeight = CoordinateKit.mainScreenHeight
            let appKitFrame = CGRect(
                x: frame.origin.x,
                y: mainScreenHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            let displayID = WindowManager.shared.displayID(for: appKitFrame)

            // 获取 Space 信息
            let spaceContext = SpaceController.shared.captureSpaceContext(windowID: entry.windowID)

            // 从 SessionWindowRegistry 查找 Claude Code 绑定
            let claudeBinding = SessionWindowRegistry.shared.findBinding(forWindowID: entry.windowID)

            let snapshot = TerminalWindowSnapshot(
                windowID: entry.windowID,
                pid: entry.ownerPID,
                appName: appName,
                bundleIdentifier: bundleID,
                title: title,
                frame: SnapshotRect(frame),
                displayID: displayID ?? 0,
                spaceIndex: spaceContext.sourceSpaceIndex,
                displayLocalSpaceIndex: spaceContext.sourceDisplaySpaceIndex,
                tty: claudeBinding?.tty,
                termSessionID: claudeBinding?.termSessionID,
                itermSessionID: claudeBinding?.itermSessionID,
                claudeSessionID: claudeBinding?.sessionID,
                claudeProjectDir: claudeBinding?.cwd,
                claudeModel: claudeBinding?.model
            )

            terminalWindows.append(snapshot)
        }

        return ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
            terminalWindows: terminalWindows,
            runningTerminalApps: runningTerminalApps
        )
    }

    // MARK: - Persistence

    private func saveSnapshot(_ snapshot: ShutdownSnapshot) -> Bool {
        if !FileManager.default.fileExists(atPath: snapshotDir) {
            try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            return true
        } catch {
            log("[ShutdownSnapshot] save failed: \(error)", level: .error)
            return false
        }
    }

    /// 读取上次关机快照
    func loadSnapshot() -> ShutdownSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    }

    /// 快照是否来自上次启动（判断 systemUptime 是否小于当前 uptime）
    func isSnapshotFromPreviousBoot(_ snapshot: ShutdownSnapshot) -> Bool {
        snapshot.systemUptimeAtCapture < ProcessInfo.processInfo.systemUptime - 60
    }

    /// 清除快照文件（恢复完成后调用）
    func clearSnapshot() {
        try? FileManager.default.removeItem(atPath: snapshotPath)
        log("[ShutdownSnapshot] snapshot file cleared")
    }

    /// 快照文件是否存在
    var hasPendingSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotPath)
    }
}
