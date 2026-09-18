// InputBubbleArrivalMover.swift
// VibeFocus — 「窗口到达主屏」的移动者归因（B211）
// 用户主诉：气泡莫名其妙自动弹出，识别不精准。取证（2026-09-19 生产日志）：
// 16 次 move-to-main 自动弹出里 14 次紧跟用户自己的 ⌃Q 拉窗（reason=manual_hotkey，
// 间隔 0.1~0.5s），仅 2 次真正被用来打字——「用户摆位/查看」被当成「要输入」。
// 根治=到达弹出按移动者归因分流：只有 hook 拉回（agent「我需要你」语义）可弹，
// 用户手动移动与外部移动（并行会话 yabai/拖动/显示器重排）静默落基线。

import Foundation

enum InputBubbleArrivalMover: Equatable {
    case hookPull     // hook 拉回（Stop 会话结束自动拉回）：agent 主动召唤 → 可弹
    case userAction   // 用户/其它来源移动（⌃Q 摆位、拖动、外部 yabai、显示器重排）→ 不弹

    /// WindowMoveReason → 移动者分类。userPromptSubmit 路径已随 B126 退役（UPS 永不搬窗），
    /// 保守归为 userAction：宁可不弹，不可误弹。
    static func map(_ reason: WindowMoveReason) -> InputBubbleArrivalMover {
        switch reason {
        case .claudeSessionEnd: return .hookPull
        case .manualHotkey, .userPromptSubmit: return .userAction
        }
    }
}

/// 归因账本：moveWindowToMainScreen 成功移动时记账（可能在 WindowWorkExecutor 后台
/// 线程写），InputBubbleAutoShow tick（主线程）读——NSLock 互斥（MoveCooldownRegistry 同款）。
/// 容量 32 FIFO，防长会话无界增长；新鲜期 10s（tick 1s 节拍 + 移动管线的可见性滞后）。
final class MoveToMainAttributionLedger: @unchecked Sendable {
    static let shared = MoveToMainAttributionLedger()
    static let freshnessSeconds: TimeInterval = 10
    static let capacity = 32

    private struct Entry {
        let mover: InputBubbleArrivalMover
        let at: Date
    }

    private var entries: [UInt32: Entry] = [:]
    private var order: [UInt32] = []
    private let lock = NSLock()

    private init() {}

    func record(windowID: UInt32, mover: InputBubbleArrivalMover, at: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if entries[windowID] == nil {
            order.append(windowID)
            while order.count > MoveToMainAttributionLedger.capacity {
                let evict = order.removeFirst()
                entries.removeValue(forKey: evict)
            }
        }
        entries[windowID] = Entry(mover: mover, at: at)
    }

    /// 新鲜期内的移动者归类；过期/无记录返回 nil（=外部移动，不可弹）。
    func recentMover(
        windowID: UInt32,
        now: Date = Date(),
        freshness: TimeInterval = MoveToMainAttributionLedger.freshnessSeconds
    ) -> InputBubbleArrivalMover? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[windowID] else { return nil }
        guard now.timeIntervalSince(entry.at) <= freshness else { return nil }
        return entry.mover
    }
}
