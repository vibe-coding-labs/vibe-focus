import CoreGraphics
import Foundation
import CoreGraphics
import Foundation

/// macOS 使用两套坐标系：
/// - Quartz (CoreGraphics): 原点在主屏左上角，Y 轴向下。AX API、CGWindowList、yabai 使用此坐标系。
/// - Cocoa (AppKit): 原点在主屏左下角，Y 轴向上。NSScreen 使用此坐标系。
/// 本模块统一使用 Quartz 坐标系作为内部标准，仅在需要与 NSScreen 交互时转换。

/// 显示器标识 — 封装三种不同的显示器索引方式
enum DisplayIdentifier: Equatable, CustomStringConvertible {
    /// yabai 的 1-based 显示器索引（display 1 = 主屏）
    case yabaiIndex(Int)
    /// NSScreen.screens 数组的 0-based 索引（index 0 = 主屏）
    case screenArrayIndex(Int)
    /// CoreGraphics 硬件级显示器标识符
    case cgDirectDisplayID(UInt32)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai(\(i))"
        case .screenArrayIndex(let i): return "screen[\(i)]"
        case .cgDirectDisplayID(let id): return "cgDisplay(\(id))"
        }
    }
}

/// 工作区标识 — 封装两种不同的工作区索引方式
enum SpaceIdentifier: Equatable, CustomStringConvertible {
    /// yabai 的全局 space 索引（space 1 = 主屏第一个 space）
    case yabaiIndex(Int)
    /// macOS 原生 space ID（CGSPrivate 中的 space identifier）
    case nativeID(Int64)

    var description: String {
        switch self {
        case .yabaiIndex(let i): return "yabai_space(\(i))"
        case .nativeID(let id): return "native_space(\(id))"
        }
    }
}

// MARK: - DisplayIdentifier Convenience

extension DisplayIdentifier {
    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
    static func yabai(_ index: Int) -> DisplayIdentifier { .yabaiIndex(index) }
    static func cgDisplay(_ id: UInt32) -> DisplayIdentifier { .cgDirectDisplayID(id) }
}

// MARK: - SpaceIdentifier Convenience

extension SpaceIdentifier {
    var yabaiIndex: Int? { if case .yabaiIndex(let i) = self { return i } else { return nil } }
    static func yabai(_ index: Int) -> SpaceIdentifier { .yabaiIndex(index) }
    static func native(_ id: Int64) -> SpaceIdentifier { .nativeID(id) }
}

/// 窗口坐标矩形 — 始终使用 Quartz 坐标系（原点在主屏左上角，Y 向下）
struct QuartzRect: Equatable, CustomStringConvertible {
    let origin: CGPoint
    let size: CGSize

    var x: CGFloat { origin.x }
    var y: CGFloat { origin.y }
    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var midX: CGFloat { origin.x + size.width / 2 }
    var midY: CGFloat { origin.y + size.height / 2 }
    var maxX: CGFloat { origin.x + size.width }
    var maxY: CGFloat { origin.y + size.height }

    init(_ cgRect: CGRect) {
        self.origin = cgRect.origin
        self.size = cgRect.size
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.origin = CGPoint(x: x, y: y)
        self.size = CGSize(width: width, height: height)
    }

    var cgRect: CGRect { CGRect(origin: origin, size: size) }

    // MARK: 日志描述族（唯一事实源，2.16a 第十五刀）
    // 此前 27 处调用点各自内联同一 Int() 截断格式串，格式漂移即日志 grep 失真。
    // 数值转换语义 = Int() 向零截断（-1.9 → -1），非四舍五入、非 floor。

    /// 全帧描述 "x,y WxH"
    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }

    /// origin-only 描述 "x,y"（log 字段只关心位置时）
    var originDescription: String { "\(Int(x)),\(Int(y))" }

    /// size-only 描述 "WxH"（log 字段只关心尺寸时）
    var sizeDescription: String { "\(Int(width))x\(Int(height))" }
}

// MARK: - 坐标转换

/// Utility for converting between CG, yabai, and NSScreen coordinate systems.
enum CoordinateKit {

