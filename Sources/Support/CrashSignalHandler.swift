import Foundation
import Darwin

// MARK: - 崩溃信号层（signal-safe 记录 + 安装 + 归档）
// 崩溃诊断体系三层之一（2026-08-31 从 CrashContext.swift 拆分并补架构说明，行为不变）。
//
// ## 崩溃诊断体系全景（原 CrashContext.swift + CrashContextRecorder.swift）
// 1. **信号层（本文件）**：POSIX 信号处理器，仅用 async-signal-safe API 把
//    PRE-CRASH STATE（CrashSnapshotBuffer 双缓冲）与信号类型写 /tmp 文件，
//    然后 SIG_DFL + raise 交还系统生成带堆栈的 .ips（2026-08-31 修复，此前 _exit
//    绕过 CrashReporter 导致崩溃无堆栈可查）。
// 2. **事件记录层（CrashContextRecorder.swift）**：@MainActor 事件环形缓冲
//    （/tmp/vibefocus-crash-context.json）+ 启动时消费 /tmp fatal 文件与 .ips；
//    另含 .ips 解析（+IO.swift）。
// 3. **运行时快照层（CrashRuntimeSnapshot.swift）**：toggle/hook 双热路径入口调用，
//    把进程关键状态（AX 权限/前台 app/屏幕数）刷进 CrashSnapshotBuffer，
//    供信号层崩溃时落盘。
//
// ## 历史坑（注释保留原因）
// - crashSnapshotFD 启动 O_TRUNC 会清空 signal handler 写的 FATAL SIGNAL 详情
//   → 崩溃信号类型永久丢失（根因 #3），故 fatal 单独用 O_APPEND 的 crashFatalFD；
// - CrashSnapshotBuffer 曾因双缓冲长度丢失致 PRE-CRASH STATE 永远为空（7109ae5 修复）。

// MARK: - Fatal 记录文件描述符

