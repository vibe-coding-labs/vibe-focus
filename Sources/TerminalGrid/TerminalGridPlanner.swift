import CoreGraphics
import Foundation

// MARK: - 终端网格规划器（纯函数）
/// rows×cols 格子 frame 计算 + 从任意摆法反推行列数。
enum TerminalGridPlanner {

    struct GridSpec: Equatable {
        var rows: Int
        var cols: Int
        var gap: CGFloat

        init(rows: Int, cols: Int, gap: CGFloat = 0) {
            self.rows = rows
            self.cols = cols
            self.gap = gap
        }
    }

    /// 行列上限（超过 4×4 的终端格子已不可用）
    static let maxGridSize = 4

    /// 单份快照的格子数上限。桌面被批量窗口污染时，captureLayout 会捕获出
    /// 数百格的异常快照（真机事故：604 格快照 → autoRestore 新建 539 扇窗），
    /// 上限护栏在捕获与恢复两端同时拦截。
    static let maxSnapshotCells = 64

    static func isValidSnapshotCellCount(_ count: Int) -> Bool {
        count >= 1 && count <= maxSnapshotCells
    }

    static func validate(rows: Int, cols: Int) -> Bool {
        (1...maxGridSize).contains(rows) && (1...maxGridSize).contains(cols)
    }

    /// row-major（先行后列，Quartz y 自上而下）格子 frames。
    /// gap 为格子间距；可见区入参用 CoordinateKit.quartzVisibleFrame(of:)。
    /// 边界法取整：每条格线按累计位置四舍五入，相邻格严格共边、末格严格贴可视区边——
    /// 逐格宽度累加在非整除（如 2560/3）时会因浮点/取整漂移在末格留 1px 缝或越界，
    /// 而窗口写入（AppleScript bounds / yabai）只接受整数像素。
    static func cells(visibleFrame: CGRect, spec: GridSpec) -> [CGRect] {
        guard validate(rows: spec.rows, cols: spec.cols), visibleFrame.width > 0, visibleFrame.height > 0 else {
            return []
        }
        let gap = max(0, spec.gap)
        let innerWidth = visibleFrame.width - gap * CGFloat(spec.cols - 1)
        let innerHeight = visibleFrame.height - gap * CGFloat(spec.rows - 1)
        guard innerWidth / CGFloat(spec.cols) > 0, innerHeight / CGFloat(spec.rows) > 0 else { return [] }

        func start(_ i: Int, count: Int, origin: CGFloat, inner: CGFloat) -> CGFloat {
            (origin + inner * CGFloat(i) / CGFloat(count) + gap * CGFloat(i)).rounded()
        }
        func end(_ i: Int, count: Int, origin: CGFloat, inner: CGFloat) -> CGFloat {
            (origin + inner * CGFloat(i + 1) / CGFloat(count) + gap * CGFloat(i)).rounded()
        }

        var result: [CGRect] = []
        result.reserveCapacity(spec.rows * spec.cols)
        for row in 0..<spec.rows {
            let y0 = start(row, count: spec.rows, origin: visibleFrame.minY, inner: innerHeight)
            let y1 = end(row, count: spec.rows, origin: visibleFrame.minY, inner: innerHeight)
            for col in 0..<spec.cols {
                let x0 = start(col, count: spec.cols, origin: visibleFrame.minX, inner: innerWidth)
                let x1 = end(col, count: spec.cols, origin: visibleFrame.minX, inner: innerWidth)
                result.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return result
    }

    /// 从一组 frames 反推网格行列数：按中心点做 y/x 聚类（容差 tolerance）。
    /// 用于"捕获当前摆法"：用户手动拖好的终端布局，数出它是几乘几。
    static func inferGrid(from frames: [CGRect], tolerance: CGFloat = 40) -> (rows: Int, cols: Int)? {
        guard !frames.isEmpty else { return nil }

        var rowBands: [CGFloat] = []   // 每行 y 中心代表值
        var colBands: [CGFloat] = []
        for frame in frames.sorted(by: { $0.midY < $1.midY }) {
            if rowBands.contains(where: { abs($0 - frame.midY) <= tolerance }) {
                continue
            }
            rowBands.append(frame.midY)
        }
        for frame in frames.sorted(by: { $0.midX < $1.midX }) {
            if colBands.contains(where: { abs($0 - frame.midX) <= tolerance }) {
                continue
            }
            colBands.append(frame.midX)
        }

        let rows = rowBands.count
        let cols = colBands.count
        guard validate(rows: rows, cols: cols) else { return nil }
        return (rows, cols)
    }

    /// 把任意 frames 按 row-major 排序（先按 y 分带，带内按 x）。
    /// 捕获乱序窗口列表后统一编号用。
    static func rowMajorOrder(_ frames: [CGRect], tolerance: CGFloat = 40) -> [CGRect] {
        guard !frames.isEmpty else { return [] }
        let sorted = frames.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > tolerance {
                return lhs.midY < rhs.midY
            }
            return lhs.midX < rhs.midX
        }
        return sorted
    }

    /// 恢复时把记录 frame 拉回可视区（分辨率/菜单栏变化后 frame 可能越界）。
    /// 尺寸 clamp 到可视区，位置平移进边界。
    static func clampToVisible(frame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        var width = min(frame.width, visibleFrame.width)
        var height = min(frame.height, visibleFrame.height)
        width = max(width, 1)
        height = max(height, 1)
        var x = frame.origin.x
        var y = frame.origin.y
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
