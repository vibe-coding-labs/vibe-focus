import Foundation

// MARK: - 一键取证报告（--diagnose）
//
// 2026-09-06 排查「莫名其妙退出」时，证据散落在 6 个地方（exits 审计、fatal 归档、
// .ips、keepalive 日志、应用日志、/tmp 现场），全靠手工交叉比对。本模块把这些
// 取证源汇总成一份文本报告，`VibeFocusHotkeys --diagnose` 一条命令出结果。
//
// 纯逻辑（解析/配对/排版）与 IO 分离：parseJournalLine / unmatchedLaunches 可被
// 镜像测试直接覆盖，report 走真实文件系统。

/// AppEntry（--diagnose）跨模块入口；Doctor 本体保持 internal，测试走镜像。
public enum VibeFocusDoctor {
    public static func report() -> String {
        Doctor.report(paths: .live())
    }
}

struct DoctorPaths {
    var journalPath: String
    var logDir: String
    var tmpFatalPath: String
    var tmpSnapshotPath: String
    var keepaliveLogPath: String
    var diagnosticReportsDir: String
    var appLogPath: String

    static func live() -> DoctorPaths {
        let logDir = NSHomeDirectory() + "/Library/Logs/VibeFocus"
        return DoctorPaths(
            journalPath: ExitJournal.filePath,
            logDir: logDir,
            tmpFatalPath: diagnosticFatalLogPath(),
            tmpSnapshotPath: diagnosticSnapshotLogPath(),
            keepaliveLogPath: "/tmp/vibefocus-keepalive.log",
            diagnosticReportsDir: NSHomeDirectory() + "/Library/Logs/DiagnosticReports",
            appLogPath: logDir + "/vibefocus.log"
        )
    }
}

enum Doctor {

    struct JournalEvent: Equatable {
        var kind: String
        var pid: Int32
        var at: String
        var reason: String?
        var signalName: String?
        var exe: String?
        var ax: Bool?
    }

    // MARK: - 纯逻辑（镜像测试覆盖）

