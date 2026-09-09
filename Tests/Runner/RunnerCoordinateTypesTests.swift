import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerCoordinateTypesTests.swift — B78：CoordinateKit 值类型三镜像退役转真身直测。
// CoordinateKit 函数族（quartzY/cocoaY/clampFrame/收敛判据族）已有 Runner 直测；三镜像
// （CoordinateKitLogicTests/QuartzRectTests/QuartzConversionTests）中仍属真身缺口的剩余
// 契约收拢到本文件：DisplayIdentifier/SpaceIdentifier/QuartzRect 的 Equatable、便捷构造、
// yabaiIndex 取值、日志描述族（description/originDescription/sizeDescription——真身新加
// 成员，镜像副本没有，含 Int() 向零截断语义锁定）。换算恒等式镜像段与既有直测重复，不重复。

extension RunnerHarness {
    func runCoordinateTypesTests() {
        // ===== A. DisplayIdentifier：三体系显示器标识 =====
        do {
            check("dispID: 同值相等、异值/异型不等",
                  DisplayIdentifier.yabai(2) == .yabai(2)
                  && DisplayIdentifier.yabai(2) != .yabai(3)
                  && DisplayIdentifier.yabai(2) != .cgDisplay(2)
                  && DisplayIdentifier.cgDisplay(7) == .cgDisplay(7)
                  && DisplayIdentifier.cgDisplay(7) != .cgDisplay(8))
            check("dispID: yabaiIndex 取值——仅 yabai case 有值（screen 数组序/cgDisplay 均 nil）",
                  DisplayIdentifier.yabai(2).yabaiIndex == 2
                  && DisplayIdentifier.screenArrayIndex(0).yabaiIndex == nil
                  && DisplayIdentifier.cgDisplay(7).yabaiIndex == nil)
            check("dispID: description 三形态格式锁定（日志 grep 依赖）",
                  DisplayIdentifier.yabai(2).description == "yabai(2)"
                  && DisplayIdentifier.screenArrayIndex(0).description == "screen[0]"
                  && DisplayIdentifier.cgDisplay(7).description == "cgDisplay(7)")
        }

        // ===== B. SpaceIdentifier：双体系工作区标识 =====
        do {
            check("spaceID: 同值相等、异值/异型不等、native 构造往返",
                  SpaceIdentifier.yabai(3) == .yabai(3)
                  && SpaceIdentifier.yabai(3) != .yabai(4)
                  && SpaceIdentifier.yabai(3) != .nativeID(3)
                  && SpaceIdentifier.native(42) == .native(42))
            check("spaceID: yabaiIndex 取值——nativeID 无 yabai 索引",
                  SpaceIdentifier.yabai(3).yabaiIndex == 3
                  && SpaceIdentifier.native(42).yabaiIndex == nil)
            check("spaceID: description 两形态格式锁定",
                  SpaceIdentifier.yabai(3).description == "yabai_space(3)"
                  && SpaceIdentifier.native(42).description == "native_space(42)")
        }

        // ===== C. QuartzRect：Quartz 矩形值对象 =====
        do {
            let r = QuartzRect(x: 100, y: 200, width: 800, height: 600)
            check("quartzRect: 几何访问器 x/y/w/h/midX/midY/maxX/maxY",
                  r.x == 100 && r.y == 200 && r.width == 800 && r.height == 600
                  && r.midX == 500 && r.midY == 500 && r.maxX == 900 && r.maxY == 800)
            let cg = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            check("quartzRect: CGRect 入构造与 cgRect 回环",
                  QuartzRect(cg).cgRect == cg && QuartzRect(cg).midY == 558.5)
            check("quartzRect: Equatable 同值相等、异 origin 不等",
                  r == QuartzRect(x: 100, y: 200, width: 800, height: 600)
                  && r != QuartzRect(x: 101, y: 200, width: 800, height: 600))
            // 日志描述族：Int() 向零截断（-1.9 → -1），非四舍五入非 floor——27 调用点同源
            check("quartzRect: description/originDescription/sizeDescription 格式+截断语义",
                  QuartzRect(x: 1480, y: -707, width: 1146, height: 707).description == "1480,-707 1146x707"
                  && QuartzRect(x: -1.9, y: 2.9, width: 3.9, height: 0).originDescription == "-1,2"
                  && QuartzRect(x: -1.9, y: 2.9, width: 3.9, height: 7.7).sizeDescription == "3x7")
        }
    }
}
