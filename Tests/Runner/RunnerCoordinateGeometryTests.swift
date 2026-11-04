import AppKit
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerCoordinateGeometryTests.swift — 屏幕坐标域单测补强。
//
// 背景：坐标换算此前在 displayContext / displayContextDisplayID /
// matchYabaiDisplayIndices / HookWindowRecord.isValid / InputBubbleLayout 五处
// 各自内联 `primaryHeight - rect.maxY`，且 rowMajorOrder 用 pairwise tolerance
// 直接当 sort 比较器（带间不满足传递性）。本文件锁定：
//   1. CoordinateKit 新增的全局坐标互转 / 屏幕下标解析（单一事实源）；
//   2. 三块屏（主屏 / 上方副屏 / 左侧副屏）的象限与负坐标语义；
//   3. ScreenLayoutMapper、TerminalGridPlanner、DisplayWorkArea 的边界与退化输入；
//   4. OverlayWindow / InputBubbleLayout 的六方位与负坐标屏；
//   5. ScreenHotplugGuard（此前仅 XCTest 套件覆盖，Runner 基线缺位）。
//
// 纯函数直测，不依赖当前真机屏幕数量；需要主屏高度的用例一律用夹具值 1117。

extension RunnerHarness {
    func runCoordinateGeometryTests() {
        print("\n=== CoordinateGeometry (2026-11-05) ===")

        /// 浮点容差比较（几何测试的 1e-9 级抖动不构成行为差异）
        func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-9) -> Bool {
            abs(a - b) <= eps
        }

        // ===== A. Quartz ↔ Cocoa 全局互转（矩形 / 点） =====
        do {
            let h: CGFloat = 1117
            let mainCocoa = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            check("coordGeom: 主屏矩形互转恒等",
                  CoordinateKit.cocoaRect(fromQuartz: mainCocoa, primaryHeight: h) == mainCocoa
                  && CoordinateKit.quartzRect(fromCocoa: mainCocoa, primaryHeight: h) == mainCocoa)

            // 主屏上方副屏：Quartz y 为负（-1080..0），Cocoa y 为 1117..2197
            let aboveQuartz = CGRect(x: 100, y: -1080, width: 1920, height: 1080)
            let aboveCocoa = CoordinateKit.cocoaRect(fromQuartz: aboveQuartz, primaryHeight: h)
            check("coordGeom: 上方副屏 Quartz→Cocoa（y = 主屏高 − maxY）",
                  aboveCocoa == CGRect(x: 100, y: 1117, width: 1920, height: 1080))
            check("coordGeom: 上方副屏 Cocoa→Quartz 往返",
                  CoordinateKit.quartzRect(fromCocoa: aboveCocoa, primaryHeight: h) == aboveQuartz)

            // 主屏左侧副屏：x 负、y 不贴 0（37 = 1117 − 1080）
            let leftQuartz = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            check("coordGeom: 左侧副屏换算保留 x、y 取 maxY 翻转",
                  CoordinateKit.cocoaRect(fromQuartz: leftQuartz, primaryHeight: h)
                  == CGRect(x: -1920, y: 37, width: 1920, height: 1080))

            // 小数与负值
            let fracQuartz = CGRect(x: 10.5, y: -0.5, width: 100.25, height: 50.5)
            check("coordGeom: 小数矩形 maxY=50 → cocoa y=1067",
                  CoordinateKit.cocoaRect(fromQuartz: fracQuartz, primaryHeight: h)
                  == CGRect(x: 10.5, y: 1067, width: 100.25, height: 50.5))

            let point = CGPoint(x: 12.5, y: -33.25)
            let cocoaPoint = CoordinateKit.cocoaPoint(fromQuartz: point, primaryHeight: h)
            check("coordGeom: 点换算 y 翻转（含负 y）",
                  cocoaPoint == CGPoint(x: 12.5, y: 1150.25))
            check("coordGeom: 点换算往返恒等",
                  CoordinateKit.quartzPoint(fromCocoa: cocoaPoint, primaryHeight: h) == point)
        }

