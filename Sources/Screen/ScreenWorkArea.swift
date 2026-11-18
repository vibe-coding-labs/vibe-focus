import AppKit
import Foundation

// ScreenWorkArea.swift
// VibeFocus — 屏幕工作区规划的唯一入口（AppKit 适配层）
//
// 分层：
//   - 纯算法在 `DisplayWorkArea`（CoreGraphics/Foundation，无 AppKit）：
//     learnedInsets / plannedFrame / inferInsets / probedInsets / store；
//   - 本类型只做「NSScreen → (Quartz visibleFrame, displayID)」适配并按同一口径
//     合成 Plan，避免 TerminalGrid 编排、Layout 快捷键两处各自拼
//     `quartzVisibleFrame + learnedInsets + plannedFrame`，改口径时漏改一处。
//
// Plan 同时保留原始 visibleFrame 与 learnedInsets：编排侧的探测写必须用原始
// visibleFrame 作 probeTarget，学习叠加也要在 learnedInsets 上 merged。

enum ScreenWorkArea {

    /// 一次解算结果。
    struct Plan: Equatable {
        /// 屏幕原始 Quartz visibleFrame（未扣保留区；探测写用）
        let visibleFrame: CGRect
        /// 屏的 CGDirectDisplayID；缺失（极罕见）按 0 处理，与历史调用一致
        let displayID: UInt32
        /// 该屏已学习保留区
        let learnedInsets: WorkAreaInsets
        /// visibleFrame 扣 learnedInsets 后的规划帧
        let planningFrame: CGRect
    }

    /// 纯解算（无 AppKit）：visibleFrame + displayID + 保留区缓存 → Plan。
    /// 默认值与测试均可直接注入，不依赖真机屏幕。
    static func plan(
        visibleFrame: CGRect,
        displayID: UInt32,
        defaults: UserDefaults = .standard
    ) -> Plan {
        let insets = DisplayWorkArea.learnedInsets(displayID: displayID, defaults: defaults)
        return Plan(
            visibleFrame: visibleFrame,
            displayID: displayID,
            learnedInsets: insets,
            planningFrame: DisplayWorkArea.plannedFrame(visibleFrame: visibleFrame, insets: insets)
        )
    }

    /// NSScreen 适配：一次取 Quartz visibleFrame 与 displayID，走同一解算。
    static func plan(for screen: NSScreen, defaults: UserDefaults = .standard) -> Plan {
        plan(
            visibleFrame: CoordinateKit.quartzVisibleFrame(of: screen),
            displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0,
            defaults: defaults
        )
    }
}
