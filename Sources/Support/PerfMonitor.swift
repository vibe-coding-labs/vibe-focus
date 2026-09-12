import Foundation

// MARK: - 常开性能监控（B178，2026-09-12）
// 背景：2026-09-12 用户报「气泡打字中途卡死几秒 + 整个设置页卡顿」，日志回溯实锤
// 主线程被 hook 窗口作业同步占用：577 个 hook 请求中 89 次 >200ms（UPS 归位 34/35、
// Stop 移动 16/16，最坏单次 66s）——但这类证据此前只能事后翻 INFO 日志粗估，
// 且 PERF_INSTRUMENT 埋点生产构建不编入。本模块提供**零编译开关、常开、低开销**的
// 三件套，让以后任何卡顿在发生瞬间就带上归因：
//   1. 主线程停顿看门狗：主线程 50ms 心跳 + 看门狗线程 100ms 巡检；主线程被任何
//      工作阻塞 ≥250ms 即落 WARN/ERROR 日志（含停顿时长 + 当时活跃区间栈 +
//      计数器 Top）——不再依赖「事后人肉对时间线」。
//   2. 区间埋点（beginSection/endSection）：已知重路径（hook 处理/移窗/恢复/
//      回灌/minimap/建格）打标，看门狗日志直接给出「卡在谁身上」。
//   3. 计数器：每区间 count/totalMs/maxMs 自启动累计，快照定期落盘
//      perf-snapshot.json，--diagnose 与 Doctor 直接可见。
// 开销预算：心跳 20 次/s（锁+Date，µs 级）；巡检线程 10 次/s（读锁+比较）；
// 埋点每区间两次锁 + 一次 Date()。对毫秒级路径无感，对秒级路径可忽略。

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

    /// 单计数器条目：name → 调用次数 / 累计耗时 / 最差耗时。
    struct CounterSnapshot: Equatable, Codable {
        var name: String
        var count: Int
        var totalMs: Double
        var maxMs: Double
    }

    /// 累加一次区间耗时（负值/NaN 防御：丢弃不计数）。
    static func record(counter: inout CounterSnapshot?, name: String, durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        if counter == nil {
            counter = CounterSnapshot(name: name, count: 1, totalMs: durationMs, maxMs: durationMs)
        } else {
            counter!.count += 1
            counter!.totalMs += durationMs
            counter!.maxMs = max(counter!.maxMs, durationMs)
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

    /// 停顿日志单行正文（看门狗与快照共用，保证日志/报告同语言）：
    /// `2.31s sections=[hook.Stop(1.9s) > move.toMain(1.9s)] top=[move.toMain×12 max=1.9s avg=0.8s]`
    static func stallReport(deltaS: Double, sections: [Section], counters: [CounterSnapshot], now: Date) -> String {
        let sectionDesc = sections.map { section -> String in
            let fieldsPart = section.fields.isEmpty ? "" : " " + section.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(section.name)\(fieldsPart)(\(String(format: "%.1f", section.elapsedMs(now: now) / 1000))s)"
        }.joined(separator: " > ")
        let topDesc = counters.prefix(3).map { counter -> String in
            let avg = counter.count > 0 ? counter.totalMs / Double(counter.count) : 0
            return "\(counter.name)×\(counter.count) max=\(String(format: "%.1f", counter.maxMs))ms avg=\(String(format: "%.1f", avg))ms"
        }.joined(separator: ", ")
        return String(format: "%.2fs", deltaS)
            + (sectionDesc.isEmpty ? "" : " sections=[\(sectionDesc)]")
            + (topDesc.isEmpty ? "" : " top=[\(topDesc)]")
    }

    /// 快照文件 JSON 形状（perf-snapshot.json，--diagnose/Doctor 消费）。
    struct SnapshotFile: Codable, Equatable {
        var generatedAt: Date
        var stallCount: Int
        var lastStallDeltaS: Double?
        var lastStallAt: Date?
        var counters: [CounterSnapshot]
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

    private init() {}

    // MARK: 启动（主线程调用一次；幂等）

    func startHeartbeatOnMain() {
        guard mainTimer == nil else { return }
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
        log("[PerfMonitor] started (heartbeat 50ms, stall warn ≥250ms error ≥1s, snapshot every 300s)")
    }

    /// 主线程心跳：主 runloop 每跳更新时间戳。主线程被阻塞时心跳停跳，
    /// 时间戳停更——看门狗据此判停顿。故意不起后台队列（后台心跳探测不到主线程卡死）。
    private func heartbeat() {
        lock.lock()
        lastHeartbeatAt = Date()
        lock.unlock()
    }

    // MARK: 区间埋点（begin/end 必须同线程配对；嵌套安全）

    func beginSection(_ name: String, fields: [String: String] = [:]) {
        let section = PerfMonitorLogic.Section(name: name, fields: fields, startedAt: Date())
        let key = ObjectIdentifier(Thread.current)
        lock.lock()
        activeSections[key, default: []] = PerfMonitorLogic.push(stack: activeSections[key] ?? [], section: section)
        lock.unlock()
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
        record(section.name, durationMs: section.elapsedMs(now: Date()))
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
        let report = PerfMonitorLogic.stallReport(deltaS: deltaS, sections: sections, counters: top, now: now)
        log("[PERF][STALL] main thread blocked \(report)", level: level, fields: [
            "deltaMs": String(Int(deltaS * 1000)),
            "sections": String(sections.count),
            "stallCount": String(stallCountNow)
        ])
        writeSnapshot(reason: "stall")
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
            counters: PerfMonitorLogic.topCounters(counters, limit: 64)
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
