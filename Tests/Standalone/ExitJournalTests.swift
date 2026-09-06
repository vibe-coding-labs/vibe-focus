// Tests/Standalone/ExitJournalTests.swift
// Verification: 退出审计日志（exits.jsonl）的路径角色隔离 + 行编码
// Mirrors: Sources/Support/DiagnosticPath.swift (diagnosticFilePath)
//          Sources/Support/ExitJournal.swift (jsonEscape/launchLine/exitLine/cCharLineForSignal)
// Run: swift Tests/Standalone/ExitJournalTests.swift
//
// 背景（2026-09-06 排查「莫名其妙退出」）：SIGKILL 类击杀零痕迹，取证只能靠
// 多文件交叉比对。退出审计让「launch 无配对 exit」成为外部击杀的实证；路径
// 角色隔离消除 TestRunner 等派生二进制对 /tmp 规范诊断文件的交叉污染
// （2026-07-12 僵尸记录以新 mtime 复活污染 keepalive 判定的实证）。

import Foundation

// MARK: - Mirrored logic

func diagnosticFilePath(base: String, processName: String) -> String {
    if processName.isEmpty || processName == "VibeFocusHotkeys" {
        return base
    }
    return "\(base)-\(processName)"
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

func launchLine(
    pid: Int32,
    at: String,
    exe: String,
    exeMtimeEpoch: Int?,
    exeInode: UInt64?,
    bundleID: String?,
    version: String?
) -> String {
    var line = "{\"kind\":\"launch\",\"pid\":\(pid),\"at\":\"\(jsonEscape(at))\""
    line += ",\"exe\":\"\(jsonEscape(exe))\""
    if let m = exeMtimeEpoch { line += ",\"exeMtime\":\(m)" }
    if let i = exeInode { line += ",\"exeInode\":\(i)" }
    if let b = bundleID { line += ",\"bundle\":\"\(jsonEscape(b))\"" }
    if let v = version { line += ",\"version\":\"\(jsonEscape(v))\"" }
    line += "}"
    return line
}

func exitLine(
    pid: Int32,
    at: String,
    reason: String,
    signal: Int32?,
    name: String?
) -> String {
    var line = "{\"kind\":\"exit\",\"pid\":\(pid),\"at\":\"\(jsonEscape(at))\""
    line += ",\"reason\":\"\(jsonEscape(reason))\""
    if let s = signal { line += ",\"signal\":\(s)" }
    if let n = name { line += ",\"name\":\"\(jsonEscape(n))\"" }
    line += "}"
    return line
}

func cCharLineForSignal(pid: Int32, signal: Int32, name: String) -> [CChar] {
    let line = exitLine(pid: pid, at: "-", reason: "fatal-signal", signal: signal, name: name) + "\n"
    var chars = Array(line.utf8CString)
    chars.removeLast()
    return chars
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

// 1. 路径角色隔离
check(diagnosticFilePath(base: "/tmp/fatal.log", processName: "VibeFocusHotkeys") == "/tmp/fatal.log",
      "主应用二进制用规范路径")
check(diagnosticFilePath(base: "/tmp/fatal.log", processName: "VibeFocusTestRunner") == "/tmp/fatal.log-VibeFocusTestRunner",
      "派生二进制加进程名后缀")
check(diagnosticFilePath(base: "/tmp/fatal.log", processName: "") == "/tmp/fatal.log",
      "空进程名退回规范路径")

// 2. launch 行编码：字段完整、可被 JSONSerialization 解析回读
let ll = launchLine(pid: 42, at: "2026-09-06T08:44:40Z", exe: "/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys",
                    exeMtimeEpoch: 1_788_629_068, exeInode: 99, bundleID: "com.openai.vibe-focus", version: "0.0.0")
var llOK = false
if let data = ll.data(using: .utf8),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    llOK = (obj["kind"] as? String) == "launch"
        && (obj["pid"] as? NSNumber)?.intValue == 42
        && (obj["exeInode"] as? NSNumber)?.uint64Value == 99
        && (obj["bundle"] as? String) == "com.openai.vibe-focus"
}
check(llOK, "launch 行编码可解析且字段齐全")

// 3. exit 行编码：signal/name 可选字段按需出现
let elWith = exitLine(pid: 7, at: "2026-09-06T08:43:40Z", reason: "fatal-signal", signal: 11, name: "SIGSEGV")
let elWithout = exitLine(pid: 8, at: "2026-09-06T08:50:00Z", reason: "clean", signal: nil, name: nil)
let elWithOK = (try? JSONSerialization.jsonObject(with: elWith.data(using: .utf8)!) as? [String: Any])
check((elWithOK?["signal"] as? Int) == 11 && (elWithOK?["name"] as? String) == "SIGSEGV",
      "exit 行含 signal 数值与信号名")
check(elWithOK?["reason"] as? String == "fatal-signal", "exit 行 reason 可解析回读")
check(!elWithout.contains("signal") && elWithout.contains("\"reason\":\"clean\""),
      "clean 行不携带 signal 字段")

// 4. jsonEscape：引号/反斜杠/控制字符
check(jsonEscape("a\"b\\c\nd") == "a\\\"b\\\\c\\nd", "特殊字符转义")
check(jsonEscape("普通路径/中文") == "普通路径/中文", "常规字符原样保留")

// 5. CChar 行（handler 预编码）：utf8、以 \n 结尾、可解析回 JSON
var chars = cCharLineForSignal(pid: 305, signal: 11, name: "SIGSEGV")
check(chars.last! == CChar(UInt8(ascii: "\n")), "信号审计行以换行结尾")
check(!chars.contains(0 as CChar), "信号审计行不含 NUL")
chars.removeLast()
let bytes: [UInt8] = chars.map { UInt8(bitPattern: $0) }
let back = String(bytes: bytes, encoding: .utf8) ?? ""
let backOK = (try? JSONSerialization.jsonObject(with: back.data(using: .utf8)!) as? [String: Any])
check(backOK?["kind"] as? String == "exit" && backOK?["signal"] as? Int == 11,
      "信号审计行可解析回 JSON 且信号正确")

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
