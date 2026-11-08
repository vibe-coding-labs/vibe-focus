import AppKit
import Foundation

// MARK: - 输入气泡 · 历史翻阅与面板（B319 拆分，行为不变）
// B196 历史面板入口 + B195/B203 ↑↓ 翻阅族整体逐字搬移自 InputBubbleController.swift；
// applyHistoryNav/setNavText 的 private 放宽 internal（跨文件访问，B151 拆分惯例）；
// 存储属性（historyNavIndex/historyStashedText）留类体。
extension InputBubbleController {
    // MARK: 历史面板（B196）

    /// 气泡上的「历史」入口：打开/聚焦历史面板（默认按当前绑定窗过滤）。
    func showHistoryPanel() {
        guard let bubbleFrame = panel?.frame else { return }
        InputBubbleHistoryPanelController.shared.toggle(
            anchorFrame: bubbleFrame,
            currentWindowID: target?.windowID,
            fill: { [weak self] text in
                self?.fillFromHistory(text)
            }
        )
    }

    /// ⌘Y（B204）：唤出/收回历史面板，返回 true=已消费。
    /// 气泡焦点态走这里；面板焦点态（搜索框打字中）由面板本地监视器同键收回，
    /// 两侧互斥接收、各收各的，不会双 toggle。
    func toggleHistoryPanel() -> Bool {
        guard phase == .open, panel != nil else { return false }
        showHistoryPanel()
        return true
    }

    /// 面板「填充」：把历史文本回填进打开中的气泡（替换全文），基线同步推进
    /// （防脏守卫/干净关闭语义把回填误判为用户新输入）。
    /// B203 防蒸发：覆盖前若现场是用户改动过的非空白文本，先落一条草稿历史——
    /// 正在输入的草稿不再被回填静默顶掉。
    func fillFromHistory(_ text: String) {
        guard phase == .open, let textView else { return }
        if let target,
           InputBubbleFillGuard.shouldPreserveCurrent(
            currentText: textView.string, baseText: lastRestoredBaseText) {
            InputBubbleHistoryStore.shared.record(
                textView.string,
                windowID: target.windowID,
                windowTitle: target.title,
                status: .draft
            )
        }
        textView.string = text
        lastRestoredBaseText = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if let target {
            InputBubbleDraftStore.shared.save(text, for: target.windowID)
        }
        (panel?.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
        refocusPanel()
        log("[InputBubble] history filled into bubble", fields: [
            "windowID": target.map { String($0.windowID) } ?? "nil",
            "length": String(text.count)
        ])
    }

    // MARK: ↑↓ 输入历史翻阅（B195；B203 起口径=本窗优先，本窗无历史回落全部）

    /// ↑：逐条变旧。返回 true=已消费（textView 不再走 super 光标移动）。
    /// 首次进入翻阅自动 stash 现场文本；到最旧停住。
    func historyPrevious() -> Bool {
        guard phase == .open, let textView else { return false }
        let entries = InputBubbleHistoryFilter.navEntries(
            InputBubbleHistoryStore.shared.entries(),
            currentWindowID: target?.windowID
        )
        let action = InputBubbleHistoryNavPlan.up(currentIndex: historyNavIndex, entryCount: entries.count)
        return applyHistoryNav(action, entries: entries, textView: textView)
    }

    /// ↓：逐条变新；走出最新一条回编辑现场（stash 还原）。未在翻阅中=不消费。
    func historyNext() -> Bool {
        guard phase == .open, let textView else { return false }
        let entries = InputBubbleHistoryFilter.navEntries(
            InputBubbleHistoryStore.shared.entries(),
            currentWindowID: target?.windowID
        )
        let action = InputBubbleHistoryNavPlan.down(currentIndex: historyNavIndex, entryCount: entries.count)
        return applyHistoryNav(action, entries: entries, textView: textView)
    }

    func applyHistoryNav(
        _ action: InputBubbleHistoryNavPlan.Action,
        entries: [InputBubbleHistoryEntry],
        textView: NSTextView
    ) -> Bool {
        PerfMonitor.shared.measure("bubble.historyNav") {
            switch action {
            case .none:
                return
            case .moveTo(let index):
                guard index < entries.count else { return }
                if historyNavIndex == nil { historyStashedText = textView.string }
                historyNavIndex = index
                setNavText(entries[index].text, textView: textView)
            case .exitToStashed:
                historyNavIndex = nil
                setNavText(historyStashedText ?? "", textView: textView)
                historyStashedText = nil
            }
        }
        return action != .none
    }

    /// 翻阅换文本：草稿同步（programmatic set 不触发 textDidChange，手动落）
    /// + 光标跳尾 + 横向归零（B178 同款）。
    func setNavText(_ text: String, textView: NSTextView) {
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        if let target {
            InputBubbleDraftStore.shared.save(text, for: target.windowID)
        }
        (panel?.contentView as? BubbleCardView)?.normalizeHorizontalOrigin()
    }

    // MARK: 绑定跟随（B183：autoHide=false 默认模式——气泡跟目标窗走）
}
