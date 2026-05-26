import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation
import Darwin

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

private let logDirectoryURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VibeFocus", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private let logFileURL = logDirectoryURL.appendingPathComponent("vibefocus.log")
private let structuredLogFileURL = logDirectoryURL.appendingPathComponent("vibefocus-events.jsonl")
private let logFileBackupURL = logDirectoryURL.appendingPathComponent("vibefocus.log.1")
private let structuredLogBackupURL = logDirectoryURL.appendingPathComponent("vibefocus-events.jsonl.1")
private let logMaxSizeBytes: UInt64 = 25 * 1024 * 1024
private let logWriteQueue = DispatchQueue(label: "vibefocus.log.write", qos: .utility)
private let logSessionID = UUID().uuidString
private final class LogTimestampFormatter: @unchecked Sendable {
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func nowString() -> String {
        formatter.string(from: Date())
    }
}

private let logTimestampFormatter = LogTimestampFormatter()
private let verboseLoggingEnabled: Bool = {
    let value = ProcessInfo.processInfo.environment["VIBEFOCUS_VERBOSE_LOGS"]?.lowercased() ?? ""
    return value == "1" || value == "true" || value == "yes"
}()

private final class LogSequenceGenerator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vibefocus.log.sequence", qos: .userInitiated)
    private var value: UInt64 = 0

    func next() -> UInt64 {
        queue.sync {
            value += 1
            return value
        }
    }
}

private let logSequenceGenerator = LogSequenceGenerator()

private func nextLogSequence() -> UInt64 {
    logSequenceGenerator.next()
}

private func threadID() -> UInt64 {
    UInt64(pthread_mach_thread_np(pthread_self()))
}

func sanitizeFieldValue(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\"", with: "\\\"")
    if escaped.contains(" ") || escaped.contains("=") || escaped.contains("\"") {
        return "\"\(escaped)\""
    }
    return escaped
}

func serializeFields(_ fields: [String: String]) -> String {
    guard !fields.isEmpty else {
        return ""
    }
    let pairs = fields
        .filter { !$0.key.isEmpty }
        .sorted { $0.key < $1.key }
        .map { key, value in
            "\(key)=\(sanitizeFieldValue(value))"
        }
    guard !pairs.isEmpty else {
        return ""
    }
    return " " + pairs.joined(separator: " ")
}

private func shouldEmitLog(_ message: String, level: LogLevel) -> Bool {
    // 默认输出所有级别日志（包括 debug），方便排查问题
    return true
}

private func rotateLogIfNeeded(fileURL: URL, backupURL: URL, maxBytes: UInt64) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
          let sizeNumber = attributes[.size] as? NSNumber else {
        return
    }
    guard sizeNumber.uint64Value >= maxBytes else {
        return
    }
    try? FileManager.default.removeItem(at: backupURL)
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
}

private func appendData(_ data: Data, to fileURL: URL) {
    if FileManager.default.fileExists(atPath: fileURL.path),
       let handle = try? FileHandle(forWritingTo: fileURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: fileURL)
    }
}

func makeOperationID(prefix: String = "op") -> String {
    let sequence = nextLogSequence()
    let normalizedPrefix = prefix.isEmpty ? "op" : prefix
    return "\(normalizedPrefix)-\(String(format: "%08llu", sequence))"
}

func elapsedMilliseconds(since startAt: Date) -> Int {
    max(0, Int((Date().timeIntervalSince(startAt) * 1000).rounded()))
}

func truncateForLog(_ text: String, limit: Int = 260) -> String {
    guard text.count > limit else {
        return text
    }
    let endIndex = text.index(text.startIndex, offsetBy: limit)
    return "\(text[..<endIndex])..."
}

func frontmostAppDescriptor() -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        return "nil"
    }
    let bundleID = app.bundleIdentifier ?? "nil"
    let name = app.localizedName ?? "nil"
    return "\(bundleID)#\(app.processIdentifier):\(name)"
}

@discardableResult
func logOperationDuration(
    _ name: String,
    startedAt: Date,
    operationID: String? = nil,
    warnThresholdMs: Int = 300,
    fields: [String: String] = [:]
) -> Int {
    let durationMs = elapsedMilliseconds(since: startedAt)
    var merged = fields
    if let operationID {
        merged["op"] = operationID
    }
    merged["durationMs"] = String(durationMs)
    let level: LogLevel = durationMs >= warnThresholdMs ? .warn : .info
    log(name, level: level, fields: merged)
    return durationMs
}

// 全局日志函数（支持结构化字段）
func log(_ message: String, level: LogLevel = .info, fields: [String: String] = [:]) {
    guard shouldEmitLog(message, level: level) else {
        return
    }

    let sequence = nextLogSequence()
    let pid = ProcessInfo.processInfo.processIdentifier
    let tid = threadID()
    let normalizedMessage = message
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    var enrichedFields = fields
    enrichedFields["pid"] = String(pid)
    enrichedFields["tid"] = String(tid)
    enrichedFields["seq"] = String(sequence)
    let renderedMessage = "[\(level.rawValue)] \(normalizedMessage)\(serializeFields(enrichedFields))"

    NSLog("[VibeFocus] %@", renderedMessage)

    logWriteQueue.async {
        let timestamp = logTimestampFormatter.nowString()

        rotateLogIfNeeded(fileURL: logFileURL, backupURL: logFileBackupURL, maxBytes: logMaxSizeBytes)
        rotateLogIfNeeded(fileURL: structuredLogFileURL, backupURL: structuredLogBackupURL, maxBytes: logMaxSizeBytes)

        let line = "[\(timestamp)] \(renderedMessage)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        appendData(data, to: logFileURL)

        var structuredPayload: [String: Any] = [
            "ts": timestamp,
            "session": logSessionID,
            "level": level.rawValue,
            "message": normalizedMessage,
            "seq": sequence,
            "pid": pid,
            "tid": tid
        ]
        if !fields.isEmpty {
            structuredPayload["fields"] = fields
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: structuredPayload, options: [.sortedKeys]),
           let jsonLine = String(data: jsonData, encoding: .utf8)?.appending("\n"),
           let jsonLineData = jsonLine.data(using: .utf8) {
            appendData(jsonLineData, to: structuredLogFileURL)
        }
    }
}

