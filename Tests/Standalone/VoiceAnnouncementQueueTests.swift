// Tests/Standalone/VoiceAnnouncementQueueTests.swift
// Verification: 多会话播报队列入队策略（有界、丢最旧、FIFO、值语义）+ 模板空文本兜底
// Mirrors: Sources/App/VoiceAnnouncementPreferences.swift (QueuedAnnouncement/VoiceAnnouncementQueuePolicy),
//          Sources/App/VoiceAnnouncementManager.swift (announceCompletion 模板兜底规则)
// Run: swift Tests/Standalone/VoiceAnnouncementQueueTests.swift

import Foundation

// MARK: - Mirrored types

enum QueuedAnnouncement: Equatable {
    case text(String)
    case audioFile(path: String)
}

enum VoiceAnnouncementQueuePolicy {
    static func appendedQueue(
        _ current: [QueuedAnnouncement],
        appending item: QueuedAnnouncement,
        capacity: Int
    ) -> [QueuedAnnouncement] {
        var next = current
        let effectiveCapacity = max(capacity, 1)
        while next.count >= effectiveCapacity {
            next.removeFirst()
        }
        next.append(item)
        return next
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let cap3 = 3 // 与 Sources 的 maxQueuedAnnouncements 对齐

print("1. appendedQueue — 基础入队")
do {
    let q0: [QueuedAnnouncement] = []
    let q1 = VoiceAnnouncementQueuePolicy.appendedQueue(q0, appending: .text("a"), capacity: cap3)
    check("空队入队 → 长度 1", q1.count == 1)
    check("空队入队 → 队首为 a", q1.first == .text("a"))

    let q2 = VoiceAnnouncementQueuePolicy.appendedQueue(q1, appending: .text("b"), capacity: cap3)
    let q3 = VoiceAnnouncementQueuePolicy.appendedQueue(q2, appending: .audioFile(path: "/x/y.wav"), capacity: cap3)
    check("未满容量 → 全部保留", q3.count == 3)
    check("FIFO 顺序保持", q3 == [.text("a"), .text("b"), .audioFile(path: "/x/y.wav")])
}

print("2. appendedQueue — 满队丢最旧")
do {
    var q: [QueuedAnnouncement] = [.text("a"), .text("b"), .text("c")]
    q = VoiceAnnouncementQueuePolicy.appendedQueue(q, appending: .text("d"), capacity: cap3)
    check("满队入队 → 长度仍 3", q.count == 3)
    check("最旧的 a 被丢弃", !q.contains(.text("a")))
    check("剩余顺序保持 b,c,d", q == [.text("b"), .text("c"), .text("d")])

    q = VoiceAnnouncementQueuePolicy.appendedQueue(q, appending: .text("e"), capacity: cap3)
    check("再次溢出 → 继续丢最旧", q == [.text("c"), .text("d"), .text("e")])
}

print("3. appendedQueue — 容量边界与值语义")
do {
    var q: [QueuedAnnouncement] = [.text("old")]
    let out = VoiceAnnouncementQueuePolicy.appendedQueue(q, appending: .text("new"), capacity: 1)
    check("capacity=1 → 只留最新", out == [.text("new")])
    check("入参未被修改（值语义）", q == [.text("old")])

    let q0: [QueuedAnnouncement] = []
    let out0 = VoiceAnnouncementQueuePolicy.appendedQueue(q0, appending: .text("x"), capacity: 0)
    check("capacity=0 防御 → 按 1 处理，新条目保留", out0 == [.text("x")])
}

print("4. 模板空文本兜底规则（announceCompletion template 分支镜像）")
do {
    func resolvedText(_ interpolated: String) -> String {
        interpolated.isEmpty ? "对话完成" : interpolated
    }
    check("非空模板原样播报", resolvedText("vibe-focus 完成") == "vibe-focus 完成")
    check("空模板兜底「对话完成」", resolvedText("") == "对话完成")
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
