import AppKit
import ApplicationServices.HIServices
import Carbon
import Darwin
import Foundation

// MARK: - Crash Signal Handler & Snapshot Buffer

private let crashSnapshotFD: Int32 = {
    let path = "/tmp/vibefocus-crash-snapshot.log"
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}()

// 致命信号记录的独立文件路径与 FD（O_APPEND 不截断）。
// 背景：crashSnapshotFD 启动时 O_TRUNC 会清空 signal handler 写入的 FATAL SIGNAL 详情，
// 导致崩溃信号类型/时刻永久丢失（屏幕热插拔崩溃 bug 因此只能靠日志推断，拿不到信号类型）。
// crashFatalFD 用 O_APPEND，下次启动不会覆盖；archivePreviousCrashFatalIfNeeded()
// 在启动期读取非空 fatal 文件 → log + 归档到 ~/Library/Logs/VibeFocus/ → 清空。
private let crashFatalPath = "/tmp/vibefocus-crash-fatal.log"
private let crashFatalFD: Int32 = {
    return open(crashFatalPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
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

    // 额外写入独立 fatal FD（O_APPEND 不截断），下次启动 archivePreviousCrashFatalIfNeeded
    // 会读取归档。修复根因 #3：crashSnapshotFD 启动时 O_TRUNC 会覆盖此处写的 FATAL SIGNAL。
    // 仅 writev（async-signal-safe），复用已构造的 iov。不 close（writev 返回数据已在内核 page
    // cache，紧随的 _exit 不影响落盘）。
    if crashFatalFD >= 0 {
        if len > 0 {
            writev(crashFatalFD, iov, 3)
        } else {
            writev(crashFatalFD, iov, 2)
        }
    }

    close(crashSnapshotFD)
    _exit(128 + sig)
}

func installCrashSignalHandlers() {
    // P-INST-247: 崩溃信号处理器注册耗时（6x signal syscall 注册 SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGTRAP 处理器；应用启动调用，崩溃时处理器执行写崩溃快照；与 installAtExitHandler P-INST-193 同类启动注册；slow-op ≥5ms warn）。
    // 启动期先归档上次的致命信号记录（若有），再触发 crashFatalFD 的 open。
    // 顺序重要：归档可能 move 掉旧 fatal 文件，必须在 open（创建新文件）之前完成。
    archivePreviousCrashFatalIfNeeded()
    _ = crashFatalFD  // 触发 lazy open（O_CREAT | O_APPEND，不截断）
    let icshStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: icshStart)
        if durMs >= 5 { log("[CrashContext] installCrashSignalHandlers slow", level: .warn, fields: ["durationMs": String(durMs)]) }
    }
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
        signal(sig, crashSignalHandler)
    }
    signal(SIGTRAP, crashSignalHandler)
}

func installAtExitHandler() {
    // P-INST-193: atexit handler 注册耗时（atexit syscall 注册退出回调；应用启动调用，注册的回调在进程退出时执行 open/write/close 文件 I/O 写崩溃快照日志）。
    let iaeStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: iaeStart)
        if durMs >= 5 { log("[CrashContext] installAtExitHandler slow", level: .warn, fields: ["durationMs": String(durMs)]) }
    }
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

