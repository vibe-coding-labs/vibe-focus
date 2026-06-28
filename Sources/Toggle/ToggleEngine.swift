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
        // P-INST-267: 显示器数量计算属性（NSScreen.screens.count 读 + max(...,1) 保证 ≥1；toggle 入口判断单屏/多屏调用，NSScreen.screens 可能阻塞 WindowServer；slow-op ≥30ms warn）。
        let dcStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: dcStart)
            if durMs >= 30 { log("[ToggleEngine] displayCount slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        return max(NSScreen.screens.count, 1)
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
        // P-INST-231: toggle record 保存编排端到端耗时（NSScreen.screens 主屏验证 + shouldRejectSave + ToggleRecord 构造 + store.saveToggleRecord SQLite 写 P-INST-17/P-INST-202；toggle 热路径每次调用，区分 NSScreen/构造 vs SQLite dbMs）。
        let saveTotalStart = Date()
        defer {
            log("[ToggleEngine] save finished", level: .debug, fields: ["windowID": String(windowID), "durationMs": String(elapsedMilliseconds(since: saveTotalStart))])
        }
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

        // P-INST-17: save SQLite 写耗时（saveMs 外部已记 moveWindowToMainScreen 的 saveMs 总耗时，此处拆 store.saveToggleRecord 的 SQLite 成本）。
        let saveDbStart = Date()
        store.saveToggleRecord(record)
        let saveDbMs = elapsedMilliseconds(since: saveDbStart)

        log("ToggleEngine.save", level: .info, fields: [
            "windowID": String(windowID),
            "sourceSpace": String(describing: sourceSpace.yabaiIndex ?? 0),
            "sourceDisplay": String(describing: sourceDisplay.yabaiIndex ?? 0),
            "sourceYabaiDisp": String(describing: sourceYabaiDisp.yabaiIndex ?? 0),
            "sourceDispSpace": String(sourceDispSpace),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))",
            "dbMs": String(saveDbMs)
        ])
    }

    // MARK: - Load (UserPromptSubmit 触发)

    /// 按 windowID 读取 toggle record
    func load(windowID: UInt32) -> ToggleRecord? {
        // P-INST-18: load SQLite 读耗时（shouldRestore decisionMs 内部的 SQLite 成本，应 <2ms）。
        let loadStart = Date()
        let record = store.loadToggleRecord(windowID: windowID)
        log("[ToggleEngine] load", level: .debug, fields: [
            "windowID": String(windowID),
            "dbMs": String(elapsedMilliseconds(since: loadStart)),
            "found": String(record != nil)
        ])
        return record
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

    // MARK: - Synthetic Record (UPS fallback)

    /// 为没有 ToggleRecord 的窗口创建合成记录 — 使用第一个非主屏作为 restore 目标
    /// 用于 UserPromptSubmit fallback：窗口在主屏但无历史位置记录时，将窗口移到副屏
    func createSyntheticToggleRecord(
        windowID: UInt32,
        pid: Int32,
        bundleIdentifier: String?,
        appName: String?
    ) -> ToggleRecord? {
        // P-INST-211: 合成 toggle record 创建耗时（NSScreen.screens x2 枚举显示器 + CoordinateKit.quartzVisibleFrame x2；UserPromptSubmit UPS fallback 路径，窗口在主屏无历史记录时调用；NSScreen.screens 可能阻塞；slow-op ≥30ms warn）。
        let cstrStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: cstrStart)
            if durMs >= 30 { log("[ToggleEngine] createSyntheticToggleRecord slow", level: .warn, fields: ["windowID": String(windowID), "durationMs": String(durMs)]) }
        }
        guard let secondaryScreen = NSScreen.screens.first(where: { $0.frame.origin != .zero }) else {
            log("[ToggleEngine] createSyntheticToggleRecord: no secondary screen found", level: .warn, fields: [
                "windowID": String(windowID),
                "screenCount": String(NSScreen.screens.count)
            ])
            return nil
        }

        guard let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            log("[ToggleEngine] createSyntheticToggleRecord: no main screen found", level: .warn, fields: [
                "windowID": String(windowID)
            ])
            return nil
        }

        let origFrame = CoordinateKit.quartzVisibleFrame(of: secondaryScreen)
        let targetFrame = CoordinateKit.quartzVisibleFrame(of: mainScreen)

        let record = ToggleRecord(
            windowID: windowID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            origFrame: origFrame,
            sourceSpace: 0,
            sourceDisplay: 0,
            sourceYabaiDisp: 0,
            sourceDispSpace: 0,
            targetFrame: targetFrame,
            targetDisplay: 0,
            toggledAt: Date(),
            sessionID: nil
        )

        guard record.isValid(mainScreenFrame: mainScreen.frame) else {
            log("[ToggleEngine] createSyntheticToggleRecord: synthetic record failed validation", level: .warn, fields: [
                "windowID": String(windowID),
                "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
                "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y))"
            ])
            return nil
        }

        store.saveToggleRecord(record)

        log("[ToggleEngine] createSyntheticToggleRecord: saved", level: .info, fields: [
            "windowID": String(windowID),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.size.width))x\(Int(origFrame.size.height))",
            "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)) \(Int(targetFrame.size.width))x\(Int(targetFrame.size.height))"
        ])

        return record
    }

}
