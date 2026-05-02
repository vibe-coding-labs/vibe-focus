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

private let logFileURL = URL(fileURLWithPath: "/tmp/vibefocus.log")
private let structuredLogFileURL = URL(fileURLWithPath: "/tmp/vibefocus-events.jsonl")
private let logFileBackupURL = URL(fileURLWithPath: "/tmp/vibefocus.log.1")
private let structuredLogBackupURL = URL(fileURLWithPath: "/tmp/vibefocus-events.jsonl.1")
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

private func sanitizeFieldValue(_ value: String) -> String {
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

private func serializeFields(_ fields: [String: String]) -> String {
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

// 诊断日志（尽量详细）
func logDiagnostics(_ context: String) {
    let bundle = Bundle.main
    let bundleID = bundle.bundleIdentifier ?? "nil"
    let bundlePath = bundle.bundleURL.path
    let execPath = bundle.executableURL?.path ?? "nil"
    let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "nil"
    let build = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "nil"
    let lsui = (bundle.infoDictionary?["LSUIElement"] as? Bool) ?? false

    let processInfo = ProcessInfo.processInfo
    let pid = processInfo.processIdentifier
    let uid = getuid()
    let euid = geteuid()
    let ppid = getppid()
    let os = processInfo.operatingSystemVersionString

    let axOptions = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
    let axTrusted = AXIsProcessTrustedWithOptions(axOptions)

    let currentApp = NSRunningApplication.current
    let currentAppName = currentApp.localizedName ?? "nil"
    let currentBundleID = currentApp.bundleIdentifier ?? "nil"
    let currentBundleURL = currentApp.bundleURL?.path ?? "nil"

    let frontApp = NSWorkspace.shared.frontmostApplication
    let frontName = frontApp?.localizedName ?? "nil"
    let frontPID = frontApp?.processIdentifier ?? 0
    let frontBundleID = frontApp?.bundleIdentifier ?? "nil"
    let frontBundleURL = frontApp?.bundleURL?.path ?? "nil"

    log("=== DIAGNOSTICS (\(context)) ===")
    log("Process pid=\(pid) ppid=\(ppid) uid=\(uid) euid=\(euid) os=\(os)")
    log("Bundle id=\(bundleID) version=\(version) build=\(build) lsui=\(lsui)")
    log("Bundle path=\(bundlePath)")
    log("Executable path=\(execPath)")
    log("Current app name=\(currentAppName) bundleID=\(currentBundleID)")
    log("Current app bundleURL=\(currentBundleURL)")
    log("Frontmost app name=\(frontName) pid=\(frontPID) bundleID=\(frontBundleID)")
    log("Frontmost app bundleURL=\(frontBundleURL)")
    log("AX trusted (prompt=false)=\(axTrusted)")

    if execPath != "nil" {
        logCodesign(targetPath: execPath, label: "Executable codesign")
    }
    logCodesign(targetPath: bundlePath, label: "Bundle codesign")
    logSigningCertificates()
    log("=== END DIAGNOSTICS ===")
}

private func logCodesign(targetPath: String, label: String) {
    guard let result = runProcessForDiagnostics(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", targetPath]) else {
        log("\(label): unable to run codesign")
        return
    }

    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stdout.isEmpty {
        log("\(label) stdout: \(stdout)")
    }
    if !stderr.isEmpty {
        log("\(label) stderr: \(stderr)")
    }
    log("\(label) exit=\(result.exitCode)")
}

func runProcessForDiagnostics(executable: String, arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        log("Failed to run \(executable): \(error.localizedDescription)")
        return nil
    }

    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    return (
        stdout: String(data: output, encoding: .utf8) ?? "",
        stderr: String(data: errorData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
    )
}

func findAppBundlePaths(bundleIdentifier: String) -> [String] {
    let query = "kMDItemCFBundleIdentifier == \"\(bundleIdentifier)\""
    guard let result = runProcessForDiagnostics(executable: "/usr/bin/mdfind", arguments: [query]),
          result.exitCode == 0 else {
        return []
    }

    let paths = result.stdout
        .split(separator: "\n")
        .map { String($0) }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    return Array(Set(paths)).sorted()
}

private func logSigningCertificates() {
    guard let result = runProcessForDiagnostics(
        executable: "/usr/bin/security",
        arguments: ["find-certificate", "-a", "-c", "VibeFocus Local Code Signing", "-Z"]
    ) else {
        log("Signing certs: unable to run security")
        return
    }

    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stdout.isEmpty {
        log("Signing certs stdout: \(stdout)")
    }
    if !stderr.isEmpty {
        log("Signing certs stderr: \(stderr)")
    }
    log("Signing certs exit=\(result.exitCode)")
}

extension Notification.Name {
    static let hotKeyConfigurationDidChange = Notification.Name("HotKeyConfigurationDidChange")
    static let hookServerStateChanged = Notification.Name("ClaudeHookServerStateChanged")
}

struct HotKeyConflict: Equatable {
    let configuration: HotKeyConfiguration
    let reason: String
}

struct HotKeyConfiguration: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let userDefaultsKey = "hotKeyConfiguration"
    static let legacyDefault = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )
    static let `default` = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_Q),
        modifiers: UInt32(controlKey)
    )

    static let knownConflicts: [HotKeyConflict] = [
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), reason: "与 Spotlight 冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)), reason: "与 Finder 搜索冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), reason: "与应用切换器冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey)), reason: "与反向应用切换冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), reason: "与退出应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)), reason: "与关闭窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)), reason: "与最小化窗口冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)), reason: "与隐藏应用冲突"),
        HotKeyConflict(configuration: .init(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey)), reason: "与许多应用的全屏快捷键冲突")
    ]

    var displayString: String {
        modifierDisplay + Self.displayKey(for: keyCode)
    }

    private var modifierDisplay: String {
        var output = ""
        if modifiers & UInt32(controlKey) != 0 { output += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { output += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { output += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { output += "⌘" }
        return output
    }

    func matches(event: NSEvent) -> Bool {
        let eventKeyCode = UInt32(event.keyCode)
        let eventModifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        let matches = eventKeyCode == keyCode && eventModifiers == modifiers
        if !matches {
            log("HotKey match failed: eventKeyCode=\(eventKeyCode) expected=\(keyCode), eventMods=\(eventModifiers) expected=\(modifiers)")
        }
        return matches
    }

    static func from(event: NSEvent) -> HotKeyConfiguration? {
        let modifiers = event.modifierFlags.intersection(.hotKeyRelevantFlags).carbonHotKeyModifiers
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard displayKey(for: keyCode) != "?" else {
            return nil
        }

        return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
    }

    static func displayKey(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case Int(kVK_ANSI_A): return "A"
        case Int(kVK_ANSI_B): return "B"
        case Int(kVK_ANSI_C): return "C"
        case Int(kVK_ANSI_D): return "D"
        case Int(kVK_ANSI_E): return "E"
        case Int(kVK_ANSI_F): return "F"
        case Int(kVK_ANSI_G): return "G"
        case Int(kVK_ANSI_H): return "H"
        case Int(kVK_ANSI_I): return "I"
        case Int(kVK_ANSI_J): return "J"
        case Int(kVK_ANSI_K): return "K"
        case Int(kVK_ANSI_L): return "L"
        case Int(kVK_ANSI_M): return "M"
        case Int(kVK_ANSI_N): return "N"
        case Int(kVK_ANSI_O): return "O"
        case Int(kVK_ANSI_P): return "P"
        case Int(kVK_ANSI_Q): return "Q"
        case Int(kVK_ANSI_R): return "R"
        case Int(kVK_ANSI_S): return "S"
        case Int(kVK_ANSI_T): return "T"
        case Int(kVK_ANSI_U): return "U"
        case Int(kVK_ANSI_V): return "V"
        case Int(kVK_ANSI_W): return "W"
        case Int(kVK_ANSI_X): return "X"
        case Int(kVK_ANSI_Y): return "Y"
        case Int(kVK_ANSI_Z): return "Z"
        case Int(kVK_ANSI_0): return "0"
        case Int(kVK_ANSI_1): return "1"
        case Int(kVK_ANSI_2): return "2"
        case Int(kVK_ANSI_3): return "3"
        case Int(kVK_ANSI_4): return "4"
        case Int(kVK_ANSI_5): return "5"
        case Int(kVK_ANSI_6): return "6"
        case Int(kVK_ANSI_7): return "7"
        case Int(kVK_ANSI_8): return "8"
        case Int(kVK_ANSI_9): return "9"
        case Int(kVK_Space): return "Space"
        case Int(kVK_Return): return "Return"
        case Int(kVK_Escape): return "Esc"
        case Int(kVK_Delete): return "Delete"
        case Int(kVK_ForwardDelete): return "Fn⌫"
        case Int(kVK_Tab): return "Tab"
        case Int(kVK_LeftArrow): return "←"
        case Int(kVK_RightArrow): return "→"
        case Int(kVK_UpArrow): return "↑"
        case Int(kVK_DownArrow): return "↓"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F5): return "F5"
        case Int(kVK_F6): return "F6"
        case Int(kVK_F7): return "F7"
        case Int(kVK_F8): return "F8"
        case Int(kVK_F9): return "F9"
        case Int(kVK_F10): return "F10"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        default: return "?"
        }
    }
}

