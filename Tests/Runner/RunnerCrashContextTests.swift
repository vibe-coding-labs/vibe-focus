import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerCrashContextTests.swift — B216：CrashContextRecorder 可注入面直测
// （IPS 报文解析纯函数 / captureTail URL 注入 / 崩溃循环窗口判定 / appendEvent 滚动截断）。
// shared 单例的 state 全程快照-还原，不污染 /tmp 生产上下文。

extension RunnerHarness {
    func runCrashContextTests() {
        // ===== parseIPSJSONPayload：首行头 + JSON 载荷的 ips 格式 =====
        do {
            let good = CrashContextRecorder.parseIPSJSONPayload(
                from: #"{"app":"x"}"# + "\n" + #"{"captureTime":"2026-09-19","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"}}"#)
            check("crashCtx: 合法 ips 报文解析出载荷", good?["captureTime"] as? String == "2026-09-19")
            let exception = good?["exception"] as? [String: Any]
            check("crashCtx: 异常段可取", exception?["signal"] as? String == "SIGSEGV")

            check("crashCtx: 单行（无载荷行）→ nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: #"{"a":1}"#) == nil)
            check("crashCtx: 载荷非 JSON → nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: "header\nnot json at all") == nil)
            check("crashCtx: 空串 → nil",
                  CrashContextRecorder.parseIPSJSONPayload(from: "") == nil)

            // 实例包装版（含日志编排）
            let inst = CrashContextRecorder.shared
            check("crashCtx: parse+log 包装返回同载荷",
                  inst.parseIPSJSONPayloadAndLog(from: "h\n{\"k\":1}")?["k"] as? Int == 1)
        }

        // ===== captureTail：URL 注入，尾部 N 行落盘；源缺失静默跳过 =====
        do {
            let dir = "/tmp/vibefocus-cctx-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let source = URL(fileURLWithPath: dir + "/src.log")
            let output = URL(fileURLWithPath: dir + "/tail.log")
            do {
                try "l1\nl2\nl3\nl4\nl5".data(using: .utf8)!.write(to: source)
            } catch {
                check("crashCtx: 夹具源文件写入失败", false)
            }
            let inst = CrashContextRecorder.shared
            inst.captureTail(sourceURL: source, outputURL: output, lineLimit: 3, context: "test", label: "t")
            let tail = try? String(contentsOf: output, encoding: .utf8)
            check("crashCtx: captureTail 截尾 3 行保序", tail == "l3\nl4\nl5")

            // lineLimit 大于总行数 → 全文
            let outputAll = URL(fileURLWithPath: dir + "/all.log")
            inst.captureTail(sourceURL: source, outputURL: outputAll, lineLimit: 50, context: "test", label: "t")
            check("crashCtx: lineLimit 超总行数 → 全文",
                  (try? String(contentsOf: outputAll, encoding: .utf8)) == "l1\nl2\nl3\nl4\nl5")

            // 源文件不存在 → 不产出输出
            let missing = URL(fileURLWithPath: dir + "/missing.log")
            let output2 = URL(fileURLWithPath: dir + "/tail2.log")
            inst.captureTail(sourceURL: missing, outputURL: output2, lineLimit: 3, context: "test", label: "t")
            check("crashCtx: 源缺失 → 跳过不产出", !FileManager.default.fileExists(atPath: output2.path))
        }

        // ===== 崩溃循环窗口判定三分支（previousCrashFatalAt 快照-还原） =====
        do {
            let inst = CrashContextRecorder.shared
            let savedFatalAt = inst.previousCrashFatalAt
            defer { inst.previousCrashFatalAt = savedFatalAt }

            inst.previousCrashFatalAt = nil
            check("crashCtx: 无致命记录 → 不在崩溃循环", !inst.isWithinCrashLoopWindow())
            inst.previousCrashFatalAt = Date().addingTimeInterval(-10)
            check("crashCtx: 10s 前致命 → 在循环窗口", inst.isWithinCrashLoopWindow())
            inst.previousCrashFatalAt = Date().addingTimeInterval(-3600)
            check("crashCtx: 1h 前致命 → 出窗", !inst.isWithinCrashLoopWindow())
        }

        // ===== appendEventLocked：无 state 跳过 / 追加 / 超 300 滚动截断（state 快照-还原） =====
        do {
            let inst = CrashContextRecorder.shared
            inst.stateLock.lock()
            let savedState = inst.state
            inst.state = nil
            inst.stateLock.unlock()
            defer {
                inst.stateLock.lock()
                inst.state = savedState
                inst.stateLock.unlock()
            }

            inst.appendEventLocked("no-state-event")   // state nil → skip 分支
            inst.stateLock.lock()
            let stillNil = inst.state == nil
            inst.stateLock.unlock()
            check("crashCtx: 无 state 追加被跳过", stillNil)

            inst.stateLock.lock()
            inst.state = CrashContextRecorder.SessionState(
                pid: 1, launchedAt: "t", cleanExit: false, events: [], lastIngestedCrashReport: nil)
            inst.stateLock.unlock()
            for i in 0..<(300 + 5) {
                inst.appendEventLocked("e\(i)")
            }
            inst.stateLock.lock()
            let events = inst.state?.events ?? []
            inst.stateLock.unlock()
            check("crashCtx: 超限滚动截断保尾部 300 条",
                  events.count == 300 && events.first?.hasSuffix(" e5") == true
                  && events.last?.hasSuffix(" e304") == true)
        }
    }
}
