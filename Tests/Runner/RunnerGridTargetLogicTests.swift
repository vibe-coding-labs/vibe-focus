import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerGridTargetLogicTests.swift — B72：GridTargetLogic 漂移镜像退役转真身直测。
// Tests/Standalone/GridTargetLogicTests.swift 机械比对实锤双料漂移（B61/B67/B68 家法）：
//   ① 真身 GridTargetCode 已加 summaryText（镜像的副本没有，穷举不到）；
//   ② 真身 MappedScreen 已加 yabaiDisplayIndex（屏号同源统一产物，镜像完全不认识该字段）；
//   ③ DisplayWorkArea/偏好语义段已被 RunnerDisplayWorkAreaTests(B70)/RunnerLayoutGridTests 直测覆盖。
// 本文件锁真身独有的剩余契约：GridTargetCode 编码端+往返+explicitDisplayID、
// TerminalGridPlanner.cells 无缝铺排几何（边界法取整）、ScreenLayoutMapper 胶囊带细节
// 与 yabaiDisplayIndex 透传（漂移证明点）。parse 侧/summaryText/gap·target 偏好已在
// RunnerRegistryStoreTests/RunnerSoundVoiceHookTests/RunnerLayoutGridTests 直测，不重复。

extension RunnerHarness {
    func runGridTargetLogicTests() {
        // ===== A. GridTargetCode：编码端 + parse↔code 全 case 往返 + explicitDisplayID =====
        do {
            check("gridTarget: code 编码端四形态（main/focused/dN/dNsM）",
                  GridTargetCode.main.code == "main"
                  && GridTargetCode.focused.code == "focused"
                  && GridTargetCode.display(displayID: 42).code == "d42"
                  && GridTargetCode.displaySpace(displayID: 7, spaceIndex: 3).code == "d7s3")
            let all: [GridTargetCode] = [
                .main, .focused, .display(displayID: 42), .displaySpace(displayID: 7, spaceIndex: 3),
            ]
            check("gridTarget: 全 case parse(code) 往返 == self",
                  all.allSatisfy { GridTargetCode.parse($0.code) == $0 })
            check("gridTarget: parse s 后空数字（d1s）→ nil",
                  GridTargetCode.parse("d1s") == nil)
            check("gridTarget: UInt32 上界可解、溢出拒绝",
                  GridTargetCode.parse("d4294967295") == .display(displayID: 4294967295)
                  && GridTargetCode.parse("d4294967296") == nil)
            check("gridTarget: explicitDisplayID——main/focused 无固定屏，display/displaySpace 取屏 ID",
                  GridTargetCode.main.explicitDisplayID == nil
                  && GridTargetCode.focused.explicitDisplayID == nil
                  && GridTargetCode.display(displayID: 42).explicitDisplayID == 42
                  && GridTargetCode.displaySpace(displayID: 7, spaceIndex: 3).explicitDisplayID == 7)
        }

        // ===== B. TerminalGridPlanner.cells：无缝铺排几何（边界法取整真身） =====
        do {
            let visible = CGRect(x: 0, y: 0, width: 2560, height: 1440)

            // 2×2 gap=0：严格共边、并集恰铺满、面积和守恒
            let g4 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 2, cols: 2))
            check("planner: 2×2 gap=0 出 4 格且横纵相邻严格共边",
                  g4.count == 4
                  && g4[0].maxX == g4[1].minX && g4[2].maxX == g4[3].minX
                  && g4[0].maxY == g4[2].minY && g4[1].maxY == g4[3].minY)
            check("planner: 2×2 gap=0 并集恰好铺满可视区（四角对齐无越界）",
                  g4[0] == CGRect(x: 0, y: 0, width: 1280, height: 720)
                  && g4[3] == CGRect(x: 1280, y: 720, width: 1280, height: 720))
            check("planner: 2×2 gap=0 面积之和 == 可视区面积（无重叠无缝隙）",
                  abs(g4.reduce(0) { $0 + $1.width * $1.height } - visible.width * visible.height) < 0.5)

