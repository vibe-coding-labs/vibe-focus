import Foundation

// IPS 解析与文件 I/O 已移至 CrashContextRecorder+IO.swift

@MainActor
final class CrashContextRecorder {
    static let shared = CrashContextRecorder()

    struct SessionState: Codable {
        var pid: Int32
        var launchedAt: String
        var cleanExit: Bool
        var events: [String]
        var lastIngestedCrashReport: String?
    }

    let stateFileURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-context.json")
    let plainLogFileURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
    let structuredLogFileURL = URL(fileURLWithPath: "/tmp/vibefocus-events.jsonl")
    let plainCrashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-tail.log")
    let structuredCrashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-tail-events.jsonl")
    let maxEvents = 300
    let plainTailLineLimit = 500
    let structuredTailLineLimit = 1200
    let diagnosticReportsDirectory = URL(
        fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"),
        isDirectory: true
    )

    let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var state: SessionState?

    /// 异步写入队列 — 避免在 toggle 热路径中阻塞主线程
    let persistQueue = DispatchQueue(label: "com.vibefocus.crash-persist", qos: .utility)
    /// 防抖标志：避免快速连续 record 调用时频繁写入磁盘
    var persistScheduled = false
    let persistDebounceInterval: TimeInterval = 0.5

    private init() {}

    func bootstrap() {
        // P-INST-80: 启动崩溃恢复初始化总耗时（启动路径一次性；含 loadState + fileExists/removeItem crashSnapshot + Data(contentsOf stateFileURL) read + atomic write + latestCrashReportURL 目录扫描 + String(contentsOf) crash report read + persistState 写；崩溃报告目录扫描 + IPS JSON parse 在崩溃后首次启动可能耗时；启动归因）。
        let bootstrapStart = Date()
        defer {
            log("CrashContextRecorder.bootstrap finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: bootstrapStart))
            ])
        }
        log("CrashContextRecorder.bootstrap entry", level: .debug)
        let previous = loadState()

        // 如果上次是 cleanExit，不需要保留旧的 crash snapshot
        if let prev = previous, prev.cleanExit {
            let crashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-snapshot.log")
            if FileManager.default.fileExists(atPath: crashSnapshotURL.path) {
                try? FileManager.default.removeItem(at: crashSnapshotURL)
                log("CrashContextRecorder.bootstrap removed stale crash snapshot (previous clean exit)", level: .debug)
            }
        }

        // 如果上次是非 cleanExit，保存 crash snapshot（tail of recent logs）
        if let prev = previous, !prev.cleanExit {
            let crashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-snapshot.log")
            if let snapshotData = try? Data(contentsOf: stateFileURL),
               let snapshotText = String(data: snapshotData, encoding: .utf8) {
                var snapshotLines = snapshotText.split(separator: "\n", omittingEmptySubsequences: false)
                if snapshotLines.count > 500 {
                    snapshotLines = Array(snapshotLines.suffix(500))
                }
                let trimmed = snapshotLines.joined(separator: "\n")
                try? trimmed.data(using: .utf8)?.write(to: crashSnapshotURL, options: .atomic)
                log("CrashContextRecorder.bootstrap saved crash snapshot", level: .debug, fields: ["lineCount": String(snapshotLines.count)])
            }
        }

        // 检查是否有新的 macOS crash report
        if let prev = previous, !prev.cleanExit,
           let reportURL = latestCrashReportURL(),
           let reportText = try? String(contentsOf: reportURL, encoding: .utf8),
           reportText.contains("VibeFocus") {
            let reportName = reportURL.lastPathComponent

            // 仅当报告比上次记录的更新时才处理
            if prev.lastIngestedCrashReport != reportName {
                guard let payload = parseIPSJSONPayloadAndLog(from: reportText) else {
                    log("CrashContextRecorder.bootstrap found crash report but failed to parse IPS payload", level: .warn, fields: ["report": reportName])
                    var newState = SessionState(
                        pid: ProcessInfo.processInfo.processIdentifier,
                        launchedAt: nowString(),
                        cleanExit: false,
                        events: prev.events,
                        lastIngestedCrashReport: reportName
                    )
                    appendEvent("crash_report file=\(reportName) (parse_failed)")
                    state = newState
                    persistState()
                    return
                }

                let captureTime = payload["captureTime"] as? String ?? "unknown"
                let procLaunch = payload["procLaunch"] as? String ?? "unknown"

                let exception = payload["exception"] as? [String: Any]
                let termination = payload["termination"] as? [String: Any]
                let exceptionType = exception?["type"] as? String ?? "unknown"
                let exceptionSignal = exception?["signal"] as? String ?? "unknown"
                let exceptionSubtype = exception?["subtype"] as? String ?? "unknown"
                let terminationIndicator = termination?["indicator"] as? String ?? "unknown"

                var queueName = "unknown"
                var topFrameSymbol = "unknown"
                if let threads = payload["threads"] as? [[String: Any]],
                   let faultingThread = threads.firstIndex(where: { ($0["triggered"] as? Bool) == true }) {
                    let thread = threads[faultingThread]
                    if let frames = thread["frames"] as? [[String: Any]] {
                        let firstFrame = frames.first {
                            ($0["symbol"] as? String)?.isEmpty == false
                        }
                        topFrameSymbol = firstFrame?["symbol"] as? String ?? "unknown"
                    }
                    queueName = thread["queue"] as? String ?? "unknown"
                }

                log("CrashContextRecorder.bootstrap ingested crash report", level: .warn, fields: [
                    "report": reportName,
                    "captureTime": captureTime,
                    "procLaunch": procLaunch,
                    "exceptionType": exceptionType,
                    "exceptionSignal": exceptionSignal,
                    "exceptionSubtype": exceptionSubtype,
                    "terminationIndicator": terminationIndicator,
                    "queue": queueName,
                    "topFrame": topFrameSymbol
                ])

                var newState = SessionState(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    launchedAt: nowString(),
                    cleanExit: false,
                    events: prev.events,
                    lastIngestedCrashReport: reportName
                )
                appendEvent("crash_report file=\(reportName) exception=\(exceptionType) signal=\(exceptionSignal) frame0=\(topFrameSymbol)")
                state?.lastIngestedCrashReport = reportName
                persistState()
                return
            }
        }

        var newState = SessionState(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: nowString(),
            cleanExit: false,
            events: [],
            lastIngestedCrashReport: nil
        )
        // 保留上次最后一条事件作为上下文
        if let lastEvent = previous?.events.last {
            newState.events.append(lastEvent)
        }
        state = newState
        persistState()
        log("CrashContextRecorder.bootstrap exit", level: .debug)
    }

    func record(_ event: String) {
        appendEvent(event)
        // Debounced persist: 不每次都立即写磁盘
        guard !persistScheduled else { return }
        persistScheduled = true
        persistQueue.asyncAfter(deadline: .now() + persistDebounceInterval) { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistScheduled = false
                self?.persistState()
            }
        }
    }

    func markCleanExit() {
        state?.cleanExit = true
        captureRecentLogTail(context: "clean_exit")
        persistState()
        log("CrashContextRecorder.markCleanExit", level: .debug)
    }

    // MARK: - Utility

    func nowString() -> String {
        timestampFormatter.string(from: Date())
    }
}