// MARK: - Crash Signal Handler & Snapshot Buffer

private let crashSnapshotFD: Int32 = {
    let path = "/tmp/vibefocus-crash-snapshot.log"
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}()

private final class CrashSnapshotBuffer: @unchecked Sendable {
    static let shared = CrashSnapshotBuffer()

    private let bufferA = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private let bufferB = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private var activeBuffer: UnsafeMutablePointer<CChar>
    private var activeLength: Int = 0
    private var activeIsA = true
    private let lock = NSLock()

    private init() {
        activeBuffer = bufferA
        bufferA.initialize(repeating: 0, count: 16384)
        bufferB.initialize(repeating: 0, count: 16384)
    }

    deinit {
        bufferA.deallocate()
        bufferB.deallocate()
    }

    func update(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
        lock.lock()
        let buf = activeBuffer
        let written = block(buf, 16384 - 1)
        activeLength = max(0, written)
        buf.advanced(by: activeLength).pointee = 0
        activeIsA = !activeIsA
        activeBuffer = activeIsA ? bufferA : bufferB
        activeLength = 0
        activeBuffer.pointee = 0
        lock.unlock()
    }

    func readInactiveBuffer() -> (ptr: UnsafeMutablePointer<CChar>, len: Int) {
        lock.lock()
        let buf = activeIsA ? bufferB : bufferA
        let len = activeLength
        lock.unlock()
        return (buf, len)
    }
}

