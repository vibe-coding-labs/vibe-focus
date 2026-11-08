import Foundation

// MARK: - 常开性能监控 · 运行时（B321 拆分，行为不变）
// 纯判定层 PerfMonitorLogic 已拆出至 PerfMonitorLogic.swift（Runner 直测域）；
// 本文件保留单例运行时（心跳/看门狗/区间栈/计数器/快照落盘）。

final class PerfMonitor: @unchecked Sendable {
    static let shared = PerfMonitor()

    /// 单锁守护全部可变状态：临界区都只有字典读写，无回调无 IO，
    /// 看门狗线程与主线程争用可忽略，也不会死锁（锁内绝不调 log 之外的慢路径）。
    private let lock = NSLock()
    private var counters: [String: PerfMonitorLogic.CounterSnapshot] = [:]
    private var activeSections: [ObjectIdentifier: [PerfMonitorLogic.Section]] = [:]
    private var journal = PerfMonitorLogic.JournalRing(capacity: 64)
    private var stallHistory: [PerfMonitorLogic.StallRecord] = []
    private var lastHeartbeatAt: Date = Date()
    private var lastStallReportedS: Double?
    private var lastStallAt: Date?
    private(set) var stallCount = 0

    private var mainTimer: Timer?
    private var watchdogThread: Thread?
    private var snapshotWorkItem: DispatchWorkItem?

    /// 看门狗参数（Runner 断言锁定默认值语义）。
    static let heartbeatInterval: TimeInterval = 0.05
    static let watchdogPollInterval: TimeInterval = 0.10
    static let stallWarnSeconds: Double = 0.25
    static let stallErrorSeconds: Double = 1.0
    static let stallEscalationSeconds: Double = 1.0
    /// 快照落盘周期（常驻证据，--diagnose 读文件不依赖 app 进程内状态）。
    static let snapshotInterval: TimeInterval = 300
    static let snapshotPath: String = NSHomeDirectory() + "/Library/Logs/VibeFocus/perf-snapshot.json"
    /// 调用栈采样只对 ≥1s（ERROR 级）停顿触发，且每次停顿只采一次。
    static let stackSampleMinSeconds: Double = 1.0

    private init() {}

    // MARK: 启动（主线程调用一次；幂等）

    func startHeartbeatOnMain() {
        guard mainTimer == nil else { return }
        BacktraceSampler.captureMainThreadPortOnLaunch()
        lock.lock()
        lastHeartbeatAt = Date()
        lock.unlock()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        mainTimer = timer
        let thread = Thread { [weak self] in
            Thread.current.name = "vibefocus-perf-watchdog"
            while true {
                usleep(useconds_t(Self.watchdogPollInterval * 1_000_000))
                self?.checkForStall()
            }
        }
        thread.qualityOfService = .utility
        thread.start()
        watchdogThread = thread
        scheduleSnapshot()
        journal("perf-monitor started")
        log("[PerfMonitor] started (heartbeat 50ms, stall warn ≥250ms error ≥1s + stack sample, journal ring 64, snapshot every 300s)")
    }

    /// 主线程心跳：主 runloop 每跳更新时间戳。主线程被阻塞时心跳停跳，
    /// 时间戳停更——看门狗据此判停顿。故意不起后台队列（后台心跳探测不到主线程卡死）。
    private func heartbeat() {
        lock.lock()
        lastHeartbeatAt = Date()
        lock.unlock()
    }

    // MARK: 主线程活动轨迹（journal）

    /// 记录一条活动轨迹（任意线程可调；主线程条目带 M 标）。停顿报告与快照
    /// 都会带上尾部若干条——「sections=0 之谜」的主线程行为证据。
    func journal(_ event: String) {
        let tag = Thread.isMainThread ? "M" : "B"
        let t = Int(ProcessInfo.processInfo.systemUptime * 1000)
        lock.lock()
        journal.append("[+\(t)ms \(tag)] \(event)")
        lock.unlock()
    }

    // MARK: 区间埋点（begin/end 必须同线程配对；嵌套安全）

    func beginSection(_ name: String, fields: [String: String] = [:]) {
        let section = PerfMonitorLogic.Section(name: name, fields: fields, startedAt: Date())
        let key = ObjectIdentifier(Thread.current)
        lock.lock()
        activeSections[key, default: []] = PerfMonitorLogic.push(stack: activeSections[key] ?? [], section: section)
        lock.unlock()
        if Thread.isMainThread, !PerfMonitorLogic.journalQuietSections.contains(name) {
            journal("▶\(name)")
        }
    }

    func endSection() {
        let key = ObjectIdentifier(Thread.current)
        lock.lock()
        let (section, remaining) = PerfMonitorLogic.pop(stack: activeSections[key] ?? [])
        if remaining.isEmpty {
            activeSections.removeValue(forKey: key)
        } else {
            activeSections[key] = remaining
        }
        lock.unlock()
        guard let section else {
            log("[PerfMonitor] endSection underflow on \(Thread.current)", level: .debug)
            return
        }
        let durationMs = section.elapsedMs(now: Date())
        record(section.name, durationMs: durationMs)
        if Thread.isMainThread, durationMs >= 100 {
            journal("✓\(section.name) \(Int(durationMs))ms")
        }
    }

    /// 显式计数（不经区间栈，如外部已有耗时的补记）。
    func record(_ name: String, durationMs: Double) {
        lock.lock()
        var existing = counters[name]
        PerfMonitorLogic.record(counter: &existing, name: name, durationMs: durationMs)
        if let existing { counters[name] = existing }
        lock.unlock()
    }

