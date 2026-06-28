import AppKit
import SwiftUI
import Foundation

extension ScreenOverlayManager {

    func setupSignalHandler() {
        // P-INST-244: SIGUSR1 信号监听安装耗时（signal SIG_IGN 注册 + DispatchSource.makeSignalSource GCD 内核信号源创建 + resume 激活；启动路径调用，内核信号注册可能阻塞；slow-op ≥50ms warn）。
        let sshStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sshStart)
            if durMs >= 50 { log("[Overlay] setupSignalHandler slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
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
        // P-INST-257: SIGUSR1 space 切换后多次 follow-up 刷新调度入口（N 个 DispatchWorkItem 构造 + asyncAfter 调度 refreshSpaceIndices P-INST-245；space 切换触发，实际刷新在闭包内已覆盖，此处归因调度入口）。
        let ssfStart = Date()
        defer {
            log("[Overlay] scheduleSignalFollowUpRefreshes finished", level: .debug, fields: ["count": String(signalFollowUpRefreshDelays.count), "durationMs": String(elapsedMilliseconds(since: ssfStart))])
        }
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
        // P-INST-246: force refresh 编排端到端耗时（cancelPendingSignalRefreshes + clearSpaceIndexCache + refreshSpaceIndices P-INST-245 + scheduleSignalFollowUpRefreshes DispatchWorkItem 调度；SIGUSR1 信号/handleScreenChange/toggle 后调用，force refresh 主线程归因）。
        let tfrStart = Date()
        defer {
            log("[Overlay] triggerForceRefresh finished", level: .debug, fields: ["reason": reason, "durationMs": String(elapsedMilliseconds(since: tfrStart))])
        }
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

    /// P3.6: toggle 后 force refresh debounce。连续 toggle（主场景）取消前一个 work item，只在 toggle 停止
    /// 300ms 后刷新一次（20 toggle 60 refresh → 1 refresh）。toggle 的 yabai window --space(focus=false)
    /// 只移窗口不改可见 space，overlay 编号不变，延后刷新无视觉影响。省下的 yabai 带宽留给下次 toggle 的
    /// 同步 captureSpaceContext/visibleSpaceIndex query —— yabai 单进程串行，force refresh 后台 Task 的
    /// query 堆积会占用 yabai，让 toggle 同步 fork 排队（实测前置 query 650ms + p2SpaceMoveMs 6→36ms）。
    /// 300ms 窗口覆盖典型连续 toggle 间隔（~2s），仅在用户停止 toggle 后补一次 overlay 刷新。
    func schedulePostToggleRefresh(reason: String) {
        // P-INST-256: toggle 后防抖刷新调度入口（cancel 旧 workItem + DispatchWorkItem 0.3s 后调度 triggerForceRefresh P-INST-246；toggle 后调用，实际刷新在闭包内已覆盖，此处归因调度入口/去抖频率）。
        let sptStart = Date()
        defer {
            log("[Overlay] schedulePostToggleRefresh finished", level: .debug, fields: ["reason": reason, "durationMs": String(elapsedMilliseconds(since: sptStart))])
        }
        pendingPostToggleRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            log("[FORCE_REFRESH] Debounced post-toggle refresh firing reason=\(reason)")
            self.triggerForceRefresh(reason: reason)
        }
        pendingPostToggleRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func registerYabaiSignals() {
        // P-INST-93: yabai space_changed 信号注册耗时（2x YabaiClient.run fork：signal --list 检查 + signal --add 注册；+ Bundle/FileManager 解析 yabai-space-changed.sh 路径；启动/overlay 初始化调用；yabai fork 已由 P-INST-37 chokepoint 内部覆盖，此为顶层聚合）。
        let rysStart = Date()
        defer {
            log("[ScreenOverlayManager] registerYabaiSignals finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rysStart))
            ])
        }
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
