import Foundation

// MARK: - 常开性能监控（B178 建，B182 证据链升级）
// 方法论：任何性能问题的证据链 = [PERF][STALL] 归因行（停顿时长 + 活跃区间栈 +
// 计数器 Top + 主线程活动轨迹 + ≥1s 停顿的调用栈）→ perf-snapshot.json 直方图
// （典型 vs 最差分布）→ --diagnose 汇总。排查手册：docs/performance-triage-runbook.md。
//
// B182 升级（用户要求「完整证据链、不靠撞大运」）：
//   1. 区间耗时直方图桶（<10/10-50/50-200/200-1k/≥1k ms）——「max 是不是孤例」
//      一眼可判，典型/最差分布不靠猜；
//   2. 主线程活动轨迹环形缓冲（journal，64 条）——停顿发生时即使无活跃区间
//      （sections=0 之谜），主线程刚做过什么也有据可查；
//   3. ≥1s 停顿的主线程调用栈采样（arm64 FP 走链，suspend→取址→resume→符号化）
//      ——直接给出「主线程卡在哪个函数」，根因级证据；
//   4. 停顿历史环（快照文件持久化最近 8 次停顿）——复盘不再依赖翻全量日志。
// 开销预算：心跳 20 次/s（锁+Date，µs 级）；巡检线程 10 次/s（读锁+比较）；
// 埋点每区间两次锁 + 一次 Date()；journal 仅主线程区间追加（容量裁剪 O(1)）。

// MARK: - 纯判定层（Runner 直测，无 IO 无锁）

enum PerfMonitorLogic {

    /// 停顿分级：达到 error 阈值返回 .error，达到 warn 阈值返回 .warn，否则 nil
    ///（不报告）。恰好等于阈值算达到（>=）。
    static func stallLevel(deltaS: Double, warnS: Double = 0.25, errorS: Double = 1.0) -> LogLevel? {
        if deltaS >= errorS { return .error }
        if deltaS >= warnS { return .warn }
        return nil
    }

    /// 同一停顿持续期间重复报告的节流决策：距上次报告后停顿又增长 >= escalationS
    /// 才再报（阻塞中每 100ms 巡检一次，不节流会每 100ms 刷一条同值日志）。
    /// 首报（lastReportedS == nil）恒 true。
    static func shouldReportStall(lastReportedS: Double?, currentDeltaS: Double, escalationS: Double = 1.0) -> Bool {
        guard let last = lastReportedS else { return true }
        return currentDeltaS - last >= escalationS
    }

    /// 直方图桶边界（ms）：<10 / 10-50 / 50-200 / 200-1000 / >=1000。
    static let bucketBounds: [Double] = [10, 50, 200, 1000]

    /// 耗时 → 桶下标（0..4；恰等边界进高桶）。
    static func bucketIndex(durationMs: Double) -> Int {
        for (index, bound) in bucketBounds.enumerated() where durationMs < bound {
            return index
        }
        return bucketBounds.count
    }

    /// 单计数器条目：name → 调用次数 / 累计耗时 / 最差耗时 / 直方图桶。
    struct CounterSnapshot: Equatable, Codable {
        var name: String
        var count: Int
        var totalMs: Double
        var maxMs: Double
        /// 直方图桶计数（bucketBounds.count + 1 = 5 桶）。
        var buckets: [Int] = [0, 0, 0, 0, 0]
    }

    /// 累加一次区间耗时（负值/NaN 防御：丢弃不计数）。
    static func record(counter: inout CounterSnapshot?, name: String, durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        let bucket = bucketIndex(durationMs: durationMs)
        if counter == nil {
            var buckets = [0, 0, 0, 0, 0]
            buckets[bucket] += 1
            counter = CounterSnapshot(name: name, count: 1, totalMs: durationMs, maxMs: durationMs, buckets: buckets)
        } else {
            counter!.count += 1
            counter!.totalMs += durationMs
            counter!.maxMs = max(counter!.maxMs, durationMs)
            counter!.buckets[bucket] += 1
        }
    }

