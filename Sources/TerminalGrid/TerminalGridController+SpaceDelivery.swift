import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格 · Space 投递（2026-09-07 从 TerminalGridController 拆分，行为不变）
// AppleScript 建窗落点由终端 app 自己的活跃 space 决定，与系统视角脱节（真机实证）。
// 逐窗按 SpaceDeliveryDecision 决策，错位的走「泊到另一屏 → 写回目标格位」跨屏往返。

extension TerminalGridController {

    /// 单窗投递决策（纯函数，Standalone GridSpaceDeliveryTests 锁定）。
    enum SpaceDeliveryDecision: Equatable {
        case notNeeded              // 已在目标 space
        case notApplicable          // 非显式 space 目标（display 级 / 主屏 / 焦点屏）
        case skipNoYabai            // yabai 不可用，无法验证也无通道
        case skipNoParkingDisplay   // 单屏机：无泊位屏，同屏错位无法往返
        case skipViewNotOnTarget    // 目标屏当前没显示目标 space（视角切换失败场景）
        case deliverCrossDisplay    // 窗口在其它屏：一次跨屏 frame 直写即入目标屏可见 space
        case deliverRoundTrip       // 窗口在目标屏但错位 space：泊到其它屏 → 写回
    }

    /// 输入全部由调用方真值采集；nil 语义见各参数注释。
    static func spaceDeliveryDecision(
        targetSpaceIndex: Int?,           // nil = 非显式 space 目标
        targetDisplayVisibleSpace: Int?,  // 目标屏当前可见 space；nil = yabai 不可用
        targetDisplayIndex: Int?,         // 目标屏 yabai display index
        windowDisplayIndex: Int?,         // 窗口当前所在 display；nil = 查询失败
        hasParkingDisplay: Bool,          // 存在其它显示器
        windowSpaceIndex: Int?            // 窗口当前 space；nil = 查询失败（按需投递）
    ) -> SpaceDeliveryDecision {
        guard let targetSpaceIndex else { return .notApplicable }
        guard let visible = targetDisplayVisibleSpace else { return .skipNoYabai }
        guard visible == targetSpaceIndex else { return .skipViewNotOnTarget }
        guard let windowSpaceIndex, windowSpaceIndex == targetSpaceIndex else {
            // 同屏错位需要往返（泊位屏）；跨屏直写不需要
            if windowDisplayIndex == targetDisplayIndex, !hasParkingDisplay {
                return .skipNoParkingDisplay
            }
            if windowDisplayIndex == targetDisplayIndex {
                return .deliverRoundTrip
            }
            return .deliverCrossDisplay
        }
        return .notNeeded
    }

