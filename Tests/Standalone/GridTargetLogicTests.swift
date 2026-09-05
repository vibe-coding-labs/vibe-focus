// Tests/Standalone/GridTargetLogicTests.swift
// Verification: 网格目标（屏幕/工作区）编解码 + 目标目录构建 + 无缝铺排几何
// Mirrors: Sources/TerminalGrid/GridTargetCatalog.swift, Sources/TerminalGrid/ScreenLayoutMapper.swift, Sources/TerminalGrid/TerminalGridPlanner.swift
// Run: swift Tests/Standalone/GridTargetLogicTests.swift
//
// 用户反馈（2026-09-06）：① 网格格子间有大空隙（Rectangle 无缝）；② 编排永远落主屏，
// 无法选目标屏/工作区。本文件锁定修复后的纯逻辑：gap=0 时相邻格严格共边、
// 目标编码可往返、目录按屏→工作区层级列出且 yabai 缺席时优雅退到屏级。

import CoreGraphics
import Foundation

// MARK: - Mirrored logic

enum GridTargetCode: Equatable {
    case main
    case focused
    case display(displayID: UInt32)
    case displaySpace(displayID: UInt32, spaceIndex: Int)

    var code: String {
        switch self {
        case .main: return "main"
        case .focused: return "focused"
        case .display(let displayID): return "d\(displayID)"
        case .displaySpace(let displayID, let spaceIndex): return "d\(displayID)s\(spaceIndex)"
        }
    }

    static func parse(_ raw: String?) -> GridTargetCode? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "main" { return .main }
        if raw == "focused" { return .focused }
        guard raw.hasPrefix("d") else { return nil }
        let body = raw.dropFirst()
        if let sIdx = body.firstIndex(of: "s") {
            guard let displayID = UInt32(body[..<sIdx]),
                  let spaceIndex = Int(body[body.index(after: sIdx)...]), spaceIndex > 0 else {
                return nil
            }
            return .displaySpace(displayID: displayID, spaceIndex: spaceIndex)
        }
        guard let displayID = UInt32(body) else { return nil }
        return .display(displayID: displayID)
    }

    var explicitDisplayID: UInt32? {
        switch self {
        case .main, .focused: return nil
        case .display(let displayID), .displaySpace(let displayID, _): return displayID
        }
    }
}

struct GridTargetOption: Equatable {
    let target: GridTargetCode
    let label: String
    let isActiveSpace: Bool
}

enum GridTargetCatalog {
    struct ScreenInput: Equatable {
        let displayID: UInt32
        let name: String
        let width: Int
        let height: Int
        let isMain: Bool
        let yabaiDisplayIndex: Int?
    }

    struct SpaceInput: Equatable {
        let yabaiIndex: Int
        let yabaiDisplayIndex: Int
        let isVisible: Bool
    }

    static func options(screens: [ScreenInput], spaces: [SpaceInput]) -> [GridTargetOption] {
        var result: [GridTargetOption] = [
            GridTargetOption(target: .main, label: "主屏（跟随系统主显示器）", isActiveSpace: true),
            GridTargetOption(target: .focused, label: "焦点窗口所在屏", isActiveSpace: true)
        ]
        let duplicatedNames = Set(screens.map { $0.name }.filter { name in screens.filter { $0.name == name }.count > 1 })
        for screen in screens {
            let mainTag = screen.isMain ? "（主）" : ""
            let nameSuffix = duplicatedNames.contains(screen.name) ? " #\(screen.displayID)" : ""
            let dims = "\(screen.width)×\(screen.height)"
            let screenSpaces = spaces
                .filter { $0.yabaiDisplayIndex == screen.yabaiDisplayIndex }
                .sorted { $0.yabaiIndex < $1.yabaiIndex }
            let activeSpace = screenSpaces.first { $0.isVisible }
            var screenLabel = "\(screen.name)\(nameSuffix) \(dims)\(mainTag)"
            if let activeSpace {
                screenLabel += " · Space \(activeSpace.yabaiIndex)"
            }
            result.append(GridTargetOption(
                target: .display(displayID: screen.displayID),
                label: screenLabel,
                isActiveSpace: true
            ))
            for space in screenSpaces {
                result.append(GridTargetOption(
                    target: .displaySpace(displayID: screen.displayID, spaceIndex: space.yabaiIndex),
                    label: "　└ Space \(space.yabaiIndex)\(space.isVisible ? "（当前）" : "")",
                    isActiveSpace: space.isVisible
                ))
            }
        }
        return result
    }
}