        // ===== B. 屏幕下标解析（中心命中优先、相交兜底、屏序稳定） =====
        do {
            let h: CGFloat = 1117
            let screenFrames = [
                CGRect(x: 0, y: 0, width: 1728, height: 1117),      // 主屏
                CGRect(x: 0, y: 1117, width: 1920, height: 1080),   // 上方副屏
                CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // 左侧副屏
            ]
            check("coordGeom: 主屏内 Quartz rect → 0",
                  CoordinateKit.screenIndex(containingQuartz: CGRect(x: 100, y: 100, width: 300, height: 200),
                                            primaryHeight: h, screenFrames: screenFrames) == 0)
            check("coordGeom: 上方副屏（Quartz 负 y）→ 1",
                  CoordinateKit.screenIndex(containingQuartz: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                                            primaryHeight: h, screenFrames: screenFrames) == 1)
            check("coordGeom: 左侧副屏（负 x）→ 2",
                  CoordinateKit.screenIndex(containingQuartz: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                            primaryHeight: h, screenFrames: screenFrames) == 2)
            check("coordGeom: 远离所有屏 → nil",
                  CoordinateKit.screenIndex(containingQuartz: CGRect(x: 5000, y: 5000, width: 10, height: 10),
                                            primaryHeight: h, screenFrames: screenFrames) == nil)

            // 中心不在屏内、但矩形与屏相交 → 相交兜底
            let intersectFallback = CoordinateKit.screenIndex(
                containing: CGRect(x: -50, y: 0, width: 80, height: 80),
                in: [CGRect(x: 0, y: 0, width: 100, height: 100)])
            check("coordGeom: 中心在外但相交 → 相交兜底命中", intersectFallback == 0)

            // 多屏重叠时按屏序取第一个（确定性）
            let overlap = CoordinateKit.screenIndex(
                containing: CGRect(x: 60, y: 10, width: 20, height: 20),
                in: [CGRect(x: 0, y: 0, width: 100, height: 100),
                    CGRect(x: 50, y: 0, width: 100, height: 100)])
            check("coordGeom: 重叠屏按屏序取首个命中", overlap == 0)
            check("coordGeom: 空屏表 → nil",
                  CoordinateKit.screenIndex(containing: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil)
        }

        // ===== C. 坐标换算的消费端一致性（isValid / 气泡 frame 走同一事实源） =====
        do {
            let h: CGFloat = 1117
            // HookWindowRecord.isValid 的 Quartz→Cocoa 中心换算与 CoordinateKit 等价
            let quartzCenter = CGPoint(x: 300.5, y: 400.25)
            let viaKit = CoordinateKit.cocoaPoint(fromQuartz: quartzCenter, primaryHeight: h)
            let viaLegacy = CGPoint(x: quartzCenter.x, y: h - quartzCenter.y)
            check("coordGeom: hook 中心换算与 CoordinateKit 一致", viaKit == viaLegacy)

            // 气泡 AppKit frame 委托同一换算
            let cgFrame = CGRect(x: 20, y: -1080, width: 800, height: 600)
            let bubbleFrame = InputBubbleLayout.appKitFrame(fromCGFrame: cgFrame, primaryScreenHeight: h)
            check("coordGeom: 气泡 frame 与 CoordinateKit.cocoaRect 一致",
                  bubbleFrame == CoordinateKit.cocoaRect(fromQuartz: cgFrame, primaryHeight: h))
            check("coordGeom: 气泡 frame 往返回 Quartz",
                  CoordinateKit.quartzRect(fromCocoa: bubbleFrame, primaryHeight: h) == cgFrame)
            check("coordGeom: 气泡 y 换算（上方副屏 → AppKit y > 主屏高）",
                  InputBubbleLayout.appKitY(fromCGY: -1080, primaryScreenHeight: h) == 2197)
        }

        // ===== D. OverlayWindow 六方位（负坐标屏 / 负 margin / 窗口大于屏） =====
        do {
            let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let size = CGSize(width: 120, height: 40)
            check("coordGeom: overlay 负坐标屏 topLeft",
                  OverlayWindow.calculateOverlayOrigin(position: .topLeft, screenFrame: screen,
                                                       windowSize: size, margin: 12)
                  == CGPoint(x: -1908, y: 1028))
            check("coordGeom: overlay 负坐标屏 topRight（右缘 = 0）",
                  OverlayWindow.calculateOverlayOrigin(position: .topRight, screenFrame: screen,
                                                       windowSize: size, margin: 12)
                  == CGPoint(x: -132, y: 1028))
            check("coordGeom: overlay 负坐标屏 bottomLeft / bottomRight",
                  OverlayWindow.calculateOverlayOrigin(position: .bottomLeft, screenFrame: screen,
                                                       windowSize: size, margin: 12)
                  == CGPoint(x: -1908, y: 12)
                  && OverlayWindow.calculateOverlayOrigin(position: .bottomRight, screenFrame: screen,
                                                          windowSize: size, margin: 12)
                  == CGPoint(x: -132, y: 12))
            check("coordGeom: overlay 负坐标屏水平居中",
                  OverlayWindow.calculateOverlayOrigin(position: .topCenter, screenFrame: screen,
                                                       windowSize: size, margin: 12)
                  == CGPoint(x: -1020, y: 1028)
                  && OverlayWindow.calculateOverlayOrigin(position: .bottomCenter, screenFrame: screen,
                                                          windowSize: size, margin: 12)
                  == CGPoint(x: -1020, y: 12))
            // 负 margin 钳 0；窗口大于屏时不做二次夹取（窗口服务器语义由 AppKit 兜底）
            check("coordGeom: overlay 负 margin 钳 0",
                  OverlayWindow.calculateOverlayOrigin(position: .topLeft,
                                                       screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                       windowSize: CGSize(width: 10, height: 10), margin: -5)
                  == CGPoint(x: 0, y: 90))
            check("coordGeom: overlay 窗口大于屏时原点按公式直出（不夹取）",
                  OverlayWindow.calculateOverlayOrigin(position: .topLeft,
                                                       screenFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                       windowSize: CGSize(width: 100, height: 100), margin: 5)
                  == CGPoint(x: 5, y: -95))
        }

        // ===== E. 气泡位置夹取 / 内容布局在退化尺寸下的几何 =====
        do {
            let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let bubble = CGSize(width: 480, height: 150)
            check("coordGeom: 气泡记忆位置越左/下缘 → 拉回负坐标屏可视区",
                  InputBubbleLayout.clampedOrigin(position: CGPoint(x: -2500, y: -100),
                                                  bubbleSize: bubble, visibleFrame: visible)
                  == CGPoint(x: -1920, y: 0))
            check("coordGeom: 气泡记忆位置越右/上缘 → 拉回屏内",
                  InputBubbleLayout.clampedOrigin(position: CGPoint(x: 200, y: 5000),
                                                  bubbleSize: bubble, visibleFrame: visible)
                  == CGPoint(x: -480, y: 930))

            let frames = InputBubbleLayout.contentFrames(for: CGSize(width: 320, height: 100))
            check("coordGeom: 最小气泡滚动区几何（12,26,296,60）",
                  frames.scroll == CGRect(x: 12, y: 26, width: 296, height: 60))
            check("coordGeom: 最小气泡关闭钮贴右上角（299,79,16,16）",
                  frames.close == CGRect(x: 299, y: 79, width: 16, height: 16))
            check("coordGeom: 最小气泡底栏从左到右不重叠",
                  frames.history.maxX <= frames.hint.minX
                  && frames.hint.maxX <= frames.button.minX
                  && frames.button.maxX <= frames.grip.minX)
            check("coordGeom: 最小气泡提示文案宽度为正",
                  frames.hint.width == 185)

            let saved = CGRect(x: -1920.5, y: -3.25, width: 480, height: 150)
            check("coordGeom: 气泡位置记忆负小数往返",
                  InputBubbleLayout.decodeFrame(InputBubbleLayout.encodeFrame(saved)) == saved)
        }

        // ===== F. ScreenLayoutMapper：多屏纵向排列 / 缩放 / 负坐标包围盒 =====
        do {
            let inputs: [ScreenLayoutMapper.InputScreen] = [
                ScreenLayoutMapper.InputScreen(
                    displayID: 1, name: "主屏",
                    cocoaFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isMain: true,
                    spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true)],
                    yabaiDisplayIndex: 1),
                ScreenLayoutMapper.InputScreen(
                    displayID: 2, name: "上方副屏",
                    cocoaFrame: CGRect(x: 0, y: 1117, width: 1920, height: 1080), isMain: false,
                    spaces: [], yabaiDisplayIndex: 2),
            ]
            let viewSize = CGSize(width: 460, height: 260)
            let mapped = ScreenLayoutMapper.map(screens: inputs, viewSize: viewSize)
            let expectedScale = min((viewSize.width - 28) / 1920, (viewSize.height - 28) / 2197)
            check("coordGeom: mapper 取两轴缩放较小者",
                  near(mapped.scale, expectedScale) && mapped.scale > 0)
            check("coordGeom: mapper 输入顺序与 displayID 透传",
                  mapped.screens.map(\.displayID) == [1, 2]
                  && mapped.screens[1].isMain == false)