    /// 同步区间测量（B190）：begin/end 自动配对，返回闭包值。闭包须在调用线程
    /// 内同步完成（区间栈按线程配对）。restore/toggle 子阶段埋点用它免 defer 样板。
    func measure<T>(_ name: String, fields: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        beginSection(name, fields: fields)
        defer { endSection() }
        return try body()
    }

    // MARK: 看门狗（后台线程巡检）

    private func checkForStall() {
        let now = Date()
        lock.lock()
        let deltaS = now.timeIntervalSince(lastHeartbeatAt)
        // 主线程（心跳线程）的区间栈排最前——停顿归因最先看它；其余线程区间附后。
        let mainKey = ObjectIdentifier(Thread.main)
        let sections = (activeSections[mainKey] ?? [])
            + activeSections.filter { $0.key != mainKey }.sorted { $0.key.hashValue < $1.key.hashValue }.flatMap { $0.value }
        let countersCopy = counters
        let journalCopy = journal.entries
        let reportedS = lastStallReportedS
        lock.unlock()

        guard let level = PerfMonitorLogic.stallLevel(
            deltaS: deltaS,
            warnS: Self.stallWarnSeconds,
            errorS: Self.stallErrorSeconds
        ) else {
            lock.lock()
            lastStallReportedS = nil
            lock.unlock()
            return
        }
        guard PerfMonitorLogic.shouldReportStall(
            lastReportedS: reportedS,
            currentDeltaS: deltaS,
            escalationS: Self.stallEscalationSeconds
        ) else { return }

        lock.lock()
        lastStallReportedS = deltaS
        lastStallAt = now
        stallCount += 1
        let stallCountNow = stallCount
        lock.unlock()

        let top = PerfMonitorLogic.topCounters(countersCopy, limit: 3)
        let report = PerfMonitorLogic.stallReport(
            deltaS: deltaS,
            sections: sections,
            counters: top,
            now: now,
            journal: journalCopy
        )
        log("[PERF][STALL] main thread blocked \(report)", level: level, fields: [
            "deltaMs": String(Int(deltaS * 1000)),
            "sections": String(sections.count),
            "stallCount": String(stallCountNow)
        ])

        // B182：≥1s 停顿采样主线程调用栈（根因级证据）。采样自身 suspend/resume
        // 主线程——此处不持任何锁 ✓；符号化在 resume 后异步执行。
        if deltaS >= Self.stackSampleMinSeconds {
            let addresses = BacktraceSampler.sampleMainThread()
            let stackSummary: String?
            if addresses.isEmpty {
                stackSummary = nil
            } else {
                stackSummary = "sampled(\(addresses.count) frames)"
                DispatchQueue.global(qos: .utility).async {
                    let symbols = BacktraceSampler.symbolize(addresses)
                    log("[PERF][STALL] main stack (\(symbols.count) frames): "
                        + symbols.prefix(16).joined(separator: " ← "))
                }
            }
            lock.lock()
            appendStallHistory(PerfMonitorLogic.StallRecord(
                at: now,
                deltaMs: Int(deltaS * 1000),
                level: level == .error ? "ERROR" : "WARN",
                sectionsSummary: sections.map(\.name).joined(separator: ">"),
                stackSummary: stackSummary
            ))
            lock.unlock()
        }
        writeSnapshot(reason: "stall")
    }

    /// 停顿历史环（调用方持锁；容量 8）。
    private func appendStallHistory(_ record: PerfMonitorLogic.StallRecord) {
        stallHistory.append(record)
        if stallHistory.count > 8 {
            stallHistory.removeFirst(stallHistory.count - 8)
        }
    }

    // MARK: 快照（常驻证据文件；--diagnose 读文件不依赖 app 存活）

    private func scheduleSnapshot() {
        let item = DispatchWorkItem { [weak self] in
            self?.writeSnapshot(reason: "periodic")
            self?.scheduleSnapshot()
        }
        snapshotWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.snapshotInterval, execute: item)
    }

    func writeSnapshot(reason: String) {
        lock.lock()
        let snapshot = PerfMonitorLogic.SnapshotFile(
            generatedAt: Date(),
            stallCount: stallCount,
            lastStallDeltaS: lastStallReportedS,
            lastStallAt: lastStallAt,
            counters: PerfMonitorLogic.topCounters(counters, limit: 64),
            journal: Array(journal.entries.suffix(32)),
            stalls: stallHistory
        )
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: URL(fileURLWithPath: Self.snapshotPath))
            _ = reason
        }
    }

    // MARK: 读取（Doctor/--diagnose 与本进程共用）

    func snapshotCounters() -> [PerfMonitorLogic.CounterSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return PerfMonitorLogic.topCounters(counters, limit: 64)
    }

    /// 从快照文件读取（跨进程：--diagnose 进程调用）。
    static func loadSnapshotFile(path: String = snapshotPath) -> PerfMonitorLogic.SnapshotFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(PerfMonitorLogic.SnapshotFile.self, from: data)
    }

    /// 解析日志中的停顿行（Doctor 报告用；纯函数，Runner 直测）。
    static func parseStallLogLine(_ line: String) -> (at: String, deltaMs: Int, level: String)? {
        guard line.contains("[PERF][STALL]"),
              let atStart = line.firstIndex(of: "["),
              let atEnd = line.firstIndex(of: "]"),
              atStart < atEnd else { return nil }
        let at = String(line[line.index(after: atStart)..<atEnd])
        guard let range = line.range(of: "deltaMs=") else { return nil }
        let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
        guard let deltaMs = Int(digits) else { return nil }
        let level = line.contains("[ERROR]") ? "ERROR" : "WARN"
        return (at, deltaMs, level)
    }
}
