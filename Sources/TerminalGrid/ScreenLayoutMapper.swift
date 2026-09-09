import CoreGraphics
import Foundation

// MARK: - 屏幕布局可视化映射器（纯函数）
/// 把真实的显示器物理布局（Cocoa 坐标，y 向上）映射为缩略图 view 坐标（y 向下），
/// 供设置页 minimap 渲染：每块屏一个圆角矩形，Space 胶囊内嵌在屏矩形底缘
/// （屏与屏物理相邻时外挂带会互相重叠，内嵌无此问题）。
/// 零 I/O 依赖，输入输出都是值对象，可完整单测。

struct ScreenLayoutMapper {

    struct InputScreen: Equatable {
        let displayID: UInt32
        let name: String
        /// NSScreen.frame（Cocoa，主屏左下原点，y 向上）
        let cocoaFrame: CGRect
        let isMain: Bool
        /// 该屏的 Space 列表（yabai 索引升序；yabai 不可用为空）
        let spaces: [InputSpace]
        /// yabai display index（1-based，几何精确匹配自 `query --displays`）。
        /// nil = yabai 不可用或匹配失败（UI 回退 #displayID 老标注）。
        /// 用户可见标注一律以此为准——CGDirectDisplayID 是另一套体系，
        /// 混用即「多套坐标系」（2026-09-08 用户反馈）。
        let yabaiDisplayIndex: Int?

        init(
            displayID: UInt32,
            name: String,
            cocoaFrame: CGRect,
            isMain: Bool,
            spaces: [InputSpace],
            yabaiDisplayIndex: Int? = nil
        ) {
            self.displayID = displayID
            self.name = name
            self.cocoaFrame = cocoaFrame
            self.isMain = isMain
            self.spaces = spaces
            self.yabaiDisplayIndex = yabaiDisplayIndex
        }
    }

    struct InputSpace: Equatable {
        let yabaiIndex: Int
        let isVisible: Bool
    }

    struct MappedScreen: Equatable {
        let displayID: UInt32
        let name: String
        let isMain: Bool
        /// view 坐标（y 向下），已含缩放与边距
        let frame: CGRect
        let spaces: [MappedSpace]
        /// 该屏当前可见 Space 的 yabai 索引（无 Space 数据为 nil）
        let visibleSpaceIndex: Int?
        /// yabai display index（透传 InputScreen；nil 回退 #displayID 标注）
        let yabaiDisplayIndex: Int?
        var hasSpaces: Bool { !spaces.isEmpty }
    }

    struct MappedSpace: Equatable {
        let yabaiIndex: Int
        let frame: CGRect
        let isVisible: Bool
    }

    struct MappedLayout: Equatable {
        let screens: [MappedScreen]
        /// 全部屏幕在 view 坐标里的包围盒
        let contentRect: CGRect
        let scale: CGFloat
    }

    /// Space 胶囊带（内嵌屏底缘）几何（view 点）
    static let spaceStripHeight: CGFloat = 14
    static let spaceStripInset: CGFloat = 3
    static let spaceCapsuleGap: CGFloat = 2
    /// 屏缩略高度低于该值时 Space 胶囊不再展示（View 侧据此隐藏）
    static let minScreenHeightForStrip: CGFloat = 34