            let s = mapped.scale
            let mainFrame = mapped.screens[0].frame
            let aboveFrame = mapped.screens[1].frame
            check("coordGeom: Cocoa y 向上 → view y 向下（上方副屏在上半区）",
                  aboveFrame.minY < mainFrame.minY
                  && near(aboveFrame.minY, 14)
                  && near(mainFrame.minY, 14 + 1080 * s))
            check("coordGeom: 上下相邻屏在 view 中恰好贴合",
                  near(aboveFrame.maxY, mainFrame.minY))
            check("coordGeom: 屏宽按同一 scale 缩放",
                  near(mainFrame.width, 1728 * s) && near(aboveFrame.width, 1920 * s))
            check("coordGeom: contentRect 覆盖两屏且落在 padding 内",
                  mapped.contentRect.minX >= 14 - 1e-9
                  && mapped.contentRect.minY >= 14 - 1e-9
                  && mapped.contentRect.maxX <= viewSize.width - 14 + 1e-9
                  && mapped.contentRect.maxY <= viewSize.height - 14 + 1e-9
                  && near(mapped.contentRect.height, 2197 * s))

            check("coordGeom: mapper 空输入 / 非法视口 / 零面积屏 → 空布局",
                  ScreenLayoutMapper.map(screens: [], viewSize: viewSize).screens.isEmpty
                  && ScreenLayoutMapper.map(screens: inputs,
                                            viewSize: CGSize(width: 27, height: 260)).screens.isEmpty
                  && ScreenLayoutMapper.map(
                    screens: [ScreenLayoutMapper.InputScreen(
                        displayID: 9, name: "零", cocoaFrame: .zero, isMain: false, spaces: [])],
                    viewSize: viewSize).screens.isEmpty)

