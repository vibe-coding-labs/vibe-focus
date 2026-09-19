import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionActivityWriteTests.swift — 覆盖率批次 50（B286）：
// SessionActivityTracker.writeToFile 原子写直测（tmp+move 原子替换语义）。
// 快照-恢复协议：写前备份现有生产快照文件，断言后还原（该文件仅 --diagnose
// 消费，非运行时状态，瞬态覆盖无碍但仍按协议还原）。

extension RunnerHarness {
    func runSessionActivityWriteTests() {
        let storeURL = SessionActivityTracker.storeURL
        let backupPath = NSTemporaryDirectory() + "b286-session-activity-backup.json"
        // 备份现有文件（若有）
        let hadExisting = FileManager.default.fileExists(atPath: storeURL.path)
        if hadExisting {
            try? FileManager.default.copyItem(atPath: storeURL.path, toPath: backupPath)
        }
        defer {
            if hadExisting, FileManager.default.fileExists(atPath: backupPath) {
                _ = try? FileManager.default.replaceItemAt(storeURL, withItemAt: URL(fileURLWithPath: backupPath))
            } else {
                try? FileManager.default.removeItem(atPath: storeURL.path)
            }
            try? FileManager.default.removeItem(atPath: backupPath)
        }

        // 构造快照：两个会话活动（含 lastCode 可选字段）
        let snapshot: [String: SessionActivity] = [
            "b286-sess-1": SessionActivity(lastEvent: .stop, at: Date(timeIntervalSince1970: 1_790_000_000), lastCode: nil),
            "b286-sess-2": SessionActivity(lastEvent: .userPromptSubmit, at: Date(timeIntervalSince1970: 1_790_000_100), lastCode: "0"),
        ]

        // writeToFile：原子写（tmp+move）
        SessionActivityTracker.writeToFile(snapshot: snapshot)

        // 读回验证：文件存在且内容与写入一致
        let restored = FileManager.default.fileExists(atPath: storeURL.path)
            ? SessionActivityTracker.parseActivities(data: (try? Data(contentsOf: URL(fileURLWithPath: storeURL.path))) ?? Data()) ?? [:]
            : [:]
        check("sessionActivity: writeToFile 原子写后 parse 往返一致",
              restored.count == snapshot.count
              && restored["b286-sess-1"]?.lastEvent == .stop
              && restored["b286-sess-2"]?.lastCode == "0")

        // 空快照写入：文件存在但 sessions 为空（原子写语义）
        SessionActivityTracker.writeToFile(snapshot: [:])
        let empty = FileManager.default.fileExists(atPath: storeURL.path)
            ? SessionActivityTracker.parseActivities(data: (try? Data(contentsOf: URL(fileURLWithPath: storeURL.path))) ?? Data()) ?? [:]
            : [:]
        check("sessionActivity: 空快照原子写往返为空字典", empty.isEmpty)

        // 还原：删除测试写的文件，恢复原备份
        try? FileManager.default.removeItem(atPath: storeURL.path)
        if hadExisting, FileManager.default.fileExists(atPath: backupPath) {
            try? FileManager.default.copyItem(atPath: backupPath, toPath: storeURL.path)
        }
        try? FileManager.default.removeItem(atPath: backupPath)
    }
}