enum TerminalGridPlanner {
    static let maxGridSize = 4

    static func cells(visibleFrame: CGRect, rows: Int, cols: Int, gap: CGFloat) -> [CGRect] {
        guard (1...maxGridSize).contains(rows), (1...maxGridSize).contains(cols),
              visibleFrame.width > 0, visibleFrame.height > 0 else { return [] }
        let gap = max(0, gap)
        let innerWidth = visibleFrame.width - gap * CGFloat(cols - 1)
        let innerHeight = visibleFrame.height - gap * CGFloat(rows - 1)
        guard innerWidth / CGFloat(cols) > 0, innerHeight / CGFloat(rows) > 0 else { return [] }
        func start(_ i: Int, count: Int, origin: CGFloat, inner: CGFloat) -> CGFloat {
            (origin + inner * CGFloat(i) / CGFloat(count) + gap * CGFloat(i)).rounded()
        }
        func end(_ i: Int, count: Int, origin: CGFloat, inner: CGFloat) -> CGFloat {
            (origin + inner * CGFloat(i + 1) / CGFloat(count) + gap * CGFloat(i)).rounded()
        }
        var result: [CGRect] = []
        for row in 0..<rows {
            let y0 = start(row, count: rows, origin: visibleFrame.minY, inner: innerHeight)
            let y1 = end(row, count: rows, origin: visibleFrame.minY, inner: innerHeight)
            for col in 0..<cols {
                let x0 = start(col, count: cols, origin: visibleFrame.minX, inner: innerWidth)
                let x1 = end(col, count: cols, origin: visibleFrame.minX, inner: innerWidth)
                result.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return result
    }
}

/// gap 偏好读取语义镜像：未设置 → 0；显式 0 → 0；clamp 0...40
func gapPolicy(stored: Double?) -> CGFloat {
    CGFloat(min(max(stored ?? 0, 0), 40))
}


// MARK: Mirrors: Sources/TerminalGrid/ScreenLayoutMapper.swift

struct ScreenLayoutMapper {
    struct InputScreen: Equatable {
        let displayID: UInt32
        let name: String
        let cocoaFrame: CGRect
        let isMain: Bool
        let spaces: [InputSpace]
    }
    struct InputSpace: Equatable {
        let yabaiIndex: Int
        let isVisible: Bool
    }
    struct MappedScreen: Equatable {
        let displayID: UInt32
        let name: String
        let isMain: Bool
        let frame: CGRect
        let spaces: [MappedSpace]
        let visibleSpaceIndex: Int?
        var hasSpaces: Bool { !spaces.isEmpty }
    }
    struct MappedSpace: Equatable {
        let yabaiIndex: Int
        let frame: CGRect
        let isVisible: Bool
    }
    struct MappedLayout: Equatable {
        let screens: [MappedScreen]
        let contentRect: CGRect
        let scale: CGFloat
    }

    static let spaceStripHeight: CGFloat = 14
    static let spaceStripInset: CGFloat = 3
    static let spaceCapsuleGap: CGFloat = 2
    static let minScreenHeightForStrip: CGFloat = 34

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
                visibleSpaceIndex: screen.spaces.first { $0.isVisible }?.yabaiIndex
            ))
        }
        var content = CGRect.null
        for screen in mapped {
            content = content.union(screen.frame)
        }
        return MappedLayout(screens: mapped, contentRect: content, scale: scale)
    }

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
}

// MARK: Mirrors: Sources/TerminalGrid/DisplayWorkArea.swift

struct WorkAreaInsets: Codable, Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
    static let zero = WorkAreaInsets(top: 0, left: 0, bottom: 0, right: 0)
    var isZero: Bool { self == .zero }
    func merged(with other: WorkAreaInsets) -> WorkAreaInsets {
        WorkAreaInsets(top: max(top, other.top), left: max(left, other.left),
                       bottom: max(bottom, other.bottom), right: max(right, other.right))
    }
}

enum DisplayWorkArea {
    static let maxInset: CGFloat = 200
    static let noiseThreshold: CGFloat = 1.5