private func crashSignalHandler(_ sig: Int32) {
    let (buf, len) = CrashSnapshotBuffer.shared.readInactiveBuffer()

    var sigMsg = "FATAL SIGNAL \(sig) ("
    switch sig {
    case SIGSEGV: sigMsg += "SIGSEGV"
    case SIGABRT: sigMsg += "SIGABRT"
    case SIGBUS: sigMsg += "SIGBUS"
    case SIGFPE: sigMsg += "SIGFPE"
    case SIGILL: sigMsg += "SIGILL"
    case SIGTRAP: sigMsg += "SIGTRAP"
    default: sigMsg += "UNKNOWN"
    }
    sigMsg += ") caught at "
    var now = time(nil)
    var tm = tm()
    localtime_r(&now, &tm)
    var timeBuf = [CChar](repeating: 0, count: 32)
    strftime(&timeBuf, 32, "%Y-%m-%dT%H:%M:%S", &tm)
    sigMsg += String(cString: timeBuf)
    sigMsg += "\n\n=== PRE-CRASH STATE ===\n"

    var iov = [iovec](repeating: iovec(), count: 4)
    var sigData = [CChar](repeating: 0, count: 512)
    sigMsg.withCString { ptr in
        var idx = 0
        while idx < 511 && ptr[idx] != 0 {
            sigData[idx] = ptr[idx]
            idx += 1
        }
        sigData[idx] = 0
    }
    iov[0].iov_base = UnsafeMutableRawPointer(&sigData)
    iov[0].iov_len = strlen(&sigData)

    let nl = "\n=== END PRE-CRASH STATE ===\n"
    var nlData = [CChar](repeating: 0, count: 32)
    nl.withCString { ptr in
        var idx = 0
        while idx < 31 && ptr[idx] != 0 { nlData[idx] = ptr[idx]; idx += 1 }
        nlData[idx] = 0
    }

    if len > 0 {
        iov[1].iov_base = UnsafeMutableRawPointer(mutating: buf)
        iov[1].iov_len = len
        iov[2].iov_base = UnsafeMutableRawPointer(&nlData)
        iov[2].iov_len = strlen(&nlData)
        writev(crashSnapshotFD, iov, 3)
    } else {
        iov[1].iov_base = UnsafeMutableRawPointer(&nlData)
        iov[1].iov_len = strlen(&nlData)
        writev(crashSnapshotFD, iov, 2)
    }

    close(crashSnapshotFD)
    _exit(128 + sig)
}

func installCrashSignalHandlers() {
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
        signal(sig, crashSignalHandler)
    }
    signal(SIGTRAP, crashSignalHandler)
}

func installAtExitHandler() {
    atexit {
        let msg = "VibeFocus exiting via atexit (likely normal termination)\n"
        msg.withCString { ptr in
            let fd = open("/tmp/vibefocus-crash-snapshot.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd != -1 {
                write(fd, ptr, strlen(ptr))
                close(fd)
            }
        }
    }
}

