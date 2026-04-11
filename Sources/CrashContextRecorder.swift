import Foundation

@MainActor
final class CrashContextRecorder {
    static let shared = CrashContextRecorder()

    private struct SessionState: Codable {
        var pid: Int32
        var launchedAt: String
        var cleanExit: Bool
        var events: [String]
        var lastIngestedCrashReport: String?
    }

    private let stateFileURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-context.json")
    private let plainLogFileURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
    private let structuredLogFileURL = URL(fileURLWithPath: "/tmp/vibefocus-events.jsonl")
    private let plainCrashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-tail.log")
    private let structuredCrashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-tail-events.jsonl")
    private let maxEvents = 300
    private let plainTailLineLimit = 500
    private let structuredTailLineLimit = 1200
    private let diagnosticReportsDirectory = URL(
        fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports"),
        isDirectory: true
    )

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var state: SessionState?

    private init() {}

    func bootstrap() {
        let previous = loadState()
        if let previous, !previous.cleanExit {
            log("[CRASH_CONTEXT] Detected unclean previous exit (pid=\(previous.pid), launchedAt=\(previous.launchedAt))")
            if let lastEvent = previous.events.last {
                log("[CRASH_CONTEXT] Last event before exit: \(lastEvent)")
            }
            captureRecentLogTail(context: "unclean_exit")
        }

        var newState = SessionState(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: nowString(),
            cleanExit: false,
            events: [],
            lastIngestedCrashReport: previous?.lastIngestedCrashReport
        )

        state = newState
        appendEvent("launch pid=\(newState.pid) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        ingestLatestCrashReportIfNeeded()
        // Ingest may update fields; persist final state.
        if let updated = state {
            newState = updated
        }
        state = newState
        persistState()
        log(
            "[CRASH_CONTEXT] bootstrap complete",
            fields: [
                "pid": String(newState.pid),
                "launchedAt": newState.launchedAt,
                "stateFile": stateFileURL.path
            ]
        )
    }

    func record(_ event: String) {
        appendEvent(event)
        persistState()
        log(
            "[CRASH_CONTEXT] event",
            fields: [
                "event": truncateForLog(event, limit: 360)
            ]
        )
    }

    func markCleanExit() {
        guard state != nil else {
            return
        }
        appendEvent("clean_exit")
        state?.cleanExit = true
        persistState()
        log("[CRASH_CONTEXT] Marked clean exit")
    }

    private func ingestLatestCrashReportIfNeeded() {
        guard let latestReport = latestCrashReportURL() else {
            return
        }
        let reportName = latestReport.lastPathComponent
        if state?.lastIngestedCrashReport == reportName {
            return
        }

        guard let reportText = try? String(contentsOf: latestReport, encoding: .utf8),
              let payload = parseIPSJSONPayload(from: reportText) else {
            appendEvent("crash_report_parse_failed file=\(reportName)")
            state?.lastIngestedCrashReport = reportName
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
        if let faultingThread = payload["faultingThread"] as? Int,
           let threads = payload["threads"] as? [[String: Any]],
           faultingThread >= 0,
           faultingThread < threads.count {
            let thread = threads[faultingThread]
            queueName = thread["queue"] as? String ?? "unknown"
            if let frames = thread["frames"] as? [[String: Any]],
               let firstFrame = frames.first {
                topFrameSymbol = firstFrame["symbol"] as? String ?? "unknown"
            }
        }

        log("[CRASH_CONTEXT] Ingested crash report: \(reportName)")
        log("[CRASH_CONTEXT] capture=\(captureTime) launch=\(procLaunch)")
        log("[CRASH_CONTEXT] exception=\(exceptionType) signal=\(exceptionSignal) subtype=\(exceptionSubtype)")
        log("[CRASH_CONTEXT] termination=\(terminationIndicator) queue=\(queueName) frame0=\(topFrameSymbol)")

        appendEvent("crash_report file=\(reportName) exception=\(exceptionType) signal=\(exceptionSignal) frame0=\(topFrameSymbol)")
        state?.lastIngestedCrashReport = reportName
        persistState()
    }

    private func parseIPSJSONPayload(from reportText: String) -> [String: Any]? {
        let lines = reportText.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else {
            return nil
        }
        let payloadText = lines.dropFirst().joined(separator: "\n")
        guard let data = payloadText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func latestCrashReportURL() -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diagnosticReportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let reports = urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("VibeFocusHotkeys-") && name.hasSuffix(".ips")
        }
        guard !reports.isEmpty else {
            return nil
        }

        return reports.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func loadState() -> SessionState? {
        guard let data = try? Data(contentsOf: stateFileURL),
              let loaded = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return nil
        }
        return loaded
    }

    private func persistState() {
        guard let state else {
            return
        }
        guard let data = try? JSONEncoder().encode(state) else {
            log("[CRASH_CONTEXT] Failed to encode state", level: .error)
            return
        }
        do {
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            log(
                "[CRASH_CONTEXT] Failed to persist state",
                level: .error,
                fields: [
                    "path": stateFileURL.path,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func appendEvent(_ event: String) {
        guard state != nil else {
            return
        }
        let line = "\(nowString()) \(event)"
        state?.events.append(line)
        if let count = state?.events.count, count > maxEvents {
            state?.events.removeFirst(count - maxEvents)
        }
    }

    private func nowString() -> String {
        timestampFormatter.string(from: Date())
    }

    private func captureRecentLogTail(context: String) {
        captureTail(
            sourceURL: plainLogFileURL,
            outputURL: plainCrashSnapshotURL,
            lineLimit: plainTailLineLimit,
            context: context,
            label: "plain"
        )
        captureTail(
            sourceURL: structuredLogFileURL,
            outputURL: structuredCrashSnapshotURL,
            lineLimit: structuredTailLineLimit,
            context: context,
            label: "structured"
        )
    }

    private func captureTail(
        sourceURL: URL,
        outputURL: URL,
        lineLimit: Int,
        context: String,
        label: String
    ) {
        guard let data = try? Data(contentsOf: sourceURL),
              let content = String(data: data, encoding: .utf8) else {
            log(
                "[CRASH_CONTEXT] tail snapshot skipped: source unavailable",
                level: .warn,
                fields: [
                    "context": context,
                    "label": label,
                    "source": sourceURL.path
                ]
            )
            return
        }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lineLimit)
            .joined(separator: "\n")

        guard let tailData = lines.data(using: .utf8) else {
            return
        }

        do {
            try tailData.write(to: outputURL, options: .atomic)
            log(
                "[CRASH_CONTEXT] saved tail snapshot",
                fields: [
                    "context": context,
                    "label": label,
                    "source": sourceURL.path,
                    "output": outputURL.path,
                    "lineLimit": String(lineLimit)
                ]
            )
        } catch {
            log(
                "[CRASH_CONTEXT] failed to save tail snapshot",
                level: .error,
                fields: [
                    "context": context,
                    "label": label,
                    "source": sourceURL.path,
                    "output": outputURL.path,
                    "error": error.localizedDescription
                ]
            )
        }
    }
}