    /// AppKit 全局 y → Quartz 全局 y（纯函数，RunnerRegistryStoreTests coord 块锁定）。
    /// AppKit 主屏左下为原点 y 向上，Quartz 主屏左上为原点 y 向下：
    /// quartzY = 主屏 AppKit maxY − 矩形 AppKit maxY。
    /// 对主屏与非主屏统一成立（主屏即历史主屏分支公式 screenMaxY − visibleMaxY）。
    static func quartzY(appKitRectMaxY: CGFloat, primaryMaxY: CGFloat) -> CGFloat {
        primaryMaxY - appKitRectMaxY
    }

    /// 获取屏幕的可用区域（去掉菜单栏和 Dock），返回 Quartz 坐标
    /// 把 frame 夹进 bounds：尺寸按 min 收窄、位置夹回 bounds 内部。
    /// P1 保守退让共用纯函数（restore 屏外 origFrame 补救 / stuck 解堵尺寸保持），
    /// mirror 测试：Tests/Standalone/FrameClampTests.swift。
    static func clampFrame(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = max(bounds.minX, min(frame.origin.x, bounds.maxX - width))
        let y = max(bounds.minY, min(frame.origin.y, bounds.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 窗口是否在主屏 — 全仓唯一的"主屏归属"判定实现。
    ///
    /// ## 场景
    /// - toggle 焦点解析（三分支共用）、isWindowOnMainScreen（hook 预检）、候选窗口筛选；
    /// - 主屏 frame 由调用方显式传入（toggle 传入口缓存的 cachedMainScreen.frame，避免
    ///   热路径内重复枚举 NSScreen.screens；无缓存的调用方用单参重载，内部取
    ///   mainScreenQuartzFrame）。
    ///
    /// ## 坐标约定
    /// - rect 是 Quartz（CGWindowList）坐标；主屏 Cocoa frame (0,0,W,H) 与主屏 Quartz
    ///   rect 数值区间一致（y 轴方向相反但区间相同），对"是否在主屏"这一布尔判定
    ///   等价——真实显示器物理上不重叠，其他屏的 Quartz 坐标不可能落入主屏区间。
    /// - 若未来需要区分"在主屏的哪一半"，必须先做 cocoaY(fromQuartzY:) 转换。
    static func isOnMainScreen(_ rect: CGRect, mainScreenFrame: CGRect) -> Bool {
        mainScreenFrame.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: 窗口帧收敛判据（唯一事实源）
    // 四个判据均为纯数学（无 NSScreen/AppKit 触碰），nonisolated 使非隔离纯模块
    // （FrameConvergence 等）可直连——漂移公式由此唯一，调用方不再内联副本。

    /// 位置漂移和 |dx| + |dy|（日志展示与收敛判定共用同一数值）。
    nonisolated static func originDrift(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    /// 尺寸漂移和 |dw| + |dh|（日志展示与收敛判定共用同一数值）。
    nonisolated static func sizeDrift(_ a: CGSize, _ b: CGSize) -> CGFloat {
        abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// size 收敛判定：漂移和 ≤ 容差。
    /// 语义约定（playbook 2.16a 第十二刀统一）：全仓收敛判据一律用"漂移和"而非逐轴比较——
    /// 逐轴允许单轴贴容差、另一轴再漂的合计超调（历史上 apply 循环逐轴、PostMove 漂移和，
    /// 两层判据不一致曾出现 apply 判收敛、PostMove 立即重写的自我打架）。
    nonisolated static func isSizeConverged(actual: CGSize, target: CGSize, tolerance: CGFloat) -> Bool {
        sizeDrift(actual, target) <= tolerance
    }

    /// 整 frame 收敛判定：origin 与 size 双维度漂移和均 ≤ 容差。
    /// 使用点：moveWindowToFrameViaYabai 闭环验证、FrameConvergence.shortfalls。
    nonisolated static func isFrameConverged(actual: CGRect, target: CGRect, tolerance: CGFloat) -> Bool {
        originDrift(actual.origin, target.origin) <= tolerance &&
        sizeDrift(actual.size, target.size) <= tolerance
    }
}