            // 1×3 gap=0 非整除宽（2560/3）：共边、末格贴右缘、整数格线、宽度差 ≤1
            let g3 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 1, cols: 3))
            check("planner: 1×3 非整除相邻共边且末格严格贴右缘",
                  g3[0].maxX == g3[1].minX && g3[1].maxX == g3[2].minX
                  && g3[2].maxX == visible.maxX)
            check("planner: 1×3 全部格线为整数像素（窗口写入只接受整数）",
                  g3.allSatisfy { f in
                      f.origin.x == f.origin.x.rounded() && f.origin.y == f.origin.y.rounded()
                      && f.width == f.width.rounded() && f.height == f.height.rounded()
                  })
            check("planner: 1×3 非整除三格宽度差 ≤1px（853/854/853）",
                  g3.map(\.width).max()! - g3.map(\.width).min()! <= 1)

            // 3×3 非整除：并集铺满 + 末行贴底
            let g9 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 3, cols: 3))
            check("planner: 3×3 非整除并集恰铺满且末行贴底、角格贴右缘",
                  g9.count == 9
                  && g9[6].minY == g9[3].maxY && g9[8].maxY == visible.maxY
                  && g9[8].maxX == visible.maxX && g9[8].minX == g9[7].maxX)

            // 显式 gap：恰缝、总宽守恒
            let g8 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 1, cols: 2, gap: 8))
            check("planner: 1×2 gap=8 格间恰 8px 且两格宽+缝 == 可视区宽",
                  g8[1].minX - g8[0].maxX == 8
                  && g8[0].width + g8[1].width + 8 == visible.width
                  && g8[0].minX == visible.minX && g8[1].maxX == visible.maxX)
            let g6 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 1, cols: 3, gap: 6))
            check("planner: 1×3 gap=6 每条缝恰 6px 且末格贴右缘",
                  g6[1].minX - g6[0].maxX == 6 && g6[2].minX - g6[1].maxX == 6
                  && g6[2].maxX == visible.maxX)

            // 防御：负 gap 按 0、非法行列/零面积可视区 → 空
            let negGap = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 2, cols: 2, gap: -5))
            check("planner: 负 gap 钳 0（与 gap=0 全等）", negGap == g4)
            check("planner: 行列越界/零面积可视区 → 空数组",
                  TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 0, cols: 2)).isEmpty
                  && TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 2, cols: 5)).isEmpty
                  && TerminalGridPlanner.cells(visibleFrame: .zero, spec: .init(rows: 2, cols: 2)).isEmpty)
        }

        // ===== C. ScreenLayoutMapper：胶囊带细节 + yabaiDisplayIndex 透传（镜像漂移证明点） =====
        do {
            // 单屏 1000×100、viewSize 恰容 padding 14 → scale=1，view frame=(14,14,1000,100)
            let screen = ScreenLayoutMapper.InputScreen(
                displayID: 1, name: "主屏", cocoaFrame: CGRect(x: 0, y: 0, width: 1000, height: 100),
                isMain: true,
                spaces: [
                    .init(yabaiIndex: 3, isVisible: false),
                    .init(yabaiIndex: 5, isVisible: true),
                    .init(yabaiIndex: 7, isVisible: false),
                    .init(yabaiIndex: 9, isVisible: true),
                ],
                yabaiDisplayIndex: 3)
            let mapped = ScreenLayoutMapper.map(screens: [screen], viewSize: CGSize(width: 1028, height: 128))
            let ms = mapped.screens[0]

            // 漂移证明点：屏号同源统一加进真身的字段，镜像的 MappedScreen 副本没有它
            check("mapper: yabaiDisplayIndex 透传（缺省 nil 回退旧标注）",
                  ms.yabaiDisplayIndex == 3
                  && ScreenLayoutMapper.map(
                    screens: [ScreenLayoutMapper.InputScreen(
                        displayID: 1, name: "s", cocoaFrame: screen.cocoaFrame, isMain: true, spaces: [])],
                    viewSize: CGSize(width: 1028, height: 128)).screens[0].yabaiDisplayIndex == nil)

            // 4 胶囊等分：segment=(宽-2·inset)/4，块间恰 2px 视觉缝，全部内嵌屏底缘
            let capsules = ms.spaces
            let expectedSegment = (ms.frame.width - ScreenLayoutMapper.spaceStripInset * 2) / 4
            check("mapper: 4 胶囊等分可用宽且相邻恰 2px 缝",
                  capsules.count == 4
                  && abs(capsules[0].frame.width - (expectedSegment - ScreenLayoutMapper.spaceCapsuleGap)) < 0.0001
                  && zip(capsules, capsules.dropFirst()).allSatisfy {
                      abs($1.frame.minX - $0.frame.maxX - ScreenLayoutMapper.spaceCapsuleGap) < 0.0001
                  })
            check("mapper: 胶囊整条内嵌屏矩形（左右缩进 3、底缘贴 inset 3）",
                  capsules.allSatisfy { $0.frame.minX >= ms.frame.minX + ScreenLayoutMapper.spaceStripInset
                      && $0.frame.maxX <= ms.frame.maxX - ScreenLayoutMapper.spaceStripInset
                      && $0.frame.height == ScreenLayoutMapper.spaceStripHeight
                      && $0.frame.maxY == ms.frame.maxY - ScreenLayoutMapper.spaceStripInset })

            // 可见标记逐格透传 + visibleSpaceIndex 取首个可见（非首格时也正确）
            check("mapper: isVisible 逐格跟随输入、visibleSpaceIndex=首个可见的 yabai 索引",
                  capsules.map(\.yabaiIndex) == [3, 5, 7, 9]
                  && capsules.map(\.isVisible) == [false, true, false, true]
                  && ms.visibleSpaceIndex == 5)

            // 网格预览格线：相邻严格共边 + 末格贴屏右/下缘
            let preview = ScreenLayoutMapper.gridPreviewCells(
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rows: 2, cols: 2)
            check("mapper: 预览 2×2 相邻严格共边且末格贴屏右/下缘",
                  preview.count == 4
                  && preview[0].maxX == preview[1].minX && preview[0].maxY == preview[2].minY
                  && preview[3].maxX == 100 && preview[3].maxY == 100)
        }
    }
}