func updateCrashSnapshot(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
    CrashSnapshotBuffer.shared.update(block)
}

@MainActor
func updateCrashSnapshotFromRuntime() {
    updateCrashSnapshot { buf, capacity in
        var pos = 0
        func append(_ str: String) {
            str.withCString { ptr in
                var i = 0
                while ptr[i] != 0 && pos < capacity - 1 {
                    buf[pos] = ptr[i]
                    pos += 1
                    i += 1
                }
            }
        }
        func appendField(_ key: String, _ value: String) {
            append("\(key)=\(value) ")
        }

        append("pid=\(ProcessInfo.processInfo.processIdentifier)")
        append(" ppid=\(getppid())")

        let axOptions = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)
        appendField("axTrusted", String(axTrusted))

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            appendField("frontPID", String(frontApp.processIdentifier))
            appendField("frontBundleID", frontApp.bundleIdentifier ?? "nil")
        }

        appendField("screenCount", String(NSScreen.screens.count))

        let wm = WindowManager.shared
        appendField("savedStates", String(wm.savedWindowStates.count))
        appendField("hasToken", String(wm.lastWindowToken != nil))
        appendField("hasFrame", String(wm.lastWindowFrame != nil))
        appendField("hasTarget", String(wm.lastTargetFrame != nil))

        if let token = wm.lastWindowToken {
            appendField("tokenPID", String(token.pid))
            appendField("tokenWinID", String(describing: token.windowID))
            appendField("tokenBundleID", token.bundleIdentifier ?? "nil")
        }
        if let frame = wm.lastWindowFrame {
            appendField("origFrame", "(\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height))")
        }
        if let target = wm.lastTargetFrame {
            appendField("targetFrame", "(\(target.origin.x),\(target.origin.y),\(target.width),\(target.height))")
        }
        appendField("srcSpace", String(describing: wm.lastSourceSpaceIndex))
        appendField("srcYabaiDisp", String(describing: wm.lastSourceYabaiDisplayIndex))

        let hkm = HotKeyManager.shared
        appendField("hotkey", hkm.currentHotKey.displayString)
        appendField("axGranted", String(hkm.accessibilityGranted))

        let hookServer = ClaudeHookServer.shared
        appendField("hookRunning", String(hookServer.isRunning))

        appendField("eventCount", String(wm.savedWindowStates.count))

        buf[pos] = 0
        return pos
    }
}

@MainActor
func logRuntimeStateSnapshot(context: String) {
    let wm = WindowManager.shared
    let hkm = HotKeyManager.shared
    let hookServer = ClaudeHookServer.shared

    var fields: [String: String] = [
        "context": context,
        "savedStates": String(wm.savedWindowStates.count),
        "hasToken": String(wm.lastWindowToken != nil),
        "hasFrame": String(wm.lastWindowFrame != nil),
        "hasTarget": String(wm.lastTargetFrame != nil),
        "hasElement": String(wm.lastWindowElement != nil),
        "srcSpace": String(describing: wm.lastSourceSpaceIndex),
        "srcYabaiDisp": String(describing: wm.lastSourceYabaiDisplayIndex),
        "srcDispSpace": String(describing: wm.lastSourceDisplaySpaceIndex),
        "hotkey": hkm.currentHotKey.displayString,
        "axGranted": String(hkm.accessibilityGranted),
        "hookRunning": String(hookServer.isRunning),
        "screenCount": String(NSScreen.screens.count),
        "frontmost": frontmostAppDescriptor()
    ]

    if let token = wm.lastWindowToken {
        fields["tokenPID"] = String(token.pid)
        fields["tokenWinID"] = String(describing: token.windowID)
        fields["tokenBundleID"] = token.bundleIdentifier ?? "nil"
        fields["tokenTitle"] = truncateForLog(token.title ?? "", limit: 60)
    }
    if let frame = wm.lastWindowFrame {
        fields["origFrame"] = "(\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height))"
    }
    if let target = wm.lastTargetFrame {
        fields["targetFrame"] = "(\(target.origin.x),\(target.origin.y),\(target.width),\(target.height))"
    }

    if !wm.savedWindowStates.isEmpty {
        let summaries = wm.savedWindowStates.suffix(5).map { state in
            "\(state.id.prefix(8))..pid=\(state.pid)win=\(String(describing: state.windowID))"
        }
        fields["recentStates"] = summaries.joined(separator: ",")
    }

    log("[STATE_SNAPSHOT] \(context)", level: .debug, fields: fields)
}

extension NSEvent.ModifierFlags {
    static let hotKeyRelevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var carbonHotKeyModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
