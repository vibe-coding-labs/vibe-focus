// CoordinateKit+Screen.swift
// VibeFocus — 坐标查询的 AppKit 依赖半区（NSScreen 枚举/主屏帧/索引互转）
// 2026-09-08 B49 从 CoordinateKit.swift 拆分：纯坐标数学（无 AppKit 触碰）
// 与屏幕查询（NSScreen.screens 可能阻塞 WindowServer）分文件，落实原设计声明。

import AppKit
import CoreGraphics
import Foundation

@MainActor
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
