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
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? NSScreen.screens.first?.frame
    }

    static var mainScreenHeight: CGFloat {
        mainScreenQuartzFrame?.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    /// NSScreen → Quartz 帧转换
    static func quartzFrame(fromNSScreen screen: NSScreen) -> CGRect {
        guard screen.frame.origin == .zero else {
            return screen.frame
        }
        return screen.frame
    }

    /// 获取屏幕的可用区域（去掉菜单栏和 Dock），返回 Quartz 坐标
    static func quartzVisibleFrame(of screen: NSScreen) -> CGRect {
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
        return mainFrame.contains(CGPoint(x: rect.midX, y: rect.midY))
    }

    static func screenForRect(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let mainFrame = mainScreenQuartzFrame, mainFrame.contains(center) {
            return NSScreen.screens.first { $0.frame.origin == .zero }
        }
        for screen in NSScreen.screens where screen.frame.origin != .zero {
            if screen.frame.contains(center) {
                return screen
            }
        }
        return nil
    }

    // MARK: 坐标系转换

    static func cocoaY(fromQuartzY quartzY: CGFloat) -> CGFloat {
        mainScreenHeight - quartzY
    }

    static func quartzY(fromCocoaY cocoaY: CGFloat) -> CGFloat {
        mainScreenHeight - cocoaY
    }

    static func convertQuartzToCocoa(_ point: CGPoint, screenFrame: CGRect) -> CGPoint {
        if screenFrame.origin == .zero {
            return CGPoint(x: point.x, y: mainScreenHeight - point.y)
        }
        return point
    }

    // MARK: 显示器索引转换

    static func nsScreen(forCGDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.cgDirectDisplayID == displayID }
    }

    static func screenArrayIndex(for screen: NSScreen) -> Int? {
        NSScreen.screens.firstIndex(of: screen)
    }

    static func cgDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.cgDirectDisplayID
    }

    /// yabai display index (1-based) → NSScreen
    static func nsScreen(forYabaiDisplayIndex index: Int) -> NSScreen? {
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

    // MARK: 窗口帧验证

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10, heightTolerance: CGFloat? = nil) -> Bool {
        let ht = heightTolerance ?? tolerance * 2
        let positionMatches = abs(a.origin.x - b.origin.x) <= tolerance &&
                             abs(a.origin.y - b.origin.y) <= tolerance
        let sizeMatches = abs(a.width - b.width) <= tolerance * 2 &&
                         abs(a.height - b.height) <= ht
        return positionMatches && sizeMatches
    }

    static func isFrameOnExpectedScreen(_ frame: CGRect, expectedScreen: NSScreen) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return expectedScreen.frame.contains(center)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var cgDirectDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isMainScreen: Bool { frame.origin == .zero }
}
