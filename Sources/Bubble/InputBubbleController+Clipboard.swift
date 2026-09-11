import AppKit

// Sources/Bubble/InputBubbleController+Clipboard.swift — B151 自 InputBubbleController.swift
// 按域拆出（逐字搬移零行为变更）：剪贴板快照写入与按纯决策恢复。
// 恢复决策在 InputBubbleClipboardPlan（RunnerInputBubbleTests 直测），本文件只做 NSPasteboard IO。

extension InputBubbleController {
    // MARK: 剪贴板快照 / 恢复

    func saveClipboardThenWrite(_ text: String) {
        let pb = NSPasteboard.general
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        if let pbi = pb.pasteboardItems {
            for item in pbi.prefix(5) {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types.prefix(10) {
                    if type.rawValue.hasPrefix("dyn.") { continue }
                    if let data = item.data(forType: type) { dict[type] = data }
                }
                if !dict.isEmpty { items.append(dict) }
            }
        }
        clipboardItems = items
        pb.clearContents()
        pb.setString(text, forType: .string)
        clipboardPostWriteCount = pb.changeCount
    }

    func restoreClipboardIfSafe() {
        guard clipboardPostWriteCount >= 0 else { return }
        let pb = NSPasteboard.general
        let shouldRestore = InputBubbleClipboardPlan.shouldRestore(
            postWriteCount: clipboardPostWriteCount,
            currentCount: pb.changeCount
        )
        clipboardPostWriteCount = -1
        guard shouldRestore else {
            log("[InputBubble] clipboard changed during injection, skip restore", level: .debug)
            clipboardItems = []
            return
        }
        pb.clearContents()
        for dict in clipboardItems {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
        clipboardItems = []
        log("[InputBubble] clipboard restored", level: .debug)
    }
}