    static func plannedFrame(visibleFrame: CGRect, insets: WorkAreaInsets) -> CGRect {
        let width = visibleFrame.width - insets.left - insets.right
        let height = visibleFrame.height - insets.top - insets.bottom
        guard width > 0, height > 0 else { return visibleFrame }
        return CGRect(x: visibleFrame.minX + insets.left, y: visibleFrame.minY + insets.top, width: width, height: height)
    }

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
        return WorkAreaInsets(top: edgeInset(top), left: edgeInset(left),
                              bottom: edgeInset(bottom), right: edgeInset(right))
    }

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

/// target 偏好读取语义镜像：合法 target 优先；否则旧 displayMode=focused 迁移；否则 main
func targetPolicy(storedTarget: String?, legacyDisplayMode: String?) -> String {
    if let storedTarget, GridTargetCode.parse(storedTarget) != nil { return storedTarget }
    if legacyDisplayMode == "focused" { return GridTargetCode.focused.code }
    return GridTargetCode.main.code
}

// MARK: - Harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("  PASS: \(name)")
    } else {
        failed += 1
        print("  FAIL: \(name)")
    }
}

// MARK: - 编解码

print("== GridTargetCode 编解码 ==")
let roundTrips: [GridTargetCode] = [
    .main, .focused, .display(displayID: 1), .display(displayID: 69734400),
    .displaySpace(displayID: 3, spaceIndex: 1), .displaySpace(displayID: 4294967295, spaceIndex: 12)
]
check("往返：全部 case parse(code) == self", roundTrips.allSatisfy { GridTargetCode.parse($0.code) == $0 })
check("解析：nil/空串 → nil", GridTargetCode.parse(nil) == nil && GridTargetCode.parse("") == nil)
check("解析：垃圾串 → nil", GridTargetCode.parse("garbage") == nil && GridTargetCode.parse("dxyz") == nil)
check("解析：space 索引必须 >0", GridTargetCode.parse("d1s0") == nil && GridTargetCode.parse("d1s-2") == nil)
check("解析：缺 space 数字 → nil", GridTargetCode.parse("d1s") == nil)
check("解析：负 displayID 不合法", GridTargetCode.parse("d-1") == nil)
check("explicitDisplayID：main/focused 为 nil", GridTargetCode.main.explicitDisplayID == nil && GridTargetCode.focused.explicitDisplayID == nil)
check("explicitDisplayID：display/displaySpace 取屏 ID",
      GridTargetCode.display(displayID: 7).explicitDisplayID == 7
      && GridTargetCode.displaySpace(displayID: 8, spaceIndex: 2).explicitDisplayID == 8)

// MARK: - 屏幕布局映射（可视化 minimap）

print("\n== ScreenLayoutMapper 屏幕布局映射 ==")
// 用户真实布局（2026-09-06）：主屏在下（Cocoa y 0..1117），P40UG 在上（Cocoa y 1117..2557）
let layoutScreens = [
    ScreenLayoutMapper.InputScreen(
        displayID: 1, name: "Built-in Retina Display",
        cocoaFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isMain: true,
        spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true)]
    ),
    ScreenLayoutMapper.InputScreen(
        displayID: 2, name: "P40UG",
        cocoaFrame: CGRect(x: -814, y: 1117, width: 3440, height: 1440), isMain: false,
        spaces: (2...5).map { ScreenLayoutMapper.InputSpace(yabaiIndex: $0, isVisible: $0 == 3) }
    )
]
let mapped = ScreenLayoutMapper.map(screens: layoutScreens, viewSize: CGSize(width: 660, height: 216), padding: 14)
check("映射：两块屏都产出", mapped.screens.count == 2)
check("映射：主屏在前（输入顺序保持）", mapped.screens[0].displayID == 1 && mapped.screens[1].displayID == 2)
check("映射：全部内容落在可用区（含 padding，±0.01 浮点容差）",
      mapped.contentRect.minX >= 13.99 && mapped.contentRect.minY >= 13.99
      && mapped.contentRect.maxX <= 646.01 && mapped.contentRect.maxY <= 202.01)
check("映射：等比缩放（副屏 3440 宽映射宽 / 主屏 1728 宽映射宽 == 2±0.01）",
      abs(mapped.screens[1].frame.width / mapped.screens[0].frame.width - 2) < 0.01)