/// 启动期：归档上次的致命信号记录（若存在）。
///
/// 读取 crashFatalPath，若非空说明上次崩溃（signal handler 向该文件写了 FATAL SIGNAL），
/// 写入应用正常日志后 move 到 ~/Library/Logs/VibeFocus/crash-fatal-<timestamp>.log 保留，
/// 再清空原文件。修复根因 #3：此前 signal handler 写的 FATAL SIGNAL 被 crashSnapshotFD
/// 的启动 O_TRUNC 覆盖，导致崩溃信号类型永久丢失。
///
/// 此函数仅在启动期（installCrashSignalHandlers）调用，非 signal handler 路径，
/// 可自由使用 FileManager / Date / log 等非 async-signal-safe API。
private func archivePreviousCrashFatalIfNeeded() {
    let fm = FileManager.default
    guard fm.fileExists(atPath: crashFatalPath) else { return }
    guard let attrs = try? fm.attributesOfItem(atPath: crashFatalPath),
          let size = attrs[.size] as? Int, size > 0 else {
        // 空文件：直接删除，确保干净起点。
        try? fm.removeItem(atPath: crashFatalPath)
        return
    }

    let content = (try? String(contentsOfFile: crashFatalPath, encoding: .utf8)) ?? "(unreadable)"
    // 写入应用正常日志，让常规日志检索能找到上次崩溃的信号类型（无需翻 /tmp）
    log("Previous crash fatal record detected, archiving", level: .error, fields: [
        "crashFatal": content
    ])

    // 归档到应用日志目录（带时间戳，避免被下次覆盖）
    let logDir = NSHomeDirectory() + "/Library/Logs/VibeFocus"
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd-HHmmss"
    df.locale = Locale(identifier: "en_US_POSIX")
    let archivePath = "\(logDir)/crash-fatal-\(df.string(from: Date())).log"
    if fm.fileExists(atPath: archivePath) {
        try? fm.removeItem(atPath: archivePath)
    }
    do {
        try fm.moveItem(atPath: crashFatalPath, toPath: archivePath)
    } catch {
        // move 失败则直接清空原文件，避免下次启动重复归档同一记录
        try? fm.removeItem(atPath: crashFatalPath)
    }
}

func updateCrashSnapshot(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
    CrashSnapshotBuffer.shared.update(block)
}

@MainActor
func updateCrashSnapshotFromRuntime() {
    // P-INST-117: 运行时崩溃快照更新耗时（NSWorkspace.frontmostApplication + NSScreen.screens.count + WindowManager/HotKeyManager 状态读取 + 写入 crash snapshot buffer；toggle 入口 WindowManager+Toggle:32 + hook 请求 ClaudeHookServer:137 双热路径调用，每次 toggle/hook 都执行）。
    let ucsrStart = Date()
    defer {
        log("CrashContext.updateCrashSnapshotFromRuntime finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: ucsrStart))
        ])
    }
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

        // 用 HotKeyManager 缓存的 accessibilityGranted 代替同步 AXIsProcessTrustedWithOptions。
        // 后者是同步权限服务查询，WindowServer 繁忙时可达数百 ms，每次 toggle 调用会阻塞入口。
        // AX 权限状态运行期间不变，缓存值足够用于 crash 诊断。
        let hkm = HotKeyManager.shared
        appendField("axTrusted", String(hkm.accessibilityGranted))

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            appendField("frontPID", String(frontApp.processIdentifier))
            appendField("frontBundleID", frontApp.bundleIdentifier ?? "nil")
        }

        appendField("screenCount", String(NSScreen.screens.count))

        let wm = WindowManager.shared

        appendField("hotkey", hkm.currentHotKey.displayString)
        appendField("axGranted", String(hkm.accessibilityGranted))

        let hookServer = ClaudeHookServer.shared
        appendField("hookRunning", String(hookServer.isRunning))

        appendField("eventCount", "0")

        buf[pos] = 0
        return pos
    }
}

@MainActor
func logRuntimeStateSnapshot(context: String) {
    // P-INST-118: 运行时状态快照日志耗时（WindowManager/HotKeyManager/ClaudeHookServer 状态读取 + 字段字典构造 + log 写；toggle 入口 WindowManager+Toggle:33 + hook 请求 ClaudeHookServer:138 双热路径调用，每次 toggle/hook 都执行）。
    let lrssStart = Date()
    defer {
        log("CrashContext.logRuntimeStateSnapshot finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: lrssStart)),
            "context": context
        ])
    }
    let wm = WindowManager.shared
    let hkm = HotKeyManager.shared
    let hookServer = ClaudeHookServer.shared

    var fields: [String: String] = [
        "context": context,
        "hotkey": hkm.currentHotKey.displayString,
        "axGranted": String(hkm.accessibilityGranted),
        "hookRunning": String(hookServer.isRunning),
        "screenCount": String(NSScreen.screens.count),
        "frontmost": frontmostAppDescriptor()
    ]

    log("[STATE_SNAPSHOT] \(context)", level: .debug, fields: fields)
}
