import Foundation
import ApplicationServices

// MARK: - 退出审计日志（exits.jsonl，append-only）
//
// 每个 VibeFocus 实例启动写一条 launch、退出写一条 exit；致命信号由
// CrashSignalHandler 写 fatal-signal（async-signal-safe 的预编码行）；
// run.sh 的安装事件（install，无 pid）也追加进同一审计流——AX 授权失效与
// 安装替换二进制的相关性在 --diagnose 时间线里直接可见（P3）。
// **SIGKILL / 外部击杀不会留下任何记录** —— 审计上「launch 无配对 exit」
// 即外部击杀实证（2026-09-06 排查 83091/84552/41369 秒死时最大的取证缺口：
// 进程怎么死的完全无痕）。
//
// 格式：JSONL，一行一个 JSON 对象；解析对坏行容错（Doctor 侧跳过）。
// 路径走 diagnosticFilePath 角色隔离：仅主应用写规范 exits.jsonl，
// TestRunner 等派生二进制写各自后缀文件，互不污染。

enum ExitJournal {

    static var filePath: String {
        diagnosticFilePath(
            base: NSHomeDirectory() + "/Library/Logs/VibeFocus/exits.jsonl",
            processName: ProcessInfo.processInfo.processName
        )
    }

    /// 已写过退出记录标记：显式 recordExit 后，atexit 的兜底 clean 记录不再重复写。
    /// 信号路径不走 atexit（SIG_DFL + raise 直接终止），与此标记无竞态。
    nonisolated(unsafe) private static var hasRecordedExit = false

    // MARK: - 编码（pure，供镜像测试）

    static func jsonEscape(_ s: String) -> String {
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

    static func timestamp(_ date: Date = Date()) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        return df.string(from: date)
    }

    static func launchLine(
        pid: Int32,
        at: String,
        exe: String,
        exeMtimeEpoch: Int?,
        exeInode: UInt64?,
        bundleID: String?,
        version: String?,
        axTrusted: Bool?
    ) -> String {
        var line = "{\"kind\":\"launch\",\"pid\":\(pid),\"at\":\"\(jsonEscape(at))\""
        line += ",\"exe\":\"\(jsonEscape(exe))\""
        if let m = exeMtimeEpoch { line += ",\"exeMtime\":\(m)" }
        if let i = exeInode { line += ",\"exeInode\":\(i)" }
        if let b = bundleID { line += ",\"bundle\":\"\(jsonEscape(b))\"" }
        if let v = version { line += ",\"version\":\"\(jsonEscape(v))\"" }
        if let ax = axTrusted { line += ",\"ax\":\(ax)" }
        line += "}"
        return line
    }

    static func exitLine(
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

    /// 信号处理器专用：预编码为 C 字符串（无时间戳——崩溃时刻由写入时刻的
    /// 文件位置与 crash-fatal 归档 mtime 承载），供 handler 一次 write 落盘。
    static func cCharLineForSignal(pid: Int32, signal: Int32, name: String) -> [CChar] {
        let line = exitLine(pid: pid, at: "-", reason: "fatal-signal", signal: signal, name: name) + "\n"
        var chars = Array(line.utf8CString)
        chars.removeLast()  // 去掉 utf8CString 尾部 NUL，按精确长度 write
        return chars
    }

    // MARK: - 写入

    static func appendLine(_ line: String) {
        let path = filePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let payload = line + "\n"
        payload.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
        close(fd)
    }

    /// 信号处理器专用：安装期打开一次审计 FD（O_APPEND），handler 内只 write 不再构造。
    static func openAppendFD() -> Int32 {
        let path = filePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    /// 启动记录：应尽早在 applicationDidFinishLaunching 调用（越早，后续任何
    /// 死法都能与「本实例存在过」对上账）。axTrusted 一并落账——重装替换二进制
    /// 后辅助功能授权失效（2026-09-06 实锤），ax 时间线让失效时刻可归因。
    static func recordLaunch(bundleID: String?, version: String?, exePath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        var mtime: Int?
        var inode: UInt64?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: exePath) {
            let mtimeKey = FileAttributeKey.modificationDate
            // NSFileSystemFileNumber = inode；Foundation 无 .inodeNumber 便捷成员
            let inodeKey = FileAttributeKey(rawValue: "NSFileSystemFileNumber")
            if let d = attrs[mtimeKey] as? Date { mtime = Int(d.timeIntervalSince1970) }
            if let n = attrs[inodeKey] as? NSNumber { inode = n.uint64Value }
        }
        appendLine(launchLine(
            pid: pid,
            at: timestamp(),
            exe: exePath,
            exeMtimeEpoch: mtime,
            exeInode: inode,
            bundleID: bundleID,
            version: version,
            axTrusted: AXIsProcessTrusted()
        ))
    }

    /// 退出记录：reason 如 "clean" / "lock-failed-terminate" / "reuse-existing-activate"。
    static func recordExit(reason: String, signal: Int32? = nil, name: String? = nil) {
        hasRecordedExit = true
        appendLine(exitLine(
            pid: ProcessInfo.processInfo.processIdentifier,
            at: timestamp(),
            reason: reason,
            signal: signal,
            name: name
        ))
    }

    /// atexit 兜底：未被显式路径标记过（即正常 Quit / 正常 exit）写 clean。
    static func recordCleanExitIfUnrecorded() {
        guard !hasRecordedExit else { return }
        recordExit(reason: "clean")
    }
}

/// AppEntry（--crash-test-signal）跨模块入口：安装信号处理器 + 写启动审计。
public enum VibeFocusCrashPipeline {
    public static func installHandlers() {
        installCrashSignalHandlers()
    }

    public static func recordTestLaunch(bundleID: String, version: String, exePath: String) {
        ExitJournal.recordLaunch(bundleID: bundleID, version: version, exePath: exePath)
    }
}
