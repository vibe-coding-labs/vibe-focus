// Tests/Standalone/DoctorReportTests.swift
// Verification: 一键取证报告的纯逻辑（审计行解析 + launch/exit 配对）与临时目录端到端
// Mirrors: Sources/Support/Doctor.swift (parseJournalLine/unmatchedLaunches/report)
// Run: swift Tests/Standalone/DoctorReportTests.swift
//
// 背景（2026-09-06 排查「莫名其妙退出」）：83091/84552/41369 三个实例完整启动后
// 秒死且零报告——若有 exits.jsonl 审计，它们会以「launch 无配对 exit」现形。
// 本测试锁定：审计行解析容错、配对规则、报告段落齐全。

import Foundation

// MARK: - Mirrored logic

struct JournalEvent: Equatable {
    var kind: String
    var pid: Int32
    var at: String
    var reason: String?
    var signalName: String?
    var exe: String?
}

func parseJournalLine(_ line: String) -> JournalEvent? {
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
        exe: dict["exe"] as? String
    )
}

func unmatchedLaunches(events: [JournalEvent]) -> [JournalEvent] {
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

// MARK: - Assertions

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("  PASS: \(name)")
    } else {
        failures += 1
        print("  FAIL: \(name)")
    }
}

// 1. 解析：合法行 / 坏行 / 未知 kind
let good = parseJournalLine("{\"kind\":\"launch\",\"pid\":1,\"at\":\"2026-09-06T08:00:00Z\",\"exe\":\"/x/VibeFocusHotkeys\"}")
check(good?.kind == "launch" && good?.pid == 1 && good?.exe == "/x/VibeFocusHotkeys", "合法 launch 行解析")
check(parseJournalLine("这不是JSON") == nil, "坏行返回 nil（容错跳过）")
check(parseJournalLine("{\"kind\":\"other\",\"pid\":1,\"at\":\"-\"}") == nil, "未知 kind 拒绝")
let exitParsed = parseJournalLine("{\"kind\":\"exit\",\"pid\":1,\"at\":\"-\",\"reason\":\"fatal-signal\",\"signal\":11,\"name\":\"SIGSEGV\"}")
check(exitParsed?.signalName == "SIGSEGV" && exitParsed?.reason == "fatal-signal", "exit 行信号字段解析")

// 2. 配对：clean 闭环不算；launch 无 exit 现形；同 pid 二轮发射
let events: [JournalEvent] = [
    JournalEvent(kind: "launch", pid: 100, at: "01", reason: nil, signalName: nil, exe: "a"),
    JournalEvent(kind: "exit", pid: 100, at: "02", reason: "clean", signalName: nil, exe: nil),
    JournalEvent(kind: "launch", pid: 200, at: "03", reason: nil, signalName: nil, exe: "b"),
    JournalEvent(kind: "exit", pid: 200, at: "04", reason: "fatal-signal", signalName: "SIGSEGV", exe: nil),
    JournalEvent(kind: "launch", pid: 300, at: "05", reason: nil, signalName: nil, exe: "c"),
]
let unmatched = unmatchedLaunches(events: events)
check(unmatched.count == 1 && unmatched[0].pid == 300, "仅未配对 launch 被点名")
check(unmatched[0].exe == "c", "未配对记录携带 exe 身份")

// 3. 端到端：临时目录装配取证现场 → 报告包含各段落与点名
let tmp = NSTemporaryDirectory() + "doctor-test-\(UUID().uuidString)"
let logDir = tmp + "/Library/Logs/VibeFocus"
try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: tmp + "/DiagnosticReports", withIntermediateDirectories: true)

let journalLines = [
    "{\"kind\":\"launch\",\"pid\":100,\"at\":\"2026-09-06T01:00:00Z\",\"exe\":\"/a\"}",
    "{\"kind\":\"exit\",\"pid\":100,\"at\":\"2026-09-06T01:10:00Z\",\"reason\":\"clean\"}",
    "{\"kind\":\"launch\",\"pid\":41369,\"at\":\"2026-09-06T08:43:39Z\",\"exe\":\"/x/VibeFocusHotkeys\"}",
    "坏行故意",
]
try? journalLines.joined(separator: "\n").write(toFile: logDir + "/exits.jsonl", atomically: true, encoding: .utf8)
try? "FATAL SIGNAL 11 (SIGSEGV) caught at 2026-09-06T08:43:40".write(
    toFile: logDir + "/crash-fatal-20260906-084340.log", atomically: true, encoding: .utf8)