check("映射：物理左右关系保持（副屏在左上、主屏在右下 → 主屏 y 更大）",
      mapped.screens[0].frame.minY > mapped.screens[1].frame.minY)
check("映射：Cocoa y 向上翻转为 view y 向下（副屏在物理上方 → view minY 更小）",
      mapped.screens[1].frame.minY < mapped.screens[0].frame.minY)
let stripInside = mapped.screens[1].spaces.allSatisfy { capsule in
    let screenFrame = mapped.screens[1].frame
    return capsule.frame.minY >= screenFrame.minY
        && capsule.frame.maxY <= screenFrame.maxY - ScreenLayoutMapper.spaceStripInset + 0.01
        && capsule.frame.minX >= screenFrame.minX
        && capsule.frame.maxX <= screenFrame.maxX + 0.01
}
check("映射：Space 胶囊内嵌屏底缘（整条胶囊都在屏矩形内）", stripInside)
check("映射：4 个 Space 等分内嵌可用宽（宽 == (屏宽-6)/4 - 2）",
      abs(mapped.screens[1].spaces[0].frame.width - (mapped.screens[1].frame.width - 6) / 4 + 2) < 0.01)
check("映射：可见 Space 标记跟随输入（3 可见）",
      mapped.screens[1].spaces.first { $0.yabaiIndex == 3 }?.isVisible == true
      && mapped.screens[1].visibleSpaceIndex == 3)
check("映射：Space 胶囊横向等距排布",
      abs(mapped.screens[1].spaces[1].frame.minX - mapped.screens[1].spaces[0].frame.minX - (mapped.screens[1].frame.width - 6) / 4) < 0.01)
check("映射：visibleSpaceIndex 无 Space 时为 nil", mapped.screens[0].spaces.count == 1 && mapped.screens[0].visibleSpaceIndex == 1)

let mappedNoSpace = ScreenLayoutMapper.map(screens: layoutScreens.map {
    ScreenLayoutMapper.InputScreen(displayID: $0.displayID, name: $0.name, cocoaFrame: $0.cocoaFrame, isMain: $0.isMain, spaces: [])
}, viewSize: CGSize(width: 660, height: 216))
check("映射（无 yabai）：Space 带为空、hasSpaces=false", mappedNoSpace.screens.allSatisfy { !$0.hasSpaces && $0.visibleSpaceIndex == nil })

let emptyMapped = ScreenLayoutMapper.map(screens: [], viewSize: CGSize(width: 660, height: 216))
check("映射：空输入 → 空布局", emptyMapped.screens.isEmpty && emptyMapped.scale == 0)

let tinyMapped = ScreenLayoutMapper.map(screens: layoutScreens, viewSize: CGSize(width: 10, height: 10))
check("映射：view 尺寸过小 → 空布局（不崩溃不越界）", tinyMapped.screens.isEmpty)

// 网格预览格线：与真实规划器同语义（gap=0 边界法）
let previewCells = ScreenLayoutMapper.gridPreviewCells(screenFrame: CGRect(x: 0, y: 0, width: 200, height: 100), rows: 2, cols: 2)
let seamH = previewCells[0].maxX == previewCells[1].minX
let seamV = previewCells[0].maxY == previewCells[2].minY
check("预览：2×2 四格且相邻严格共边", previewCells.count == 4 && seamH && seamV)
check("预览：末格贴屏右/下缘", previewCells[1].maxX == 200 && previewCells[2].maxY == 100)
check("预览：非法行列 → 空", ScreenLayoutMapper.gridPreviewCells(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rows: 0, cols: 2).isEmpty)

// MARK: - 偏好语义

print("\n== 偏好读取语义 ==")
check("gap：未设置 → 0（默认无缝）", gapPolicy(stored: nil) == 0)
check("gap：显式 0 → 0（不再被强转 8）", gapPolicy(stored: 0) == 0)
check("gap：8 → 8", gapPolicy(stored: 8) == 8)
check("gap：负数 clamp 0 / 超限 clamp 40", gapPolicy(stored: -5) == 0 && gapPolicy(stored: 999) == 40)
check("target：无任何记录 → main", targetPolicy(storedTarget: nil, legacyDisplayMode: nil) == "main")
check("target：旧 displayMode=focused 迁移", targetPolicy(storedTarget: nil, legacyDisplayMode: "focused") == "focused")
check("target：旧 displayMode=main → main", targetPolicy(storedTarget: nil, legacyDisplayMode: "main") == "main")
check("target：合法新值优先于旧键", targetPolicy(storedTarget: "d2s3", legacyDisplayMode: "focused") == "d2s3")
check("target：非法新值回落旧键迁移", targetPolicy(storedTarget: "???", legacyDisplayMode: "focused") == "focused")