            // 极窄屏 + 多 Space：胶囊宽度退化到 0 时不得出现负宽或越出屏矩形
            let narrow = ScreenLayoutMapper.map(
                screens: [ScreenLayoutMapper.InputScreen(
                    displayID: 7, name: "窄", cocoaFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    isMain: true,
                    spaces: (1...7).map { ScreenLayoutMapper.InputSpace(yabaiIndex: $0, isVisible: $0 == 4) },
                    yabaiDisplayIndex: 1)],
                viewSize: CGSize(width: 38, height: 38))
            let narrowScreen = narrow.screens[0]
            check("coordGeom: 极窄屏 7 Space 胶囊宽度非负且不出屏",
                  narrowScreen.spaces.count == 7
                  && narrowScreen.spaces.allSatisfy {
                      $0.frame.width >= 0
                      && $0.frame.minX >= narrowScreen.frame.minX
                      && $0.frame.maxX <= narrowScreen.frame.maxX + 1e-9
                  })
            check("coordGeom: 极窄屏 visibleSpaceIndex 取首个可见",
                  narrowScreen.visibleSpaceIndex == 4)

            // 网格预览：负原点 / 非整除 / row-major
            let preview = ScreenLayoutMapper.gridPreviewCells(
                screenFrame: CGRect(x: -50, y: -30, width: 100, height: 100), rows: 3, cols: 3)
            check("coordGeom: 预览 3×3 负原点 9 格且相邻共边",
                  preview.count == 9
                  && near(preview[1].minX, preview[0].maxX)
                  && near(preview[3].minY, preview[0].maxY))
            check("coordGeom: 预览末格严格贴屏右/下缘",
                  near(preview[8].maxX, 50) && near(preview[8].maxY, 70))
            check("coordGeom: 预览行列非法/零面积 → 空",
                  ScreenLayoutMapper.gridPreviewCells(
                    screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rows: 0, cols: 3).isEmpty
                  && ScreenLayoutMapper.gridPreviewCells(
                    screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rows: 3, cols: -1).isEmpty
                  && ScreenLayoutMapper.gridPreviewCells(
                    screenFrame: .zero, rows: 3, cols: 3).isEmpty)

