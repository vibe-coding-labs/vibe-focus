// CrashContextRecorder+IO.swift
// VibeFocus — Crash report 解析与文件 I/O 操作
// 从 CrashContextRecorder.swift 中提取

import Foundation

extension CrashContextRecorder {

    // MARK: - IPS Report Parsing

    static func parseIPSJSONPayload(from reportText: String) -> [String: Any]? {
        let lines = reportText.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        let payloadText = lines.dropFirst().joined(separator: "\n")
        guard let data = payloadText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else { return nil }
        return payload
    }

    func parseIPSJSONPayloadAndLog(from reportText: String) -> [String: Any]? {
        log("CrashContextRecorder.parseIPSJSONPayload entry", level: .debug, fields: ["textLength": String(reportText.count)])
        let result = Self.parseIPSJSONPayload(from: reportText)
        if let result {
            log("CrashContextRecorder.parseIPSJSONPayload exit", level: .debug, fields: ["keyCount": String(result.count)])
        } else {
            log("CrashContextRecorder.parseIPSJSONPayload failed", level: .debug)
        }
        return result
    }

    // MARK: - Crash Report Discovery

    func latestCrashReportURL() -> URL? {
        log("CrashContextRecorder.latestCrashReportURL entry", level: .debug, fields: ["directory": diagnosticReportsDirectory.path])
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: diagnosticReportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            log("CrashContextRecorder.latestCrashReportURL cannot read directory", level: .debug)
            return nil
        }

        let reports = urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("VibeFocus-") && name.hasSuffix(".ips")
        }
        guard !reports.isEmpty else {
            log("CrashContextRecorder.latestCrashReportURL no reports found", level: .debug)
            return nil
        }

        return reports.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    // MARK: - State Persistence

    func loadState() -> SessionState? {
        log("CrashContextRecorder.loadState entry", level: .debug, fields: ["path": stateFileURL.path])
        guard let data = try? Data(contentsOf: stateFileURL),
              let loaded = try? JSONDecoder().decode(SessionState.self, from: data) else {
            log("CrashContextRecorder.loadState no state file or decode failed", level: .debug)
            return nil
        }
        log("CrashContextRecorder.loadState exit", level: .debug, fields: ["pid": String(loaded.pid), "cleanExit": String(loaded.cleanExit), "eventCount": String(loaded.events.count)])
        return loaded
    }

    func persistState() {
        guard let state else {
            log("CrashContextRecorder.persistState no state to persist", level: .debug)
            return
        }
        log("CrashContextRecorder.persistState entry", level: .debug, fields: ["eventCount": String(state.events.count), "cleanExit": String(state.cleanExit)])
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

    func appendEvent(_ event: String) {
        guard state != nil else {
            log("CrashContextRecorder.appendEvent no state, skipping", level: .debug)
            return
        }
        let line = "\(nowString()) \(event)"
        state?.events.append(line)
        if let count = state?.events.count, count > maxEvents {
            state?.events.removeFirst(count - maxEvents)
            log("CrashContextRecorder.appendEvent trimmed events", level: .debug, fields: ["removedCount": String(count - maxEvents)])
        }
    }

    // MARK: - Log Tail Capture

    func captureRecentLogTail(context: String) {
        log("CrashContextRecorder.captureRecentLogTail entry", level: .debug, fields: ["context": context])
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

    func captureTail(
        sourceURL: URL,
        outputURL: URL,
        lineLimit: Int,
        context: String,
        label: String
    ) {
        log("CrashContextRecorder.captureTail entry", level: .debug, fields: ["source": sourceURL.path, "output": outputURL.path, "label": label, "lineLimit": String(lineLimit)])
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
