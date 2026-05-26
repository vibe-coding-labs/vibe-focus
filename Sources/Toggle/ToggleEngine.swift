import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

/// Toggle Engine — 窗口 toggle/restore 的单一入口
///
/// 设计原则：
/// 1. 单一事实来源：所有 toggle state 只存 SQLite `windows` 表，不缓存到内存
/// 2. 确定性查找：用 windowID 直接查 SQLite，不走 PID/TTY/PPID 猜测链
/// 3. 原子操作：save 是一次 SQLite UPDATE，read 是一次 SELECT
@MainActor
final class ToggleEngine: ToggleRecordStore {

    static let shared = ToggleEngine()
    private init() {}

    private var store: WindowStateStore { WindowStateStore.shared }

    var displayCount: Int {
        max(NSScreen.screens.count, 1)
    }

    // MARK: - Save Validation (extracted for testability)

    /// Pure decision: should a save be rejected because origFrame is on the main screen?
    static func shouldRejectSave(origFrame: CGRect, mainScreenFrame: CGRect?) -> Bool {
        guard let mainScreenFrame else { return false }
        let origCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
        return mainScreenFrame.contains(origCenter)
    }

    // MARK: - Save (Ctrl+Q 触发)

    /// 保存 toggle 快照 — 在 moveWindowToMainScreen 成功后调用
    func save(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?,
        origFrame: CGRect,
        sourceSpace: SpaceIdentifier,
        sourceDisplay: DisplayIdentifier,
        sourceYabaiDisp: DisplayIdentifier,
        sourceDispSpace: Int,
        targetFrame: CGRect,
        targetDisplay: Int,
        sessionID: String?
    ) {
        // 验证 origFrame 不在主屏上 — 如果 origFrame 在主屏，说明数据异常
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        if Self.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen?.frame) {
            log(
                "[ToggleEngine] save rejected: origFrame is on main screen (corrupted data)",
                level: .warn,
                fields: [
                    "windowID": String(windowID),
                    "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
                    "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))",
                    "sourceSpace": String(describing: sourceSpace),
                    "sourceYabaiDisp": String(describing: sourceYabaiDisp)
                ]
            )
            return
        }

        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: sourceSpace.yabaiIndex ?? 0,
            sourceDisplay: sourceDisplay.yabaiIndex ?? 0,
            sourceYabaiDisp: sourceYabaiDisp.yabaiIndex ?? 0,
            sourceDispSpace: sourceDispSpace,
            targetFrame: targetFrame,
            targetDisplay: targetDisplay,
            toggledAt: Date(),
            sessionID: sessionID
        )

        store.saveToggleRecord(record)

        log("ToggleEngine.save", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(describing: sourceSpace.yabaiIndex ?? 0),
            "sourceDisplay": String(describing: sourceDisplay.yabaiIndex ?? 0),
            "sourceYabaiDisp": String(describing: sourceYabaiDisp.yabaiIndex ?? 0),
            "sourceDispSpace": String(sourceDispSpace),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])
    }

    // MARK: - Load (UserPromptSubmit 触发)

    /// 按 windowID 读取 toggle record
    func load(windowID: UInt32) -> ToggleRecord? {
        return store.loadToggleRecord(windowID: windowID)
    }

    /// 按 PID 读取最近的 toggle record（CGWindowNumber 变化时的 fallback）
    func loadByPID(pid: Int32) -> ToggleRecord? {
        return store.loadToggleRecordByPID(pid: pid)
    }

    // MARK: - Clear (Restore 后或窗口关闭时)

    /// 清除 toggle state
    func clear(windowID: UInt32) {
        store.clearToggleRecord(windowID: windowID)
        log("ToggleEngine.clear", fields: ["windowID": String(windowID)])
    }

}
