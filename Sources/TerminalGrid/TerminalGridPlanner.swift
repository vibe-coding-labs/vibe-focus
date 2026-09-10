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

    /// 间距滑杆的 2px 步进取整（0 = 无缝；Runner 穷尽锁定）
    static func steppedGap(_ raw: Double) -> Double {
        (raw / 2).rounded() * 2
    }

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

    /// 覆盖网格：在推断网格基础上保证 rows×cols ≥ 格子数（每窗在重排网格里都有位子）。
    /// inferGrid 是几何聚类估计——自由摆放时乘积≠窗口数（16 窗可聚成 3 行 4 列），
    /// 照存会导致重排恢复帧数不足而丢窗；先夹进行列上限再按「先扩列后扩行」长到覆盖。
    /// 超过 4×4 容量的快照无处可长 → 返回 4×4（重排只放得下前 16 格，总量由恢复汇总如实播报）。
    static func coveringGrid(inferred: (rows: Int, cols: Int), cellCount: Int) -> (rows: Int, cols: Int) {
        var rows = max(1, min(inferred.rows, maxGridSize))
        var cols = max(1, min(inferred.cols, maxGridSize))
        let target = min(max(cellCount, 1), maxGridSize * maxGridSize)
        while rows * cols < target {
            if cols < maxGridSize {
                cols += 1
            } else {
                rows += 1
            }
        }
        return (rows: rows, cols: cols)
    }

    /// 捕获成功文案：括号网格仅在 rows×cols 恰等于窗口数（干净网格）时展示。
    /// 推断网格是聚类估计，自由摆放时乘积≠窗口数，两数并列会被读成「数字对不上」。
    static func captureSummaryMessage(cellCount: Int, rows: Int, cols: Int, sessionCount: Int) -> String {
        let gridNote = rows * cols == cellCount ? "（\(rows)×\(cols)）" : ""
        return "已捕获 \(cellCount) 个终端窗口\(gridNote)，其中 \(sessionCount) 个关联到 Claude session"
    }

    /// 自动恢复汇总：四类去处之外若有格子因超出网格容量（>4×4 的快照重排封顶）
    /// 未获处理，必须显式记账——否则「新建/注入/跳过/失败」加起来 < 格子数，
    /// 读起来像账全平、实际有格子被静默丢掉。
    static func autoRestoreSummaryMessage(
        created: Int, injected: Int, skipped: Int, failures: Int, unprocessed: Int
    ) -> String {
        var summary = "自动恢复：新建 \(created)、注入 \(injected)、跳过运行中 \(skipped)"
        if failures > 0 {
            summary += "、失败 \(failures)"
        }
        if unprocessed > 0 {
            summary += "；另有 \(unprocessed) 格超出网格容量（4×4）未处理"
        }
        return summary
    }

    /// 建格失败文案：失败序号从 1 起计（与快照格子阅读序一致）；此前已建成的窗口
    /// 不会被回收、留在屏上，必须说明——否则用户对着凭空多出的窗不知道哪来的。
    static func cellCreationFailureMessage(failedIndex: Int, createdCount: Int, detail: String) -> String {
        var message = "第 \(failedIndex + 1) 个终端窗口创建失败：\(detail)（若为自动化权限问题，请在 系统设置 → 隐私与安全性 → 自动化 中允许 VibeFocus 控制终端）"
        if createdCount > 0 {
            message += "；前 \(createdCount) 个窗口已创建并保留在屏上"
        }
        return message
    }
}