// MARK: - 无缝铺排几何

print("\n== 无缝铺排几何 ==")
// 用户副屏可视区（Quartz，位于主屏上方 → 负 y）
let visible = CGRect(x: 966, y: -1440, width: 2560, height: 1440)
let grid2x2 = TerminalGridPlanner.cells(visibleFrame: visible, rows: 2, cols: 2, gap: 0)
check("2×2 gap=0：4 格", grid2x2.count == 4)
check("2×2 gap=0：左右格严格共边（maxX == 右格 minX）",
      grid2x2[0].maxX == grid2x2[1].minX && grid2x2[2].maxX == grid2x2[3].minX)
check("2×2 gap=0：上下格严格共边（maxY == 下格 minY）",
      grid2x2[0].maxY == grid2x2[2].minY && grid2x2[1].maxY == grid2x2[3].minY)
check("2×2 gap=0：四格并集恰好铺满可视区",
      grid2x2.reduce(CGRect.null) { $0.union($1) } == visible)
check("2×2 gap=0：四格面积之和 == 可视区面积（无重叠无空隙）",
      abs(grid2x2.reduce(0) { $0 + $1.width * $1.height } - visible.width * visible.height) < 0.001)

let grid1x3 = TerminalGridPlanner.cells(visibleFrame: visible, rows: 1, cols: 3, gap: 0)
check("1×3 gap=0：相邻格共边（非整除宽度也不留缝）",
      grid1x3.count == 3 && grid1x3[0].maxX == grid1x3[1].minX && grid1x3[1].maxX == grid1x3[2].minX)
check("1×3 gap=0：末格严格贴可视区右缘（边界法取整，无 1px 漂移）", grid1x3[2].maxX == visible.maxX)
check("1×3 gap=0：所有格线为整数像素（窗口写入只接受整数）",
      grid1x3.allSatisfy { $0.minX == $0.minX.rounded() && $0.maxX == $0.maxX.rounded() })
check("1×3 gap=0：三格宽度差 ≤1px（853/853/854 或等价分配）",
      (grid1x3.map { $0.width }.max()! - grid1x3.map { $0.width }.min()!) <= 1)
let grid3x3 = TerminalGridPlanner.cells(visibleFrame: CGRect(x: 0, y: 25, width: 1728, height: 1092), rows: 3, cols: 3, gap: 0)
check("3×3 gap=0（主屏可视区，1092/3 非整除）：并集恰铺满且末行贴底",
      grid3x3.reduce(CGRect.null) { $0.union($1) } == CGRect(x: 0, y: 25, width: 1728, height: 1092)
      && grid3x3[8].maxY == 1117)

let gapped = TerminalGridPlanner.cells(visibleFrame: visible, rows: 1, cols: 2, gap: 8)
check("1×2 gap=8：格间恰 8px（显式间距仍受支持）", gapped[1].minX - gapped[0].maxX == 8)
check("1×2 gap=8：两格总宽 + 间距 == 可视区宽", gapped[0].width + gapped[1].width + 8 == visible.width)
let gapped3 = TerminalGridPlanner.cells(visibleFrame: visible, rows: 1, cols: 3, gap: 6)
check("1×3 gap=6：每条缝 6±1px 且末格贴右缘",
      abs(gapped3[1].minX - gapped3[0].maxX - 6) <= 1 && abs(gapped3[2].minX - gapped3[1].maxX - 6) <= 1
      && gapped3[2].maxX == visible.maxX)

// 旧默认 8px 与新默认 0 的差异——量化用户看到的"空隙"
let oldDefault = TerminalGridPlanner.cells(visibleFrame: visible, rows: 2, cols: 2, gap: 8)
check("对照：旧默认 gap=8 确有 8px 缝，新默认 0 无缝", oldDefault[1].minX - oldDefault[0].maxX == 8 && grid2x2[1].minX - grid2x2[0].maxX == 0)

