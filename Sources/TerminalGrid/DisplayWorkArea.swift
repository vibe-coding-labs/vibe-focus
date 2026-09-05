import CoreGraphics
import Foundation

// MARK: - 显示器实际可用区（学习型）
/// 真机实证（2026-09-06，P40UG 3440×1440 副屏）：`NSScreen.visibleFrame` 返回整屏
/// （不扣菜单栏），`auxiliaryTopLeftArea` 为 nil，但 WindowServer 与 yabai abs 写
/// 都进不了顶部 25px——窗口被钳到 y=-1415/h=1415。系统没有任何公开 API 报告
/// 这块保留区，按 visibleFrame 规划的网格顶行就会留出一条肉眼可见的空带。
///
/// 策略（零硬编码，任何机器任何屏自适应）：
/// 1. 规划用可用区 = visibleFrame 扣「已学习 insets」；
/// 2. 编排后用实际落点反推四边钳制量（纯函数 inferInsets），叠加进缓存并重排；
/// 3. 缓存非零时下次编排做一次探测写：能到达更靴边界就缩回 insets（菜单栏改
///    自动隐藏等设置变化后自愈）。
struct WorkAreaInsets: Codable, Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let zero = WorkAreaInsets(top: 0, left: 0, bottom: 0, right: 0)

    var isZero: Bool { self == .zero }

    /// 逐边取较大值（学习只会让保留区更保守，除非探测证明可缩回）
    func merged(with other: WorkAreaInsets) -> WorkAreaInsets {
        WorkAreaInsets(
            top: max(top, other.top),
            left: max(left, other.left),
            bottom: max(bottom, other.bottom),
            right: max(right, other.right)
        )
    }
}

enum DisplayWorkArea {

    static let defaultsKey = "displayWorkAreaInsets"

    /// 单边保留区合理上限（超过即视为异常读数，不学习）
    static let maxInset: CGFloat = 200
    /// 1px 取整抖动不算钳制
    static let noiseThreshold: CGFloat = 1.5

    // MARK: 缓存

    static func learnedInsets(displayID: UInt32, defaults: UserDefaults = .standard) -> WorkAreaInsets {
        guard let data = defaults.data(forKey: defaultsKey),
              let table = try? JSONDecoder().decode([String: WorkAreaInsets].self, from: data) else {
            return .zero
        }
        return table[String(displayID)] ?? .zero
    }

    static func store(_ insets: WorkAreaInsets, displayID: UInt32, defaults: UserDefaults = .standard) {
        var table: [String: WorkAreaInsets] = [:]
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: WorkAreaInsets].self, from: data) {
            table = decoded
        }
        if insets.isZero {
            table.removeValue(forKey: String(displayID))
        } else {
            table[String(displayID)] = insets
        }
        if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    // MARK: 纯函数

    /// 规划可用区：visibleFrame 扣 insets（Quartz，y 向下：top 加在 minY）。
    /// 扣完面积非正（insets 异常）→ 回落原始 frame。
    static func plannedFrame(visibleFrame: CGRect, insets: WorkAreaInsets) -> CGRect {
        let width = visibleFrame.width - insets.left - insets.right
        let height = visibleFrame.height - insets.top - insets.bottom
        guard width > 0, height > 0 else { return visibleFrame }
        return CGRect(
            x: visibleFrame.minX + insets.left,
            y: visibleFrame.minY + insets.top,
            width: width,
            height: height
        )
    }

    /// 由规划 frames 与实际落点推断钳制量。
    /// 只看贴规划区边缘的格子：该边所有贴边格都被同向推离 > noiseThreshold 时，
    /// 取其中最小推离量作为该边保留区（任一格能到达边缘 → 该边无钳制）。
    static func inferInsets(planned: [CGRect], actual: [CGRect?], planningFrame: CGRect) -> WorkAreaInsets {
        var top: [CGFloat] = []
        var left: [CGFloat] = []
        var bottom: [CGFloat] = []
        var right: [CGFloat] = []
        for (plan, act) in zip(planned, actual) {
            guard let act else { continue }
            if abs(plan.minY - planningFrame.minY) < 0.5 { top.append(act.minY - plan.minY) }
            if abs(plan.minX - planningFrame.minX) < 0.5 { left.append(act.minX - plan.minX) }
            if abs(plan.maxY - planningFrame.maxY) < 0.5 { bottom.append(plan.maxY - act.maxY) }
            if abs(plan.maxX - planningFrame.maxX) < 0.5 { right.append(plan.maxX - act.maxX) }
        }
        func edgeInset(_ deltas: [CGFloat]) -> CGFloat {
            guard let minDelta = deltas.min(), minDelta > noiseThreshold, minDelta <= maxInset else { return 0 }
            return minDelta.rounded()
        }
        return WorkAreaInsets(
            top: edgeInset(top),
            left: edgeInset(left),
            bottom: edgeInset(bottom),
            right: edgeInset(right)
        )
    }

    /// 探测结果换算：探测窗按「原始 visibleFrame 顶左格」写入后，实际到达的
    /// 顶/左边界与原始边界之差即真实保留区（能到达 → 0）。
    static func probedInsets(probeTarget: CGRect, actual: CGRect, learned: WorkAreaInsets) -> WorkAreaInsets {
        var result = learned
        let topReach = actual.minY - probeTarget.minY
        let leftReach = actual.minX - probeTarget.minX
        if topReach <= noiseThreshold {
            result.top = 0
        } else if topReach.rounded() < learned.top {
            result.top = topReach.rounded()
        }
        if leftReach <= noiseThreshold {
            result.left = 0
        } else if leftReach.rounded() < learned.left {
            result.left = leftReach.rounded()
        }
        return result
    }
}