    static func parseJournalLine(_ line: String) -> JournalEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let kind = dict["kind"] as? String,
              let pidNum = dict["pid"] as? NSNumber,
              kind == "launch" || kind == "exit" else {
            return nil
        }
        return JournalEvent(
            kind: kind,
            pid: pidNum.int32Value,
            at: dict["at"] as? String ?? "-",
            reason: dict["reason"] as? String,
            signalName: dict["name"] as? String,
            exe: dict["exe"] as? String,
            ax: dict["ax"] as? Bool
        )
    }

    /// 辅助功能授权翻转检测：两次相邻 launch 之间 true→false = 授权在运行期间失效
    /// （重装替换二进制后 TCC 拒绝，2026-09-06 实锤）。返回翻转点描述数组。
    static func accessibilityFlips(events: [JournalEvent]) -> [String] {
        let launches = events.filter { $0.kind == "launch" && $0.ax != nil }
        var flips: [String] = []
        var previous: JournalEvent?
        for launch in launches {
            if let prev = previous, let prevAX = prev.ax, let ax = launch.ax, prevAX != ax {
                let direction = prevAX ? "true→false（授权失效，需重新勾选辅助功能）"
                                       : "false→true（已重新授权）"
                flips.append("\(launch.at) pid=\(launch.pid)：\(direction)")
            }
            previous = launch
        }
        return flips
    }

    /// launch 无配对 exit = 进程未走正常退出路径（SIGKILL/kill -9/断电）——外部击杀实证。
    static func unmatchedLaunches(events: [JournalEvent]) -> [JournalEvent] {
        var open: [Int32: JournalEvent] = [:]
        for event in events {
            if event.kind == "launch" {
                open[event.pid] = event
            } else {
                open.removeValue(forKey: event.pid)
            }
        }
        return open.values.sorted { $0.at < $1.at }
    }

    // MARK: - 报告

    static func report(paths: DoctorPaths = .live(), now: Date = Date()) -> String {
        var out: [String] = []
        let pid = ProcessInfo.processInfo.processIdentifier
        out.append("=== VibeFocus Doctor (\(ExitJournal.timestamp(now)), pid=\(pid) \(ProcessInfo.processInfo.processName)) ===")

        // 实例生命周期
        var events: [JournalEvent] = []
        let journalText = try? String(contentsOfFile: paths.journalPath, encoding: .utf8)
        if let text = journalText {
            events = text.split(separator: "\n").compactMap { parseJournalLine(String($0)) }
        }
        out.append("")
        out.append("[实例生命周期] \(paths.journalPath)")
        if events.isEmpty {
            out.append("  （无记录或文件不可读）")
        } else {
            out.append("  共 \(events.count) 条事件，最近 \(min(12, events.count)) 条：")
            for e in events.suffix(12) {
                if e.kind == "launch" {
                    out.append("  launch pid=\(e.pid) at=\(e.at) exe=\(e.exe ?? "?")")
                } else {
                    let sig = e.signalName.map { " signal=\($0)" } ?? ""
                    out.append("  exit    pid=\(e.pid) at=\(e.at) reason=\(e.reason ?? "?")\(sig)")
                }
            }
        }

        // 最近一次死亡（排查时最想知道的第一件事）
        if let lastExit = events.last(where: { $0.kind == "exit" }) {
            var line = "pid=\(lastExit.pid) reason=\(lastExit.reason ?? "?")"
            if let sig = lastExit.signalName { line += " signal=\(sig)" }
            if let age = ageSeconds(fromISO: lastExit.at, now: now) {
                line += String(format: "（%.0f 分钟前）", age / 60)
            }
            out.append("")
            out.append("[最近一次死亡] \(line)")
        } else {
            out.append("")
            out.append("[最近一次死亡] 无退出记录")
        }

        // 辅助功能授权时间线
        out.append("")
        let axLaunches = events.filter { $0.kind == "launch" && $0.ax != nil }
        if let latest = axLaunches.last, let ax = latest.ax {
            out.append("[辅助功能授权] 当前：\(ax ? "已授权" : "未授权（热键/窗口管理失效，请到系统设置勾选）")")
            let flips = accessibilityFlips(events: events)
            if flips.isEmpty {
                out.append("  审计期内无 true/false 翻转。")
            } else {
                out.append("  检测到 \(flips.count) 次翻转：")
                for f in flips.suffix(5) {
                    out.append("    \(f)")
                }
            }
        } else {
            out.append("[辅助功能授权] 审计中无 ax 记录（旧版本实例）")
        }

        // 疑似外部击杀（排除还活着的 pid：运行中的实例本来就没有 exit 记录）
        let unmatched = unmatchedLaunches(events: events)
        let alive = unmatched.filter { kill($0.pid, 0) == 0 }
        let deadUnmatched = unmatched.filter { kill($0.pid, 0) != 0 }
        out.append("")
        out.append("[疑似外部击杀（launch 无配对 exit，SIGKILL 类）] \(deadUnmatched.count) 个")
        for e in deadUnmatched.suffix(5) {
            out.append("  pid=\(e.pid) launchedAt=\(e.at) exe=\(e.exe ?? "?")")
        }
        if !alive.isEmpty {
            out.append("  （另有 \(alive.count) 个存活实例尚无退出记录，属正常运行中）")
        }

        // /tmp 现场 + fatal 归档
        out.append("")
        out.append("[致命信号记录现场]")
        out.append("  /tmp fatal: \(fileState(paths.tmpFatalPath))")
        out.append("  /tmp snapshot: \(fileState(paths.tmpSnapshotPath))")
        let archives = filesSortedByMtime(dir: paths.logDir, prefix: "crash-fatal-", suffix: ".log")
        out.append("  归档（最近 \(min(5, archives.count))）:")
        for a in archives.prefix(5) {
            out.append("    \(a.name) \(a.size)B \(formatDate(a.mtime))")
        }

        // .ips 崩溃报告
        let ipsFiles = filesSortedByMtime(dir: paths.diagnosticReportsDir, prefix: "VibeFocus", suffix: ".ips")
        out.append("")
        out.append("[.ips 崩溃报告] 最近 \(min(5, ipsFiles.count))（VibeFocus*）:")
        for f in ipsFiles.prefix(5) {
            out.append("    \(f.name) \(f.size)B \(formatDate(f.mtime))")
        }

        // keepalive 决策日志
        out.append("")
        out.append("[keepalive 决策] \(paths.keepaliveLogPath) 尾部:")
        for line in tailLines(paths.keepaliveLogPath, maxBytes: 8192, count: 5) {
            out.append("    \(line)")
        }

        // 应用日志错误
        out.append("")
        out.append("[应用日志] \(fileState(paths.appLogPath))")
        let errors = tailLines(paths.appLogPath, maxBytes: 262_144, count: 200).filter { $0.contains("[ERROR]") }.suffix(5)
        if errors.isEmpty {
            out.append("  尾部无 [ERROR]")
        } else {
            out.append("  最近 [ERROR]（≤5）:")
            for line in errors {
                out.append("    \(line.prefix(300))")
            }
        }

        out.append("")
        if deadUnmatched.isEmpty {
            out.append("[结论] 无未配对退出记录；结合上方 fatal/ips 段定位历史崩溃。")
        } else {
            out.append("[结论] 存在 \(deadUnmatched.count) 个未配对退出（SIGKILL 类击杀）——")
            out.append("  下一步：比对上方 .ips/归档 mtime 与 launch 时刻；再看 keepalive 决策行。")
        }
        return out.joined(separator: "\n")
    }

    /// ISO8601 审计时间 → 距 now 的秒数；解析失败（如信号审计行的 "-"）返回 nil。
    private static func ageSeconds(fromISO: String, now: Date) -> TimeInterval? {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: fromISO) else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    // MARK: - IO 辅助

    private static func fileState(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            return "不存在"
        }
        let mtime = (attrs[.modificationDate] as? Date).map { formatForFilename.string(from: $0) } ?? "?"
        return "存在 size=\(size)B mtime=\(mtime)"
    }

    private static func filesSortedByMtime(dir: String, prefix: String, suffix: String) -> [(name: String, size: Int, mtime: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.compactMap { name in
            let path = dir + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int,
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (name, size, mtime)
        }
        .sorted { $0.mtime > $1.mtime }
    }

    private static func tailLines(_ path: String, maxBytes: Int, count: Int) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        // 不能写 max(0, size - maxBytes)：UInt64 在小文件上先下溢再 max 已来不及
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        return Array(lines.suffix(count))
    }

    private static let formatForFilename: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static func formatDate(_ date: Date) -> String {
        formatForFilename.string(from: date)
    }
}