    /// 计数器 Top-K（按 maxMs 降序，平局按 name 升序保稳定序）。
    static func topCounters(_ counters: [String: CounterSnapshot], limit: Int) -> [CounterSnapshot] {
        counters.values
            .sorted { $0.maxMs != $1.maxMs ? $0.maxMs > $1.maxMs : $0.name < $1.name }
            .prefix(max(0, limit)).map { $0 }
    }

    /// 活跃区间条目（begin 时刻快照）。
    struct Section: Equatable {
        var name: String
        var fields: [String: String]
        var startedAt: Date
        /// 区间已持续毫秒（快照时刻 - startedAt）。
        func elapsedMs(now: Date) -> Double { now.timeIntervalSince(startedAt) * 1000 }
    }

    /// 区间栈压入（返回新栈；纯函数便于直测嵌套/复位语义）。
    static func push(stack: [Section], section: Section) -> [Section] {
        stack + [section]
    }

    /// 区间栈弹出并产出到期条目（配对校验：空栈弹出返回 nil 栈不变——防
    /// endSection 多调导致的栈下溢，调用方如实记 debug 不崩）。
    static func pop(stack: [Section]) -> (Section?, [Section]) {
        guard let last = stack.last else { return (nil, stack) }
        return (last, Array(stack.dropLast()))
    }

    /// 主线程活动轨迹环形缓冲（B182）：固定容量、满则淘汰最旧并计数。
    struct JournalRing: Equatable {
        var entries: [String] = []
        var capacity: Int
        var dropped: Int = 0

        init(capacity: Int) { self.capacity = max(1, capacity) }

        mutating func append(_ entry: String) {
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
                dropped += 1
            }
        }
    }

    /// 单次停顿的持久化记录（快照文件内）。
    struct StallRecord: Codable, Equatable {
        var at: Date
        var deltaMs: Int
        var level: String
        var sectionsSummary: String
        var stackSummary: String?
    }

    /// 停顿报告单行正文（看门狗与快照共用，保证日志/报告同语言）：
    /// `2.31s sections=[hook.Stop(1.9s) > move.toMain(1.9s)] top=[...] journal=[...]`
    static func stallReport(
        deltaS: Double,
        sections: [Section],
        counters: [CounterSnapshot],
        now: Date,
        journal: [String] = []
    ) -> String {
        let sectionDesc = sections.map { section -> String in
            let fieldsPart = section.fields.isEmpty ? "" : " " + section.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(section.name)\(fieldsPart)(\(String(format: "%.1f", section.elapsedMs(now: now) / 1000))s)"
        }.joined(separator: " > ")
        let topDesc = counters.prefix(3).map { counter -> String in
            let avg = counter.count > 0 ? counter.totalMs / Double(counter.count) : 0
            return "\(counter.name)×\(counter.count) max=\(String(format: "%.1f", counter.maxMs))ms avg=\(String(format: "%.1f", avg))ms"
        }.joined(separator: ", ")
        let journalDesc = journal.suffix(4).joined(separator: " | ")
        return String(format: "%.2fs", deltaS)
            + (sectionDesc.isEmpty ? "" : " sections=[\(sectionDesc)]")
            + (topDesc.isEmpty ? "" : " top=[\(topDesc)]")
            + (journalDesc.isEmpty ? "" : " journal=[\(journalDesc)]")
    }

    /// 直方图格式化（报告行）。
    static func bucketSummary(_ buckets: [Int]) -> String {
        let labels = ["<10", "10-50", "50-200", "200-1k", ">=1k"]
        return (0..<(bucketBounds.count + 1)).map { i in
            "\(labels[i]):\(i < buckets.count ? buckets[i] : 0)"
        }.joined(separator: "/")
    }

    /// 快照文件 JSON 形状（perf-snapshot.json，--diagnose/Doctor 消费）。
    struct SnapshotFile: Codable, Equatable {
        var generatedAt: Date
        var stallCount: Int
        var lastStallDeltaS: Double?
        var lastStallAt: Date?
        var counters: [CounterSnapshot]
        /// B182：主线程活动轨迹尾部 + 停顿历史环。
        var journal: [String]?
        var stalls: [StallRecord]?
    }
}

// MARK: - 运行时（单例；线程安全模型见各方法）

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
        if Thread.isMainThread {
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
