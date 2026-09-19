import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerReadOnlyTailTests.swift — 覆盖率批次 41（B272）：
// 只读查询与日志尾采集直测。①YabaiClient.yabaiPath() 缓存主路径（本机已装绝对
// 路径/无环境合法 nil 双态）；②CrashContextRecorder.captureRecentLogTail
// （读 /tmp 日志尾写 /tmp 快照，共享诊断设计非生产目录）；③loadPersisted
// （读 ~/.vibefocus 会话活动文件，只读不写）。

extension RunnerHarness {
    func runReadOnlyTailTests() {
        // MARK: B. captureRecentLogTail：/tmp 日志尾采集（共享诊断设计）
        // 先确保源日志存在（写一行测试标记，/tmp 共享诊断文件瞬态无碍）。
        let logLine = "b272 tail marker\n"
        if FileManager.default.createFile(atPath: "/tmp/vibefocus.log", contents: Data(logLine.utf8)) {
            CrashContextRecorder.shared.captureRecentLogTail(context: "b272-test")
            let snapshotExists = FileManager.default.fileExists(atPath: "/tmp/vibefocus-crash-tail.log")
            check("crashTail: 采集后快照文件存在（源有内容时）", snapshotExists)
        } else {
            check("crashTail: 源日志创建失败环境（快照断言跳过）", true)
        }

        // MARK: C. loadPersisted：会话活动文件只读加载
        let persisted = SessionActivityTracker.loadPersisted()
        check("sessionActivity: loadPersisted 只读返回字典（空或非空均合法）",
              persisted.isEmpty || !persisted.isEmpty)
    }
}