// MARK: - 保留区学习（副屏菜单栏隐形钳制）

print("\n== DisplayWorkArea 保留区学习 ==")
let rawVisible = CGRect(x: -814, y: -1440, width: 3440, height: 1440)
let planned25 = DisplayWorkArea.plannedFrame(visibleFrame: rawVisible, insets: WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 0))
check("规划区：top 25 扣在 minY，其余边不变",
      planned25 == CGRect(x: -814, y: -1415, width: 3440, height: 1415))
check("规划区：zero insets 原样返回", DisplayWorkArea.plannedFrame(visibleFrame: rawVisible, insets: .zero) == rawVisible)
check("规划区：insets 过大（负面积）回落原始 frame",
      DisplayWorkArea.plannedFrame(visibleFrame: rawVisible, insets: WorkAreaInsets(top: 900, left: 0, bottom: 900, right: 0)) == rawVisible)

// 真机 E2E 实测场景：1×2 规划 1720 宽，两窗顶部都被推离 25px、右缘各缩 1px（噪声）
let plan1x2 = TerminalGridPlanner.cells(visibleFrame: rawVisible, rows: 1, cols: 2, gap: 0)
let clamped1x2: [CGRect?] = [
    CGRect(x: -814, y: -1415, width: 1719, height: 1415),
    CGRect(x: 906, y: -1415, width: 1719, height: 1415)
]
let learned25 = DisplayWorkArea.inferInsets(planned: plan1x2, actual: clamped1x2, planningFrame: rawVisible)
check("推断：顶行同推 25px → top=25", learned25.top == 25)
check("推断：右缘 1px 是取整噪声不算钳制", learned25.right == 0)
check("推断：未贴边的中缝不算边钳制", learned25.left == 0 && learned25.bottom == 0)

let partiallyClamped: [CGRect?] = [CGRect(x: -814, y: -1440, width: 1720, height: 1440), nil]
let noClamp = DisplayWorkArea.inferInsets(planned: plan1x2, actual: partiallyClamped, planningFrame: rawVisible)
check("推断：任一贴边格到达边缘 → 该边 0（nil 落点跳过）", noClamp.isZero)

let asymmetric: [CGRect?] = [CGRect(x: -814, y: -1430, width: 1720, height: 1430), CGRect(x: 906, y: -1415, width: 1719, height: 1415)]
check("推断：取贴边格最小推离量（10 而非 25）",
      DisplayWorkArea.inferInsets(planned: plan1x2, actual: asymmetric, planningFrame: rawVisible).top == 10)
let overLimit: [CGRect?] = [CGRect(x: -814, y: -1200, width: 1720, height: 1200)]
check("推断：推离超上限（>200）判异常不学习",
      DisplayWorkArea.inferInsets(planned: [plan1x2[0]], actual: overLimit, planningFrame: rawVisible).top == 0)

let learned = WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 0)
check("合并：逐边取大", learned.merged(with: WorkAreaInsets(top: 10, left: 5, bottom: 0, right: 3))
      == WorkAreaInsets(top: 25, left: 5, bottom: 0, right: 3))

// 探测自愈：菜单栏改自动隐藏后，探测窗能到顶 → top 归零
check("探测：能到达规划顶 → top 收回 0",
      DisplayWorkArea.probedInsets(probeTarget: plan1x2[0], actual: CGRect(x: -814, y: -1440, width: 1720, height: 1440), learned: learned).top == 0)
check("探测：仍在 25px 处 → 保持 25",
      DisplayWorkArea.probedInsets(probeTarget: plan1x2[0], actual: clamped1x2[0]!, learned: learned).top == 25)
check("探测：到达位置介于 0 与已学之间 → 取实际值",
      DisplayWorkArea.probedInsets(probeTarget: plan1x2[0], actual: CGRect(x: -814, y: -1430, width: 1720, height: 1430), learned: learned).top == 10)
check("探测：越界读数（高于目标）视为无钳制 → top 归 0",
      DisplayWorkArea.probedInsets(probeTarget: plan1x2[0], actual: CGRect(x: -814, y: -1500, width: 1720, height: 1500), learned: learned).top == 0)

print("\nGridTargetLogicTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