private let crashSnapshotFD: Int32 = {
    // 路径按进程角色隔离（DiagnosticPath.swift）：TestRunner 等派生二进制写各自
    // 后缀文件，不再与主应用共享 /tmp 现场（2026-09-06 僵尸记录污染实证）。
    return open(diagnosticSnapshotLogPath(), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}()

// 致命信号记录的独立文件路径与 FD（O_APPEND 不截断）。
// 背景：crashSnapshotFD 启动时 O_TRUNC 会清空 signal handler 写入的 FATAL SIGNAL 详情，
// 导致崩溃信号类型/时刻永久丢失（屏幕热插拔崩溃 bug 因此只能靠日志推断，拿不到信号类型）。
// crashFatalFD 用 O_APPEND，下次启动不会覆盖；archivePreviousCrashFatalIfNeeded()
// 在启动期读取非空 fatal 文件 → log + 归档到 ~/Library/Logs/VibeFocus/ → 清空。
private let crashFatalPath = diagnosticFatalLogPath()
private let crashFatalFD: Int32 = {
    return open(crashFatalPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
}()

// 退出审计（ExitJournal/exits.jsonl）：handler 只做一次 write 落盘预编码行，
// installCrashSignalHandlers 时打开 FD 并按本进程 pid 预生成各信号的行。
nonisolated(unsafe) private var exitJournalFD: Int32 = -1
nonisolated(unsafe) private var fatalSignalJournalLines: [Int32: [CChar]] = [:]
// handler 内不可用 ProcessInfo（非 async-signal-safe），进程名安装期取一次。
private let signalTimeProcessName = ProcessInfo.processInfo.processName

// MARK: - 崩溃堆栈抓取（execinfo）
//
// SIGTRAP 类死亡在 CrashReporter 侧反复无 .ips（2026-09-06 多实例实证），
// backtrace_symbols_fd 是崩溃现场唯一的堆栈来源。其内部 malloc 在堆损坏时
// 可能失效——失败即退化为无堆栈，与现状持平，无回退风险。execinfo 未桥接进
// Swift 的 Darwin 模块，用 @_silgen_name 直连 libsystem 符号。
@_silgen_name("backtrace")
private func crash_backtrace(_ addrs: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32) -> Int32

@_silgen_name("backtrace_symbols_fd")
private func crash_backtrace_symbols_fd(_ addrs: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: Int32, _ fd: Int32)

// MARK: - 双缓冲快照

/// async-signal-safe 的 PRE-CRASH STATE 双缓冲。
///
/// ## 场景
/// - 生产者（主线程 updateCrashSnapshotFromRuntime）写 active buffer；
/// - 消费者（任意线程的 crashSignalHandler）readInactiveBuffer + writev 落盘——
///   读"对面"缓冲避免读到正在写一半的内容。
private final class CrashSnapshotBuffer: @unchecked Sendable {
    static let shared = CrashSnapshotBuffer()

    private let bufferA = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private let bufferB = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private var activeBuffer: UnsafeMutablePointer<CChar>
    private var lengthA: Int = 0
    private var lengthB: Int = 0
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
        let len = max(0, written)
        buf.advanced(by: len).pointee = 0
        // 记录刚写入的 buffer 长度，再切换 active buffer
        if activeIsA {
            lengthA = len
        } else {
            lengthB = len
        }
        activeIsA = !activeIsA
        activeBuffer = activeIsA ? bufferA : bufferB
        activeBuffer.pointee = 0
        lock.unlock()
    }

    func readInactiveBuffer() -> (ptr: UnsafeMutablePointer<CChar>, len: Int) {
        lock.lock()
        // inactive buffer 是当前 active 的对面
        let buf: UnsafeMutablePointer<CChar>
        let len: Int
        if activeIsA {
            buf = bufferB
            len = lengthB
        } else {
            buf = bufferA
            len = lengthA
        }
        lock.unlock()
        return (buf, len)
    }
}

// MARK: - 信号处理器

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
    sigMsg += ") proc=\(signalTimeProcessName) pid=\(getpid()) caught at "
    var now = time(nil)
    var tm = tm()
    localtime_r(&now, &tm)
    var timeBuf = [CChar](repeating: 0, count: 32)
    strftime(&timeBuf, 32, "%Y-%m-%dT%H:%M:%S", &tm)
    sigMsg += String(cString: timeBuf)
    sigMsg += "\n\n=== PRE-CRASH STATE ===\n"

    var sigData = [CChar](repeating: 0, count: 512)
    sigMsg.withCString { ptr in
        var idx = 0
        while idx < 511 && ptr[idx] != 0 {
            sigData[idx] = ptr[idx]
            idx += 1
        }
        sigData[idx] = 0
    }

    let nl = "\n=== END PRE-CRASH STATE ===\n"
    var nlData = [CChar](repeating: 0, count: 32)
    nl.withCString { ptr in
        var idx = 0
        while idx < 31 && ptr[idx] != 0 { nlData[idx] = ptr[idx]; idx += 1 }
        nlData[idx] = 0
    }

    // 2026-09-06：writev 改三次普通 write。writev 在真机反复部分失败——只落
    // iov[1] 的 3-10 个二进制字节、sigMsg 文本整体丢失（01:24/04:30/17:27 的
    // 8-10B 神秘归档即此成因，crash-test 复现并定位）；write 则全程零丢失
    // （审计行/BT 头均完整落地）。三次 write 均为 async-signal-safe，O_APPEND
    // 下各自原子定位；多线程并发崩溃时可能交错，属可接受的取证折衷。
    withUnsafeMutableBytes(of: &sigData) { sigBase in
        let sigLen = strlen(sigBase.baseAddress!)
        withUnsafeMutableBytes(of: &nlData) { nlBase in
            let nlLen = strlen(nlBase.baseAddress!)
            func emit(to fd: Int32) {
                _ = write(fd, sigBase.baseAddress, sigLen)
                if len > 0 {
                    _ = write(fd, buf, len)
                }
                _ = write(fd, nlBase.baseAddress, nlLen)
            }
            emit(to: crashSnapshotFD)
            // 额外写入独立 fatal FD（O_APPEND 不截断），下次启动 archivePreviousCrashFatalIfNeeded
            // 会读取归档。修复根因 #3：crashSnapshotFD 启动时 O_TRUNC 会覆盖此处写的 FATAL SIGNAL。
            // 仅 writev（async-signal-safe）。不 close（writev 返回数据已在内核 page cache，
            // 紧随的退出不影响落盘）。
            if crashFatalFD >= 0 {
                emit(to: crashFatalFD)
            }
            // 退出审计：预编码的 fatal-signal 行写入 exits.jsonl（install 期预生成，
            // handler 内一次 write，async-signal-safe）。SIGKILL 无此行——审计上
            // 「launch 无配对 exit」即外部击杀实证。
            if exitJournalFD >= 0, let line = fatalSignalJournalLines[sig] {
                line.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        _ = write(exitJournalFD, base, strlen(base))
                    }
                }
            }
            // 崩溃堆栈：SIGTRAP 类死亡无 .ips 时的唯一堆栈来源（见文件头 execinfo 注释）。
            var stackAddrs = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let frameCount = crash_backtrace(&stackAddrs, 64)
            if frameCount > 0 {
                let btHeader = "\n=== BACKTRACE (frames=\(frameCount)) ===\n"
                btHeader.withCString { ptr in
                    _ = write(crashSnapshotFD, ptr, strlen(ptr))
                    if crashFatalFD >= 0 {
                        _ = write(crashFatalFD, ptr, strlen(ptr))
                    }
                }
                crash_backtrace_symbols_fd(&stackAddrs, frameCount, crashSnapshotFD)
                if crashFatalFD >= 0 {
                    crash_backtrace_symbols_fd(&stackAddrs, frameCount, crashFatalFD)
                }
            }
        }
    }

    close(crashSnapshotFD)
    // 2026-08-31 修复：此前直接 _exit(128+sig)，绕过 macOS CrashReporter——~/Library/Logs/
    // DiagnosticReports 里零 .ips 记录，每次崩溃只知信号类型、拿不到崩溃点堆栈，只能靠日志推断。
    // 改为重置默认处理器后重新抛出：进程按默认行为终止 → CrashReporter 生成带完整堆栈的 .ips
    // （CrashContextRecorder.bootstrap 已有 .ips 解析归因逻辑，正好衔接）。signal() 与 raise()
    // 均为 async-signal-safe。
    signal(sig, SIG_DFL)
    raise(sig)
    // 兜底：SIG_DFL 后 raise 不应返回；若返回（信号曾被阻塞）则保底退出，防止 handler 返回后
    // 回到损坏的执行现场二次 SIGSEGV 循环。
    _exit(128 + sig)
}