            check("coordGeom: 工作区标注「屏号-位次」与全局号兜底",
                  ScreenLayoutMapper.userVisibleSpaceLabel(displayIndex: 3, positionInDisplay: 2, yabaiIndex: 9) == "3-2"
                  && ScreenLayoutMapper.userVisibleSpaceLabel(displayIndex: nil, positionInDisplay: 2, yabaiIndex: 9) == "9")
            check("coordGeom: 屏内位次查询命中/缺失",
                  ScreenLayoutMapper.positionInDisplay(of: 3, inAscendingIndexes: [1, 3, 5]) == 2
                  && ScreenLayoutMapper.positionInDisplay(of: 9, inAscendingIndexes: [1, 3, 5]) == nil
                  && ScreenLayoutMapper.positionInDisplay(of: 1, inAscendingIndexes: []) == nil)
        }

        // ===== G. TerminalGridPlanner：边界取整 / 退化输入 / 反推 / 稳定排序 =====
        do {
            // 2560/3 非整除：相邻严格共边、末格贴右缘
            let visible = CGRect(x: 0, y: 25, width: 2560, height: 1400)
            let cells = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 1, cols: 3))
            check("coordGeom: 网格非整除宽度按边界法取整",
                  cells.count == 3
                  && cells[0].minX == 0 && cells[0].maxX == 853
                  && cells[1].minX == 853 && cells[1].maxX == 1707
                  && cells[2].minX == 1707 && cells[2].maxX == 2560)
            check("coordGeom: 网格非整除宽度合计恰好铺满",
                  cells.reduce(0) { $0 + $1.width } == 2560)

            // 1001/2 = 500.5 → .rounded() 远离零取整 501
            let rows = TerminalGridPlanner.cells(
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1001),
                spec: .init(rows: 2, cols: 1))
            check("coordGeom: 网格半像素边界四舍五入（501/500）",
                  rows.count == 2 && rows[0].height == 501 && rows[1].height == 500
                  && rows[1].maxY == 1001)

            check("coordGeom: gap 等于屏宽 → 内区非正 → 空数组",
                  TerminalGridPlanner.cells(
                    visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    spec: .init(rows: 1, cols: 2, gap: 100)).isEmpty)
            check("coordGeom: 负原点可视区格子跟随原点",
                  TerminalGridPlanner.cells(
                    visibleFrame: CGRect(x: -100, y: -50, width: 200, height: 100),
                    spec: .init(rows: 2, cols: 2)) == [
                      CGRect(x: -100, y: -50, width: 100, height: 50),
                      CGRect(x: 0, y: -50, width: 100, height: 50),
                      CGRect(x: -100, y: 0, width: 100, height: 50),
                      CGRect(x: 0, y: 0, width: 100, height: 50),
                  ])

            check("coordGeom: 行列合法域 1…4",
                  TerminalGridPlanner.validate(rows: 1, cols: 1)
                  && TerminalGridPlanner.validate(rows: 4, cols: 4)
                  && !TerminalGridPlanner.validate(rows: 0, cols: 1)
                  && !TerminalGridPlanner.validate(rows: 5, cols: 1)
                  && !TerminalGridPlanner.validate(rows: 1, cols: 5))

            // inferGrid 容差边界：≤ tolerance 同带、> tolerance 分带
            let tolerant = TerminalGridPlanner.inferGrid(from: [
                CGRect(x: 0, y: 0, width: 100, height: 100),
                CGRect(x: 0, y: 40, width: 100, height: 100),
            ])
            let intolerant = TerminalGridPlanner.inferGrid(from: [
                CGRect(x: 0, y: 0, width: 100, height: 100),
                CGRect(x: 0, y: 41, width: 100, height: 100),
            ])
            check("coordGeom: inferGrid 容差边界（40 同带 / 41 分带）",
                  tolerant?.rows == 1 && tolerant?.cols == 1
                  && intolerant?.rows == 2 && intolerant?.cols == 1)
            check("coordGeom: inferGrid 空输入/超 4 行 → nil",
                  TerminalGridPlanner.inferGrid(from: []) == nil
                  && TerminalGridPlanner.inferGrid(from: (0..<5).map {
                      CGRect(x: 0, y: CGFloat($0) * 100, width: 100, height: 50)
                  }) == nil)

            // rowMajorOrder：带链不传递时仍按确定性带号排序
            let chain = [
                CGRect(x: 0, y: 110, width: 100, height: 100),   // midY 160
                CGRect(x: 0, y: 50, width: 100, height: 100),    // midY 100
                CGRect(x: 0, y: 80, width: 100, height: 100),    // midY 130
            ]
            let ordered = TerminalGridPlanner.rowMajorOrder(chain)
            check("coordGeom: rowMajorOrder 带链（100/130/160）稳定输出 100→130→160",
                  ordered.map { $0.midY } == [100, 130, 160])
            // 同带内按 x
            let sameBand = TerminalGridPlanner.rowMajorOrder([
                CGRect(x: 200, y: 0, width: 100, height: 100),
                CGRect(x: 0, y: 20, width: 100, height: 100),
            ])
            check("coordGeom: rowMajorOrder 同带内按 x 排序",
                  sameBand.map { $0.midX } == [50, 250])
            // 同位置按输入序（稳定），旧 sort 无此保证
            let r2 = CGRect(x: 0, y: 20, width: 100, height: 60)   // midY 50
            let r1 = CGRect(x: 0, y: 0, width: 100, height: 100)   // midY 50
            let stable = TerminalGridPlanner.rowMajorOrder([r2, r1])
            check("coordGeom: rowMajorOrder 同位置保持输入序",
                  stable.count == 2 && stable[0] == r2 && stable[1] == r1)

            // clampToVisible 退化与越界
            check("coordGeom: clampToVisible 零面积可视区原样返回",
                  TerminalGridPlanner.clampToVisible(
                    frame: CGRect(x: 1, y: 2, width: 3, height: 4), visibleFrame: .zero)
                  == CGRect(x: 1, y: 2, width: 3, height: 4))
            check("coordGeom: clampToVisible 超大 frame 收窄并夹到负原点可视区",
                  TerminalGridPlanner.clampToVisible(
                    frame: CGRect(x: 100, y: 100, width: 500, height: 500),
                    visibleFrame: CGRect(x: -200, y: -200, width: 400, height: 400))
                  == CGRect(x: -200, y: -200, width: 400, height: 400))
            check("coordGeom: clampToVisible 零尺寸保底 1pt",
                  TerminalGridPlanner.clampToVisible(
                    frame: CGRect(x: 10, y: 10, width: 0, height: 0),
                    visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
                  == CGRect(x: 10, y: 10, width: 1, height: 1))
            check("coordGeom: clampToVisible 屏外小窗平移回边界",
                  TerminalGridPlanner.clampToVisible(
                    frame: CGRect(x: -500, y: -500, width: 100, height: 100),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
                  == CGRect(x: 0, y: 0, width: 100, height: 100))

            check("coordGeom: coveringGrid 0 格保底 1×1、超大封顶 4×4",
                  TerminalGridPlanner.coveringGrid(inferred: (0, 0), cellCount: 0) == (rows: 1, cols: 1)
                  && TerminalGridPlanner.coveringGrid(inferred: (5, 5), cellCount: 100) == (rows: 4, cols: 4))
            check("coordGeom: coveringGrid 先扩列后扩行",
                  TerminalGridPlanner.coveringGrid(inferred: (2, 2), cellCount: 5) == (rows: 2, cols: 3))
        }

        // ===== H. DisplayWorkArea：四边推断 / 阈值边界 / 探测只缩不涨 =====
        do {
            let planning = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 200, _ h: CGFloat = 200) -> CGRect {
                CGRect(x: x, y: y, width: w, height: h)
            }
            let inferred = DisplayWorkArea.inferInsets(
                planned: [cell(0, 0), cell(800, 800)],
                actual: [cell(10, 20), cell(770, 790, 200, 180)],
                planningFrame: planning)
            check("coordGeom: inferInsets 四边同时推断（top20/left10/bottom30/right30）",
                  inferred == WorkAreaInsets(top: 20, left: 10, bottom: 30, right: 30))

            check("coordGeom: inferInsets 实际越界（负推离）不学习",
                  DisplayWorkArea.inferInsets(planned: [cell(0, 0)],
                                              actual: [cell(0, -10)],
                                              planningFrame: planning) == .zero)
            check("coordGeom: inferInsets 噪声阈边界——1.5 不学、1.6 取整为 2",
                  DisplayWorkArea.inferInsets(planned: [cell(0, 0)],
                                              actual: [cell(0, 1.5)],
                                              planningFrame: planning).top == 0
                  && DisplayWorkArea.inferInsets(planned: [cell(0, 0)],
                                                 actual: [cell(0, 1.6)],
                                                 planningFrame: planning).top == 2)
            check("coordGeom: inferInsets 上限边界——200 学、200.6 不学",
                  DisplayWorkArea.inferInsets(planned: [cell(0, 0)],
                                              actual: [cell(0, 200)],
                                              planningFrame: planning).top == 200
                  && DisplayWorkArea.inferInsets(planned: [cell(0, 0)],
                                                 actual: [cell(0, 200.6)],
                                                 planningFrame: planning).top == 0)
            check("coordGeom: inferInsets actual 少于 planned 时按 zip 截断不崩",
                  DisplayWorkArea.inferInsets(planned: [cell(0, 0), cell(800, 800)],
                                              actual: [cell(0, 25)],
                                              planningFrame: planning).top == 25)

            let learned = WorkAreaInsets(top: 10, left: 20, bottom: 30, right: 40)
            let probe = CGRect(x: 0, y: 0, width: 400, height: 300)
            check("coordGeom: probedInsets learned 为零时探测推离不反向生效",
                  DisplayWorkArea.probedInsets(probeTarget: probe,
                                               actual: CGRect(x: 0, y: 25, width: 400, height: 300),
                                               learned: .zero) == .zero)
            check("coordGeom: probedInsets 只缩 top/left，bottom/right 原样保留",
                  DisplayWorkArea.probedInsets(probeTarget: probe,
                                               actual: CGRect(x: 10, y: 0, width: 400, height: 300),
                                               learned: learned)
                  == WorkAreaInsets(top: 0, left: 10, bottom: 30, right: 40))

            check("coordGeom: plannedFrame 负原点可视区扣减",
                  DisplayWorkArea.plannedFrame(
                    visibleFrame: CGRect(x: -1920, y: 37, width: 1920, height: 1080),
                    insets: WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 15))
                  == CGRect(x: -1920, y: 62, width: 1905, height: 1055))
            check("coordGeom: insets merged 逐边独立取 max",
                  WorkAreaInsets(top: 10, left: 50, bottom: 0, right: 5)
                    .merged(with: WorkAreaInsets(top: 20, left: 0, bottom: 30, right: 1))
                  == WorkAreaInsets(top: 20, left: 50, bottom: 30, right: 5))

            let suiteName = "vibefocus-coordgeom-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            DisplayWorkArea.store(WorkAreaInsets(top: 10, left: 0, bottom: 0, right: 0),
                                  displayID: 1, defaults: defaults)
            DisplayWorkArea.store(WorkAreaInsets(top: 20, left: 0, bottom: 0, right: 0),
                                  displayID: 2, defaults: defaults)
            DisplayWorkArea.store(.zero, displayID: 1, defaults: defaults)
            check("coordGeom: 多屏 insets 表摘除单屏不串扰",
                  DisplayWorkArea.learnedInsets(displayID: 1, defaults: defaults) == .zero
                  && DisplayWorkArea.learnedInsets(displayID: 2, defaults: defaults)
                  == WorkAreaInsets(top: 20, left: 0, bottom: 0, right: 0))
        }

        // ===== I. 屏幕热插拔守卫（纯函数；此前仅 XCTest 套件覆盖，Runner 基线缺位） =====
        do {
            let a = UUID(), b = UUID(), c = UUID()
            check("coordGeom: 热插拔身份集合相等 / 重排放行",
                  ScreenHotplugGuard.identityMatches(preUUIDs: [a, b, c], currentUUIDs: [c, a, b]))
            check("coordGeom: 热插拔增屏 / 减屏 / 换屏均丢弃",
                  !ScreenHotplugGuard.identityMatches(preUUIDs: [a, b], currentUUIDs: [a])
                  && !ScreenHotplugGuard.identityMatches(preUUIDs: [a], currentUUIDs: [a, b])
                  && !ScreenHotplugGuard.identityMatches(preUUIDs: [a, b], currentUUIDs: [a, c]))
            let results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] = [
                (index: 0, uuid: a, displayIndex: 1, spaceIndex: 1),
                (index: 1, uuid: b, displayIndex: 2, spaceIndex: nil),
            ]
            check("coordGeom: 热插拔结果过滤剔除已消失屏",
                  ScreenHotplugGuard.filterStale(results, liveUUIDs: [a]).map { $0.uuid } == [a])
            check("coordGeom: 热插拔结果过滤全存活 / 全过期",
                  ScreenHotplugGuard.filterStale(results, liveUUIDs: [a, b]).count == 2
                  && ScreenHotplugGuard.filterStale(results, liveUUIDs: [c]).isEmpty)
        }
    }
}
