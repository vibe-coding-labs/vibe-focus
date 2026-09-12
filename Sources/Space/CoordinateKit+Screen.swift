// CoordinateKit+Screen.swift
// VibeFocus — 坐标查询的 AppKit 依赖半区（NSScreen 枚举/主屏帧/索引互转）
// 2026-09-08 B49 从 CoordinateKit.swift 拆分：纯坐标数学（无 AppKit 触碰）
// 与屏幕查询（NSScreen.screens 可能阻塞 WindowServer）分文件，落实原设计声明。

import AppKit
import CoreGraphics
import Foundation

extension CoordinateKit {

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
        // 历史注（2026-09-03 乱蹦连带修复）：非主屏此前原样返回 AppKit 坐标——副屏在
        // 主屏上方时 AppKit y 为正（+1117），Quartz 里应为负（-1055），yabai --move abs
        // 按 Quartz 解释，stuck 解堵把窗口直写到主屏下方不存在的屏幕区域
        //（trace toggle-00000129，窗口悬在屏外）。任意屏统一换算，主屏数值不变。
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else {
            return visibleFrame
        }
        return CGRect(
            x: visibleFrame.origin.x,
            y: quartzY(appKitRectMaxY: visibleFrame.maxY, primaryMaxY: primaryMaxY),
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }


    static func isOnMainScreen(_ point: CGPoint) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return mainFrame.contains(point)
    }

    static func isOnMainScreen(_ rect: CGRect) -> Bool {
        guard let mainFrame = mainScreenQuartzFrame else { return false }
        return isOnMainScreen(rect, mainScreenFrame: mainFrame)
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

    /// NSScreen → yabai display index (1-based)。nsScreen(forYabaiDisplayIndex:) 的逆映射。
    /// ⚠️ 猜序实现（主屏=1、其余按 NSScreen 次序）——同尺寸副屏反序即错。
    /// **仅作 SpaceController.exactYabaiDisplayIndex 的 yabai 不可用回退，
    /// 生产热路径禁止直接消费**（2026-09-08 minimap 对应关系错修复后收敛）。
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

    // MARK: - NSScreen ↔ yabai display 几何精确匹配

    /// NSScreen（Cocoa frame）↔ yabai display index 的几何精确匹配（纯函数）。
    ///
    /// ## 为什么不猜
    /// 历史实现按「origin=.zero 当 1 号屏、其余按 NSScreen.screens 次序数 2,3,…」
    /// 猜 yabai 索引——两块同尺寸副屏在两套排序里一旦反序，Space 胶囊就挂错屏，
    /// 点击切换切到别的屏（2026-09-08 用户实测「对应关系完全错误」）。本函数用
    /// `yabai -m query --displays` 的真实 index+frame 做几何匹配，顺序无关。
    ///
    /// ## 坐标转换
    /// yabai frame 是 Quartz TopLeft 全局坐标（主屏左上=原点，y 向下）；NSScreen.frame
    /// 是 Cocoa BottomLeft 全局坐标（主屏左下=原点，y 向上）。同一物理屏：
    /// `cocoaY = mainHeight - (quartzY + h)`，X 两系同值。mainHeight 由调用方传
    /// （origin=.zero 那块屏的 frame.height）。
    ///
    /// 匹配判据 = 转换后中心距最近的唯一配对（贪心：按距离升序占用，防同尺寸屏
    /// 双抢）。数量不符 / 空输入 → 空表（调用方回退老标注与空 Space 带）。
    ///
    /// - Returns: cocoaFrames 数组下标 → yabai display index
    static func matchYabaiDisplayIndices(
        cocoaFrames: [CGRect],
        mainHeight: CGFloat,
        yabaiIndices: [Int],
        yabaiQuartzFrames: [CGRect]
    ) -> [Int: Int] {
        guard mainHeight > 0,
              !cocoaFrames.isEmpty,
              yabaiIndices.count == yabaiQuartzFrames.count,
              !yabaiIndices.isEmpty
        else { return [:] }

        // Quartz TopLeft → Cocoa BottomLeft
        let yabaiCocoaFrames: [CGRect] = yabaiQuartzFrames.map { q in
            CGRect(x: q.minX, y: mainHeight - q.maxY, width: q.width, height: q.height)
        }

        // 全对全中心距，按距离升序贪心唯一配对
        var pairs: [(cocoa: Int, yabai: Int, distance: CGFloat)] = []
        for (ci, cf) in cocoaFrames.enumerated() {
            for (yi, yf) in yabaiCocoaFrames.enumerated() {
                let dx = cf.midX - yf.midX
                let dy = cf.midY - yf.midY
                pairs.append((ci, yi, dx * dx + dy * dy))
            }
        }
        pairs.sort { $0.distance < $1.distance }

        var result: [Int: Int] = [:]
        var usedCocoa = Set<Int>()
        var usedYabai = Set<Int>()
        for pair in pairs where pair.distance <= 64 {
            // 容差：中心距 ≤ 8pt（同屏仅差坐标转换舍入；不同屏中心距远大于此，
            // 不可能误配——贪心唯一配对同样兜底）
            if usedCocoa.contains(pair.cocoa) || usedYabai.contains(pair.yabai) { continue }
            usedCocoa.insert(pair.cocoa)
            usedYabai.insert(pair.yabai)
            result[pair.cocoa] = yabaiIndices[pair.yabai]
        }
        return result
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