    /// 把屏幕布局映射进 viewSize（含 padding）。空输入/非法尺寸返回空布局。
    static func map(screens: [InputScreen], viewSize: CGSize, padding: CGFloat = 14) -> MappedLayout {
        guard !screens.isEmpty, viewSize.width > padding * 2, viewSize.height > padding * 2 else {
            return MappedLayout(screens: [], contentRect: .zero, scale: 0)
        }
        var bounds = CGRect.null
        for screen in screens {
            bounds = bounds.union(screen.cocoaFrame)
        }
        guard bounds.width > 0, bounds.height > 0 else {
            return MappedLayout(screens: [], contentRect: .zero, scale: 0)
        }

        let availW = viewSize.width - padding * 2
        let availH = viewSize.height - padding * 2
        let scale = min(availW / bounds.width, availH / bounds.height)

        // Cocoa（y 向上）→ view（y 向下）：viewY = (bounds.maxY - cocoaMaxY) * scale + padding
        func toView(_ rect: CGRect) -> CGRect {
            CGRect(
                x: (rect.minX - bounds.minX) * scale + padding,
                y: (bounds.maxY - rect.maxY) * scale + padding,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }

        var mapped: [MappedScreen] = []
        mapped.reserveCapacity(screens.count)
        for screen in screens {
            let frame = toView(screen.cocoaFrame)
            // Space 胶囊：内嵌屏底缘，等分可用宽（块间留视觉缝）
            let stripY = frame.maxY - spaceStripInset - spaceStripHeight
            let usable = frame.width - spaceStripInset * 2
            let segment = usable / CGFloat(max(screen.spaces.count, 1))
            let spaces = screen.spaces.enumerated().map { pair -> MappedSpace in
                let (offset, space) = pair
                return MappedSpace(
                    yabaiIndex: space.yabaiIndex,
                    frame: CGRect(
                        x: frame.minX + spaceStripInset + segment * CGFloat(offset) + spaceCapsuleGap / 2,
                        y: stripY,
                        width: max(segment - spaceCapsuleGap, 0),
                        height: spaceStripHeight
                    ),
                    isVisible: space.isVisible
                )
            }
            mapped.append(MappedScreen(
                displayID: screen.displayID,
                name: screen.name,
                isMain: screen.isMain,
                frame: frame,
                spaces: spaces,
                visibleSpaceIndex: screen.spaces.first { $0.isVisible }?.yabaiIndex,
                yabaiDisplayIndex: screen.yabaiDisplayIndex
            ))
        }

        var content = CGRect.null
        for screen in mapped {
            content = content.union(screen.frame)
        }
        return MappedLayout(screens: mapped, contentRect: content, scale: scale)
    }

    /// 选中屏内的 rows×cols 网格预览格线（view 坐标；gap=0 无缝语义，边界法取整同源）
    static func gridPreviewCells(screenFrame: CGRect, rows: Int, cols: Int) -> [CGRect] {
        guard rows >= 1, cols >= 1, screenFrame.width > 0, screenFrame.height > 0 else { return [] }
        var cells: [CGRect] = []
        for row in 0..<rows {
            let y0 = screenFrame.minY + screenFrame.height * CGFloat(row) / CGFloat(rows)
            let y1 = screenFrame.minY + screenFrame.height * CGFloat(row + 1) / CGFloat(rows)
            for col in 0..<cols {
                let x0 = screenFrame.minX + screenFrame.width * CGFloat(col) / CGFloat(cols)
                let x1 = screenFrame.minX + screenFrame.width * CGFloat(col + 1) / CGFloat(cols)
                cells.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return cells
    }

    // MARK: 用户可见工作区编号（「屏号-位次」语言，2026-09-09 用户裁定）

    /// 工作区的用户可见标注：「屏号-该屏内第几个」（如 3-1 / 3-2）——overlay 角标、
    /// minimap Space 胶囊、S 标注、编排目标摘要四处共用同一语言。
    /// yabai 屏号缺失（几何解析失败）时退回 yabai 全局索引。
    static func userVisibleSpaceLabel(displayIndex: Int?, positionInDisplay: Int, yabaiIndex: Int) -> String {
        guard let displayIndex else { return "\(yabaiIndex)" }
        return "\(displayIndex)-\(positionInDisplay)"
    }

    /// yabai 全局索引在该屏 Space 升序列表中的屏内位次（1 起）；不在列表返回 nil。
    /// 接受索引数组以同时服务 MappedSpace（视图侧）与 InputSpace（快照侧）。
    static func positionInDisplay(of yabaiIndex: Int, inAscendingIndexes indexes: [Int]) -> Int? {
        indexes.firstIndex(of: yabaiIndex).map { $0 + 1 }
    }
}