// MARK: - 安装与归档

func installCrashSignalHandlers() {
    // P-INST-247: 崩溃信号处理器注册耗时（6x signal syscall 注册 SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGTRAP 处理器；应用启动调用，崩溃时处理器执行写崩溃快照；与 installAtExitHandler P-INST-193 同类启动注册；slow-op ≥5ms warn）。
    // 启动期先归档上次的致命信号记录（若有），再触发 crashFatalFD 的 open。
    // 顺序重要：归档可能 move 掉旧 fatal 文件，必须在 open（创建新文件）之前完成。
    // 注意：AppDelegate 在调用本函数之前必须先 CrashContextRecorder.shared
    // .capturePreviousCrashFatalDate()（fatal 文件 mtime 是崩溃循环熔断的判定输入）。
    archivePreviousCrashFatalIfNeeded()
    _ = crashFatalFD  // 触发 lazy open（O_CREAT | O_APPEND，不截断）
    // 退出审计：打开 exits.jsonl 追加 FD + 预生成各信号的审计行（handler 内零构造）。
    exitJournalFD = ExitJournal.openAppendFD()
    let journalPID = getpid()
    for (sig, name) in [(SIGSEGV, "SIGSEGV"), (SIGABRT, "SIGABRT"), (SIGBUS, "SIGBUS"),
                        (SIGFPE, "SIGFPE"), (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP")] {
        fatalSignalJournalLines[sig] = ExitJournal.cCharLineForSignal(pid: journalPID, signal: sig, name: name)
    }
    #if PERF_INSTRUMENT
    let icshStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: icshStart)
        if durMs >= 5 { log("[CrashContext] installCrashSignalHandlers slow", level: .warn, fields: ["durationMs": String(durMs)]) }
    }
    #endif
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
        signal(sig, crashSignalHandler)
    }
    signal(SIGTRAP, crashSignalHandler)
}

func installAtExitHandler() {
    // P-INST-193: atexit handler 注册耗时（atexit syscall 注册退出回调；应用启动调用，注册的回调在进程退出时执行 open/write/close 文件 I/O 写崩溃快照日志）。
    #if PERF_INSTRUMENT
    let iaeStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: iaeStart)
        if durMs >= 5 { log("[CrashContext] installAtExitHandler slow", level: .warn, fields: ["durationMs": String(durMs)]) }
    }
    #endif
    atexit {
        let msg = "VibeFocus exiting via atexit (likely normal termination)\n"
        msg.withCString { ptr in
            let fd = open(diagnosticSnapshotLogPath(), O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd != -1 {
                write(fd, ptr, strlen(ptr))
                close(fd)
            }
        }
        // 退出审计兜底：显式 recordExit 的路径（lock 失败/复用已有实例）已写过专属
        // reason，此处只补「正常 Quit / 正常 exit」的 clean 记录。
        ExitJournal.recordCleanExitIfUnrecorded()
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

// MARK: - 快照缓冲入口

func updateCrashSnapshot(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
    CrashSnapshotBuffer.shared.update(block)
}