    /// 建窗后 Space 投递：AppleScript 建窗的落点由终端 app 自己的活跃 space 决定，
    /// 与系统视角脱节（真机实证）。逐窗读 yabai space，错位的走「泊到另一屏 →
    /// 写回目标格位」：窗口跨 display 移动必入「目标 display 当前可见 space」，
    /// 而此刻目标屏正显示目标 space。返回 (attempted, delivered, parkingUnavailable)。
    func deliverCellsToTargetSpace(
        windowIDs: [UInt32],
        frames: [CGRect],
        screen: NSScreen,
        op: String
    ) async -> (attempted: Int, delivered: Int, parkingUnavailable: Bool) {
        guard case .displaySpace(_, let spaceIndex) = GridTargetCode.parse(TerminalGridPreferences.target) ?? .main else {
            return (0, 0, false)
        }
        guard let targetDisplayIndex = CoordinateKit.yabaiDisplayIndex(for: screen) else {
            return (0, 0, false)
        }
        guard let parkingScreen = NSScreen.screens.first(where: {
            CoordinateKit.yabaiDisplayIndex(for: $0) != targetDisplayIndex
        }) else {
            log("[TerminalGrid] createGrid space delivery unavailable: single display", fields: [
                "op": op, "space": String(spaceIndex)
            ])
            return (0, 0, true)
        }
        let parkingBase = CoordinateKit.quartzVisibleFrame(of: parkingScreen)
        var attempted = 0
        var delivered = 0
        func pollSpace(_ windowID: UInt32, equals target: Int, budgetSeconds: Double) async -> Bool {
            let deadline = Date().addingTimeInterval(budgetSeconds)
            while Date() < deadline {
                if let after = SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true),
                   after.space == target {
                    return true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return false
        }

        for (index, windowID) in windowIDs.enumerated() where index < frames.count {
            // 目标屏可见 space 若被激活拖拽等拉走，先拉回（Space 上已有的
            // 已投递窗口天然成为 refocus 候选）
            if activeSpaceIndex(for: screen) != spaceIndex {
                _ = SpaceController.shared.refocusWindowOnSpace(spaceIndex, operationID: op)
            }
            let visible = activeSpaceIndex(for: screen)
            let info = SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true)
            let decision = Self.spaceDeliveryDecision(
                targetSpaceIndex: spaceIndex,
                targetDisplayVisibleSpace: visible,
                targetDisplayIndex: targetDisplayIndex,
                windowDisplayIndex: info?.display,
                hasParkingDisplay: true,
                windowSpaceIndex: info?.space
            )
            guard decision == .deliverCrossDisplay || decision == .deliverRoundTrip else {
                continue
            }
            attempted += 1
            let frame = frames[index]
            let parkFrame = CGRect(
                x: parkingBase.minX + 40,
                y: parkingBase.minY + 40,
                width: min(frame.width, max(parkingBase.width - 80, 200)),
                height: min(frame.height, max(parkingBase.height - 80, 120))
            )
            // 裸 yabai 序列（真机实验八验证的通道）：float 脱管 → park → settle →
            // 写回 move+resize。不走 placeWindow：其 AX resize 通道 + 300ms 双段
            // 验证会被 iTerm2 的窗口自动恢复行为吞掉（move 已发但 frame 回弹）。
            // 前置：新建窗口的 yabai AX reference 懒建立（实测 1-3s），未建立时
            // float/move 全部静默失效（unmanaged），必须轮询等到位。
            let axDeadline = Date().addingTimeInterval(3)
            var axReady = false
            while Date() < axDeadline {
                if SpaceController.shared.queryWindow(windowID: windowID, ignoreCache: true)?.isManageableByYabai == true {
                    axReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard axReady else {
                log("[TerminalGrid] delivery skip: window never became yabai-managed", level: .warn, fields: [
                    "op": op, "windowID": String(windowID)
                ])
                continue
            }
            _ = SpaceController.shared.setWindowFloat(windowID, operationID: op)
            if decision == .deliverRoundTrip {
                // 窗在目标屏但错位 space（同 display 不可见 space）：frame 直写无法
                // 跨 space，先泊到其它屏——写回时目标屏正显示目标 space
                _ = SpaceController.shared.runYabai(
                    arguments: ["-m", "window", "\(windowID)", "--move", "abs:\(Int(parkFrame.origin.x)):\(Int(parkFrame.origin.y))"],
                    operation: "delivery.park(windowID=\(windowID))", operationID: op
                )
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            // 写回：crossDisplay 直写目标格位、roundTrip 从泊位写回，跨屏归属
            // 切换都落入「目标屏当前可见 space」= 目标 space
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(windowID)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "delivery.writeback.move(windowID=\(windowID))", operationID: op
            )
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(windowID)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "delivery.writeback.resize(windowID=\(windowID))", operationID: op
            )
            if await pollSpace(windowID, equals: spaceIndex, budgetSeconds: 5.0) {
                delivered += 1
            }
        }
        if attempted > 0 {
            log("[TerminalGrid] createGrid space delivery", fields: [
                "op": op,
                "attempted": String(attempted),
                "delivered": String(delivered),
                "space": String(spaceIndex)
            ])
        }
        return (attempted, delivered, false)
    }

}
