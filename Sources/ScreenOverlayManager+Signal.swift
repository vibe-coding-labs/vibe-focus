import AppKit
import SwiftUI
import Foundation

extension ScreenOverlayManager {

    func setupSignalHandler() {
        // 设置 SIGUSR1 信号处理
        signal(SIGUSR1, SIG_IGN)  // 忽略默认处理

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            log("[SIGUSR1] ====== WORKSPACE SWITCH DETECTED at \(timestamp) ======")
            self.triggerForceRefresh(reason: "sigusr1")
        }
        source.resume()

        ScreenOverlayManager.signalSource = source
        log("Signal handler setup complete")
    }

    func clearSpaceIndexCache() {
        log("ScreenOverlayManager.clearSpaceIndexCache entry", level: .debug, fields: ["cachedSpaceCount": String(cachedSpaceIndices.count), "lastQueryCount": String(lastQueryTimes.count), "screenSpaceCacheCount": String(screenSpaceCache.count)])
        cachedSpaceIndices.removeAll()
        lastQueryTimes.removeAll()
        // 关键修复：同时清除 screenSpaceCache，确保信号触发时强制刷新
        screenSpaceCache.removeAll()
        log("Cleared all caches including screenSpaceCache")
    }

    func cancelPendingSignalRefreshes() {
        log("ScreenOverlayManager.cancelPendingSignalRefreshes entry", level: .debug, fields: ["pendingCount": String(pendingSignalRefreshWorkItems.count)])
        for workItem in pendingSignalRefreshWorkItems {
            workItem.cancel()
        }
        pendingSignalRefreshWorkItems.removeAll()
        log("ScreenOverlayManager.cancelPendingSignalRefreshes exit", level: .debug)
    }

    func scheduleSignalFollowUpRefreshes() {
        for (offset, delay) in signalFollowUpRefreshDelays.enumerated() {
            let isLast = offset == signalFollowUpRefreshDelays.count - 1
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                log("[SIGUSR1] Follow-up refresh (\(Int(delay * 1000))ms after signal)")
                self.refreshSpaceIndices(force: true)
                if isLast {
                    log("[SIGUSR1] ====== WORKSPACE SWITCH HANDLING COMPLETE ======")
                }
            }
            pendingSignalRefreshWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func triggerForceRefresh(reason: String) {
        guard !automaticRefreshSuspended else {
            log("[FORCE_REFRESH] Skipped while automatic refresh is suspended, reason=\(reason)")
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastForceRefreshTriggerAt) < minForceRefreshTriggerInterval {
            log("[FORCE_REFRESH] Skip duplicated trigger reason=\(reason)")
            return
        }
        lastForceRefreshTriggerAt = now

        log("[FORCE_REFRESH] Triggered by reason=\(reason), clearing caches and refreshing")
        cancelPendingSignalRefreshes()
        clearSpaceIndexCache()

        log("[FORCE_REFRESH] Immediate refresh starting...")
        refreshSpaceIndices(force: true)
        scheduleSignalFollowUpRefreshes()
    }

    func registerYabaiSignals() {
        guard let yabaiPath = getYabaiPath() else { return }

        // 检查是否已注册信号
        let checkTask = Process()
        checkTask.launchPath = yabaiPath
        checkTask.arguments = ["-m", "signal", "--list"]

        let pipe = Pipe()
        checkTask.standardOutput = pipe
        checkTask.launch()
        checkTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        // 如果已经注册了 vibefocus 信号，跳过
        if output.contains("vibefocus-space-changed") {
            return
        }

        // 获取脚本路径 - 优先从 Bundle 查找，如果不存在则从项目目录查找
        let scriptPath: String
        if let bundlePath = Bundle.main.path(forResource: "yabai-space-changed", ofType: "sh") {
            scriptPath = bundlePath
        } else if FileManager.default.fileExists(atPath: "Resources/yabai-space-changed.sh") {
            // 开发模式：从项目根目录查找
            scriptPath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("Resources/yabai-space-changed.sh")
        } else {
            log("Could not find yabai-space-changed.sh script in Bundle or project directory")
            return
        }
        log("Using yabai-space-changed script at: \(scriptPath)")

        // 注册信号: 空间切换时触发
        let registerTask = Process()
        registerTask.launchPath = yabaiPath
        registerTask.arguments = [
            "-m", "signal", "--add",
            "event=space_changed",
            "action=\"\(scriptPath)\"",
            "label=vibefocus-space-changed"
        ]
        registerTask.launch()
        registerTask.waitUntilExit()

        log("Registered yabai signal for space changes")
    }
}
