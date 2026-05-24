import AppKit
import SwiftUI
import Foundation

extension ScreenOverlayManager {

    func setupSignalHandler() {
        signal(SIGUSR1, SIG_IGN)

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
    }

    func clearSpaceIndexCache() {
        lastQueryTimes.removeAll()
        screenSpaceCache.removeAll()
    }

    func cancelPendingSignalRefreshes() {
        for workItem in pendingSignalRefreshWorkItems {
            workItem.cancel()
        }
        pendingSignalRefreshWorkItems.removeAll()
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
        refreshSpaceIndices(force: true)
        scheduleSignalFollowUpRefreshes()
    }

    func registerYabaiSignals() {
        guard let checkResult = YabaiClient.run(arguments: ["-m", "signal", "--list"]),
              checkResult.exitCode == 0 else { return }

        if checkResult.stdout.contains("vibefocus-space-changed") {
            return
        }

        let scriptPath: String
        if let bundlePath = Bundle.main.path(forResource: "yabai-space-changed", ofType: "sh") {
            scriptPath = bundlePath
        } else if FileManager.default.fileExists(atPath: "Resources/yabai-space-changed.sh") {
            scriptPath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("Resources/yabai-space-changed.sh")
        } else {
            log("Could not find yabai-space-changed.sh script in Bundle or project directory")
            return
        }

        let _ = YabaiClient.run(arguments: [
            "-m", "signal", "--add",
            "event=space_changed",
            "action=\"\(scriptPath)\"",
            "label=vibefocus-space-changed"
        ])
    }
}
