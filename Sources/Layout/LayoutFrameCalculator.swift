import CoreGraphics
import Foundation

// MARK: - 摆位目标 frame 计算
/// 纯几何：action → Quartz 目标 frame。坐标系与 CoordinateKit 内部标准一致
/// （原点主屏左上、Y 向下）；可见区入参传 `CoordinateKit.quartzVisibleFrame(of:)`。
/// gap=0 时语义与 Rectangle 一致（铺满分割，无缝隙）。
enum LayoutFrameCalculator {

    /// 摆位留白（px）：可见区边缘与半屏/四分接缝各让出 gap / gap/2
    static let defaultGap: CGFloat = 0

    static func frame(
        for action: LayoutAction,
        visibleFrame: CGRect,
        windowFrame: CGRect? = nil,
        gap: CGFloat = defaultGap
    ) -> CGRect? {
        switch action {
        case .center:
            guard let windowFrame else { return nil }
            return centeredFrame(windowFrame: windowFrame, visibleFrame: visibleFrame)
        default:
            return splitFrame(for: action, visibleFrame: visibleFrame, gap: gap)
        }
    }

    /// 半屏/四分/最大化/下一屏的分割 frame；居中需要窗口原尺寸，返回 nil。
    /// Quartz Y 向下，"top" 即较小 y。
    static func splitFrame(
        for action: LayoutAction,
        visibleFrame: CGRect,
        gap: CGFloat = defaultGap
    ) -> CGRect? {
        switch action {
        case .maximize, .nextDisplay:
            return visibleFrame.insetBy(dx: gap, dy: gap)
        case .leftHalf, .rightHalf:
            let span = max(0, (visibleFrame.width - gap * 2 - gap / 2) / 2)
            let x: CGFloat = action == .leftHalf
                ? visibleFrame.minX + gap
                : visibleFrame.minX + gap + span + gap / 2
            return CGRect(x: x, y: visibleFrame.minY + gap, width: span, height: max(0, visibleFrame.height - gap * 2))
        case .topHalf, .bottomHalf:
            let span = max(0, (visibleFrame.height - gap * 2 - gap / 2) / 2)
            let y: CGFloat = action == .topHalf
                ? visibleFrame.minY + gap
                : visibleFrame.minY + gap + span + gap / 2
            return CGRect(x: visibleFrame.minX + gap, y: y, width: max(0, visibleFrame.width - gap * 2), height: span)
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            let w = max(0, (visibleFrame.width - gap * 2 - gap / 2) / 2)
            let h = max(0, (visibleFrame.height - gap * 2 - gap / 2) / 2)
            let isLeft = action == .topLeftQuarter || action == .bottomLeftQuarter
            let isTop = action == .topLeftQuarter || action == .topRightQuarter
            let x: CGFloat = isLeft ? visibleFrame.minX + gap : visibleFrame.minX + gap + w + gap / 2
            let y: CGFloat = isTop ? visibleFrame.minY + gap : visibleFrame.minY + gap + h + gap / 2
            return CGRect(x: x, y: y, width: w, height: h)
        case .center:
            return nil
        }
    }

    /// 居中：保持窗口尺寸（clamp 到可视区内），几何中心对齐可视区中心
    static func centeredFrame(windowFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(windowFrame.width, visibleFrame.width)
        let height = min(windowFrame.height, visibleFrame.height)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