try? "2026-09-06 16:43:40 app exited fatal=unchanged bin=REPLACED decision=no-respawn\n".write(
    toFile: tmp + "/keepalive.log", atomically: true, encoding: .utf8)
try? "2026-09-06T08:43:40Z [ERROR] [SpaceController] failed to launch".write(
    toFile: logDir + "/vibefocus.log", atomically: true, encoding: .utf8)
try? "ips-body".write(toFile: tmp + "/DiagnosticReports/VibeFocusHotkeys-2026-09-06-084340.ips",
                      atomically: true, encoding: .utf8)

struct DoctorPaths {
    var journalPath: String
    var logDir: String
    var tmpFatalPath: String
    var tmpSnapshotPath: String
    var keepaliveLogPath: String
    var diagnosticReportsDir: String
    var appLogPath: String
}

func filesSortedByMtime(dir: String, prefix: String, suffix: String) -> [(name: String, size: Int, mtime: Date)] {
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

func tailLines(_ path: String, maxBytes: Int, count: Int) -> [String] {
    guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? fh.seek(toOffset: start)
    let data = (try? fh.readDataToEndOfFile()) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? ""
    return Array(text.split(separator: "\n").map(String.init).suffix(count))
}

let paths = DoctorPaths(
    journalPath: logDir + "/exits.jsonl",
    logDir: logDir,
    tmpFatalPath: tmp + "/nonexistent-fatal.log",
    tmpSnapshotPath: tmp + "/nonexistent-snapshot.log",
    keepaliveLogPath: tmp + "/keepalive.log",
    diagnosticReportsDir: tmp + "/DiagnosticReports",
    appLogPath: logDir + "/vibefocus.log"
)

var report = "=== VibeFocus Doctor ===\n"
let allLines = (try? String(contentsOfFile: paths.journalPath, encoding: .utf8)) ?? ""
let parsed = allLines.split(separator: "\n").compactMap { parseJournalLine(String($0)) }
report += "[实例生命周期] 共 \(parsed.count) 条事件\n"
for e in parsed.suffix(12) {
    report += e.kind == "launch" ? "  launch pid=\(e.pid) exe=\(e.exe ?? "?")\n" : "  exit    pid=\(e.pid) reason=\(e.reason ?? "?")\n"
}
let unmatched2 = unmatchedLaunches(events: parsed)
report += "[疑似外部击杀] \(unmatched2.count) 个\n"
for e in unmatched2 { report += "  pid=\(e.pid) launchedAt=\(e.at)\n" }
let archives = filesSortedByMtime(dir: paths.logDir, prefix: "crash-fatal-", suffix: ".log")
report += "[致命信号记录现场] 归档 \(archives.count) 个: \(archives.first?.name ?? "无")\n"
let ips = filesSortedByMtime(dir: paths.diagnosticReportsDir, prefix: "VibeFocus", suffix: ".ips")
report += "[.ips 崩溃报告] \(ips.count) 个: \(ips.first?.name ?? "无")\n"
let klines = tailLines(paths.keepaliveLogPath, maxBytes: 8192, count: 5)
report += "[keepalive 决策] \(klines.first ?? "无")\n"
let errs = tailLines(paths.appLogPath, maxBytes: 262_144, count: 200).filter { $0.contains("[ERROR]") }
report += "[应用日志] ERROR \(errs.count) 条\n"

check(report.contains("共 3 条事件"), "审计共 3 条有效事件（坏行被容错跳过）")
check(report.contains("pid=41369") && report.contains("[疑似外部击杀] 1 个"), "秒死实例被审计点名")
check(report.contains("crash-fatal-20260906-084340.log"), "fatal 归档出现在报告中")
check(report.contains("VibeFocusHotkeys-2026-09-06-084340.ips"), ".ips 出现在报告中")
check(report.contains("bin=REPLACED"), "keepalive 二进制替换指纹进入报告")
check(report.contains("ERROR 1 条"), "应用日志错误行被采集")

try? FileManager.default.removeItem(atPath: tmp)

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
