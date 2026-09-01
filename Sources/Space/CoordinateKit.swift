import AppKit
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
    static func screenArray(_ index: Int) -> DisplayIdentifier { .screenArrayIndex(index) }
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

    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }

    func centerIsInside(_ screenFrame: CGRect) -> Bool {
        screenFrame.contains(CGPoint(x: midX, y: midY))
    }
}

// MARK: - 坐标转换

/// Utility for converting between CG, yabai, and NSScreen coordinate systems.
@MainActor
enum CoordinateKit {

    // MARK: 显示器相关

    static var mainScreenQuartzFrame: CGRect? {
        // P-INST-134: 主屏 Quartz 帧查询耗时（NSScreen.screens AppKit 显示配置数组遍历找 origin==.zero；toggle/move/overlay 坐标计算高频调用；mainScreenHeight/isOnMainScreen 经此委托）。
        #if PERF_INSTRUMENT
        let mpqfStart = Date()
        defer {
            log("[CoordinateKit] mainScreenQuartzFrame finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: mpqfStart))
            ])
        }
        #endif
        return NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? NSScreen.screens.first?.frame
    }

    static var mainScreenHeight: CGFloat {
        // P-INST-268: 主屏高度计算属性（mainScreenQuartzFrame P-INST-134 + NSScreen.screens.first.frame 读 fallback；坐标转换高频调用，NSScreen.screens 可能阻塞 WindowServer；slow-op ≥30ms warn）。
        #if PERF_INSTRUMENT
        let mshStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: mshStart)
            if durMs >= 30 { log("[CoordinateKit] mainScreenHeight slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        return mainScreenQuartzFrame?.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    /// 获取屏幕的可用区域（去掉菜单栏和 Dock），返回 Quartz 坐标
    static func quartzVisibleFrame(of screen: NSScreen) -> CGRect {
        // P-INST-266: NSScreen 可见区域转 Quartz 坐标（screen.visibleFrame 动态计算去菜单栏/Dock + frame 读；窗口定位/axFrame 调用，visibleFrame 可能查 WindowServer；slow-op ≥30ms warn）。
        #if PERF_INSTRUMENT
        let qvfStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: qvfStart)
            if durMs >= 30 { log("[CoordinateKit] quartzVisibleFrame slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        let visibleFrame = screen.visibleFrame
        if screen.frame.origin == .zero {
            let screenMaxY = screen.frame.maxY
            return CGRect(
                x: visibleFrame.origin.x,
                y: screenMaxY - visibleFrame.maxY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        }
        return visibleFrame
    }

    static func isOnMainScreen(_ point: CGPoint) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return mainFrame.contains(point)
    }

    static func isOnMainScreen(_ rect: CGRect) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return isOnMainScreen(rect, mainScreenFrame: mainFrame)
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

    // MARK: 坐标系转换

    static func cocoaY(fromQuartzY quartzY: CGFloat) -> CGFloat {
        mainScreenHeight - quartzY
    }

    static func quartzY(fromCocoaY cocoaY: CGFloat) -> CGFloat {
        mainScreenHeight - cocoaY
    }

    // MARK: 显示器索引转换

    static func nsScreen(forCGDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        // P-INST-136: CGDisplayID→NSScreen 查询耗时（NSScreen.screens 遍历 + cgDirectDisplayID deviceDescription 读；显示器索引转换）。
        #if PERF_INSTRUMENT
        let nsgStart = Date()
        defer {
            log("[CoordinateKit] nsScreen(forCGDisplayID:) finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: nsgStart))
            ])
        }
        #endif
        return NSScreen.screens.first { $0.cgDirectDisplayID == displayID }
    }

    static func screenArrayIndex(for screen: NSScreen) -> Int? {
        // P-INST-137: NSScreen→数组索引查询耗时（NSScreen.screens.firstIndex Equatable 查找；显示器索引转换）。
        #if PERF_INSTRUMENT
        let saiStart = Date()
        defer {
            log("[CoordinateKit] screenArrayIndex finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: saiStart))
            ])
        }
        #endif
        return NSScreen.screens.firstIndex(of: screen)
    }

    static func cgDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.cgDirectDisplayID
    }

    /// yabai display index (1-based) → NSScreen
    static func nsScreen(forYabaiDisplayIndex index: Int) -> NSScreen? {
        // P-INST-138: yabai display index→NSScreen 查询耗时（NSScreen.screens 读取 + filter 非主屏 + 索引访问；overlay/display 索引转换）。
        #if PERF_INSTRUMENT
        let nsyStart = Date()
        defer {
            log("[CoordinateKit] nsScreen(forYabaiDisplayIndex:) finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: nsyStart))
            ])
        }
        #endif
        let screens = NSScreen.screens
        guard index >= 1, index <= screens.count else { return nil }
        if index == 1 {
            return screens.first { $0.frame.origin == .zero } ?? screens.first
        }
        let nonMainScreens = screens.filter { $0.frame.origin != .zero }
        let nonMainIndex = index - 2
        guard nonMainIndex >= 0, nonMainIndex < nonMainScreens.count else { return nil }
        return nonMainScreens[nonMainIndex]
    }

    /// NSScreen → yabai display index (1-based)。nsScreen(forYabaiDisplayIndex:) 的逆映射：
    /// 主屏（origin .zero）= 1，非主屏按 NSScreen.screens 中的先后次序 = 2, 3, …
    /// 消费方必须经本函数取 yabai 索引，禁止把 NSScreen 数组下标直接当 yabai 索引写入
    /// （2.16a 第十三刀前 ToggleRecord.sourceDisplay 曾因此把副屏记成 yabai(1)=主屏）。
    static func yabaiDisplayIndex(for screen: NSScreen) -> Int? {
        let screens = NSScreen.screens
        if screen.frame.origin == .zero { return 1 }
        var yabaiIndex = 2
        for candidate in screens where candidate.frame.origin != .zero {
            if candidate == screen { return yabaiIndex }
            yabaiIndex += 1
        }
        return nil
    }

    // MARK: 窗口帧收敛判据（唯一事实源）

    /// 位置漂移和 |dx| + |dy|（日志展示与收敛判定共用同一数值）。
    static func originDrift(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    /// 尺寸漂移和 |dw| + |dh|（日志展示与收敛判定共用同一数值）。
    static func sizeDrift(_ a: CGSize, _ b: CGSize) -> CGFloat {
        abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// size 收敛判定：漂移和 ≤ 容差。
    /// 语义约定（playbook 2.16a 第十二刀统一）：全仓收敛判据一律用"漂移和"而非逐轴比较——
    /// 逐轴允许单轴贴容差、另一轴再漂的合计超调（历史上 apply 循环逐轴、PostMove 漂移和，
    /// 两层判据不一致曾出现 apply 判收敛、PostMove 立即重写的自我打架）。
    static func isSizeConverged(actual: CGSize, target: CGSize, tolerance: CGFloat) -> Bool {
        sizeDrift(actual, target) <= tolerance
    }

    /// 整 frame 收敛判定：origin 与 size 双维度漂移和均 ≤ 容差。
    /// 使用点：moveWindowToFrameViaYabai 闭环验证。
    static func isFrameConverged(actual: CGRect, target: CGRect, tolerance: CGFloat) -> Bool {
        originDrift(actual.origin, target.origin) <= tolerance &&
        sizeDrift(actual.size, target.size) <= tolerance
    }

    static func isFrameOnExpectedScreen(_ frame: CGRect, expectedScreen: NSScreen) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return expectedScreen.frame.contains(center)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var cgDirectDisplayID: CGDirectDisplayID? {
        // P-INST-139: NSScreen→CGDisplayID 读取耗时（deviceDescription 字典查 NSScreenNumber；显示器 ID 转换，nsScreen(forCGDisplayID:) 等遍历中调用）。
        #if PERF_INSTRUMENT
        let cgdStart = Date()
        defer {
            log("[CoordinateKit] cgDirectDisplayID finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: cgdStart))
            ])
        }
        #endif
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isMainScreen: Bool { frame.origin == .zero }
}
