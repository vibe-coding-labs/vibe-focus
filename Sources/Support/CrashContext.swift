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
