// Tests/Standalone/GridTargetLogicTests.swift
// Verification: 网格目标（屏幕/工作区）编解码 + 目标目录构建 + 无缝铺排几何
// Mirrors: Sources/TerminalGrid/GridTargetCatalog.swift, Sources/TerminalGrid/TerminalGridPlanner.swift
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

// MARK: - 目录构建（用户三屏：主屏在下，两副屏在上）

print("\n== GridTargetCatalog 目录 ==")
let screens = [
    GridTargetCatalog.ScreenInput(displayID: 1, name: "内建视网膜显示器", width: 1728, height: 1117, isMain: true, yabaiDisplayIndex: 1),
    GridTargetCatalog.ScreenInput(displayID: 2, name: "DELL U2723QE", width: 2560, height: 1440, isMain: false, yabaiDisplayIndex: 2),
    GridTargetCatalog.ScreenInput(displayID: 3, name: "DELL U2723QE", width: 2560, height: 1440, isMain: false, yabaiDisplayIndex: 3)
]
let spaces = [
    GridTargetCatalog.SpaceInput(yabaiIndex: 1, yabaiDisplayIndex: 1, isVisible: true),
    GridTargetCatalog.SpaceInput(yabaiIndex: 2, yabaiDisplayIndex: 1, isVisible: false),
    GridTargetCatalog.SpaceInput(yabaiIndex: 3, yabaiDisplayIndex: 2, isVisible: true),
    GridTargetCatalog.SpaceInput(yabaiIndex: 5, yabaiDisplayIndex: 3, isVisible: false),
    GridTargetCatalog.SpaceInput(yabaiIndex: 4, yabaiDisplayIndex: 3, isVisible: true)
]
let full = GridTargetCatalog.options(screens: screens, spaces: spaces)
check("目录：前两项恒为 主屏 / 焦点屏", full[0].target == .main && full[1].target == .focused)
check("目录：三屏各一项 + 每屏 space 细分（2+1+2）→ 共 2+3+5=10 项", full.count == 10)
check("目录：屏级项紧跟其 space 项（层级顺序）",
      full[2].target == .display(displayID: 1)
      && full[3].target == .displaySpace(displayID: 1, spaceIndex: 1)
      && full[4].target == .displaySpace(displayID: 1, spaceIndex: 2)
      && full[5].target == .display(displayID: 2)
      && full[6].target == .displaySpace(displayID: 2, spaceIndex: 3)
      && full[7].target == .display(displayID: 3))
check("目录：同屏 space 按 yabai 索引升序（5 在 4 之后）",
      full[8].target == .displaySpace(displayID: 3, spaceIndex: 4)
      && full[9].target == .displaySpace(displayID: 3, spaceIndex: 5))
check("目录：主屏标签带（主）与尺寸与当前 Space", full[2].label == "内建视网膜显示器 1728×1117（主） · Space 1")
check("目录：重名屏追加 #displayID 消歧",
      full[5].label.contains("DELL U2723QE #2") && full[7].label.contains("DELL U2723QE #3"))
check("目录：非重名屏不加 #", !full[2].label.contains("#"))
check("目录：当前可见 space 标（当前）且 isActiveSpace=true",
      full[3].label.contains("（当前）") && full[3].isActiveSpace
      && !full[4].label.contains("（当前）") && !full[4].isActiveSpace)
check("目录：屏级项 isActiveSpace 恒 true（无需切换）", full.filter { if case .display = $0.target { return true }; return false }.allSatisfy { $0.isActiveSpace })
check("目录：选项 code 唯一（Picker tag 不冲突）", Set(full.map { $0.target.code }).count == full.count)

let noYabai = GridTargetCatalog.options(screens: screens.map {
    GridTargetCatalog.ScreenInput(displayID: $0.displayID, name: $0.name, width: $0.width, height: $0.height, isMain: $0.isMain, yabaiDisplayIndex: nil)
}, spaces: [])
check("目录（无 yabai）：只到屏级 2+3=5 项，无 space 项", noYabai.count == 5 && !noYabai.contains { if case .displaySpace = $0.target { return true }; return false })
check("目录（无 yabai）：屏标签不带 Space 后缀", !noYabai[2].label.contains("Space"))

let singleScreen = GridTargetCatalog.options(screens: [screens[0]], spaces: [spaces[0]])
check("目录（单屏单 space）：主屏 + 焦点 + 屏 + 1 space = 4 项", singleScreen.count == 4)

let orphanSpaces = GridTargetCatalog.options(screens: [screens[0]], spaces: [GridTargetCatalog.SpaceInput(yabaiIndex: 9, yabaiDisplayIndex: 7, isVisible: true)])
check("目录：归属未知屏的 space 被忽略（不产生悬空项）", orphanSpaces.count == 3)

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
