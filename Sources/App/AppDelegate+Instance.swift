import AppKit
import Darwin

// Sources/App/AppDelegate+Instance.swift — B158 自 AppDelegate+MenuAndInstance.swift 按域拆出
//（逐字搬移零行为变更）：单实例排他锁/既有实例发现/应用图标/安装位置校验/AX 授权引导。

extension AppDelegate {

    func acquireExclusiveLock() -> Bool {
        // P-INST-98: 单实例排他锁获取耗时（POSIX open lockFilePath O_CREAT|O_RDWR 创建/打开锁文件 + flock LOCK_EX|LOCK_NB 非阻塞加锁；启动单实例检测；内核文件锁竞争可阻塞）。
        #if PERF_INSTRUMENT
        let aelStart = Date()
        defer {
            log("[AppDelegate] acquireExclusiveLock finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aelStart))
            ])
        }
        #endif
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard fd != -1 else {
            log("Failed to open lock file")
            return false
        }

        let result = flock(fd, LOCK_EX | LOCK_NB)
        if result == -1 {
            close(fd)
            return false
        }

        log("Acquired exclusive lock, PID \(ProcessInfo.processInfo.processIdentifier)")
        return true
    }

    func findExistingInstance() -> ExistingInstanceInfo? {
        // P-INST-209: 单实例检查耗时（NSWorkspace.shared.runningApplications 枚举所有运行进程 + Bundle.main.bundleIdentifier；启动路径调用，runningApplications 可能在多进程系统累积；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let feiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: feiStart)
            if durMs >= 50 { log("[AppDelegate] findExistingInstance slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        if let bundleID {
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    return ExistingInstanceInfo(
                        app: app,
                        version: installedVersion(for: app),
                        path: app.bundleURL?.path
                    )
                }
            }
        }

        return nil
    }

    func applyApplicationIcon() {
        // P-INST-102: 应用图标应用耗时（bundledAppIconImage 从 Bundle 加载 NSImage + 设置 NSApp.applicationIconImage；启动路径调用；启动延迟归因）。
        #if PERF_INSTRUMENT
        let aaiStart = Date()
        defer {
            log("[AppDelegate] applyApplicationIcon finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: aaiStart))
            ])
        }
        #endif
        guard let icon = bundledAppIconImage() else {
            return
        }
        NSApp.applicationIconImage = icon
    }

    func enforceExpectedInstallLocation() -> Bool {
        // P-INST-95: 安装位置校验耗时（Bundle.main.bundleURL + isAllowedDevelopmentBundlePath + fileExists 检查预期路径 + 可能触发 NSWorkspace.open 重定位；启动路径调用；启动延迟归因）。
        #if PERF_INSTRUMENT
        let eeiStart = Date()
        defer {
            log("[AppDelegate] enforceExpectedInstallLocation finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: eeiStart))
            ])
        }
        #endif
        let actualURL = Bundle.main.bundleURL
        let actual = actualURL.path
        if actualURL.pathExtension != "app" {
            return true
        }

        if isAllowedDevelopmentBundlePath(actual) {
            return true
        }

        let expectedPaths = expectedAppBundlePaths()
        guard !expectedPaths.contains(actual) else {
            return true
        }

        log("Unexpected app location. actual=\(actual) expected=\(expectedPaths)")
        logDiagnostics("unexpected_location")

        for expected in expectedPaths {
            if FileManager.default.fileExists(atPath: expected) {
                NSWorkspace.shared.open(URL(fileURLWithPath: expected))
                break
            }
        }

        showWrongLocationAlert(actual: actual, expectedPaths: expectedPaths)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
        return false
    }

    func promptAccessibilityIfNeeded() {
        // P-INST-262: AX 未授权时延迟打开系统设置入口（accessibilityGranted 缓存检查 + DispatchQueue 0.4s 后调度 openAccessibilitySettings NSWorkspace.open；启动调用，open 可能阻塞；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let paiStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: paiStart)
            if durMs >= 50 { log("[App] promptAccessibilityIfNeeded slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        guard HotKeyManager.shared.accessibilityGranted == false else {
            return
        }
        log("Accessibility not granted; opening System Settings.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            HotKeyManager.shared.openAccessibilitySettings()
        }
    }
}
