import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerHookPrefsSweepTests.swift — B217：Hook/LAN/Overlay 偏好层补扫。
//llvm-cov 0 计数行定向清零：ClaudeHookPreferences isEnabled/listenPort 默认分支/triggerOnStop
// 翻转取证行、LANHookPreferences parseLegacyBindings 旧格式迁移、ScreenIndexPreferences
// decodeWithLegacyFallback 三态与 CodableColor 往返。UserDefaults.standard 域全程存-还。

extension RunnerHarness {
    func runHookPrefsSweepTests() {
        // ===== ClaudeHookPreferences：isEnabled 三态 + 路径常量 =====
        do {
            let savedEnabled = UserDefaults.standard.object(forKey: ClaudeHookPreferences.enabledKey)
            defer {
                if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: ClaudeHookPreferences.enabledKey) }
                else { UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.enabledKey) }
            }
            UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.enabledKey)
            check("hookPrefs: isEnabled 未设置 → false（defaultEnabled）",
                  ClaudeHookPreferences.isEnabled == false)
            ClaudeHookPreferences.isEnabled = true
            check("hookPrefs: isEnabled set true → 回读 true", ClaudeHookPreferences.isEnabled == true)
            ClaudeHookPreferences.isEnabled = false

            check("hookPrefs: helperScriptDir 家目录拼接",
                  ClaudeHookPreferences.helperScriptDir.hasSuffix(".vibefocus"))
            check("hookPrefs: configFilePath 指向 hook-config.json",
                  ClaudeHookPreferences.configFilePath.hasSuffix(".vibefocus/hook-config.json"))
        }

        // ===== ClaudeHookPreferences：listenPort 缺省回落 + 读写双端钳制 =====
        do {
            let savedPort = UserDefaults.standard.object(forKey: ClaudeHookPreferences.portKey)
            defer {
                if let savedPort { UserDefaults.standard.set(savedPort, forKey: ClaudeHookPreferences.portKey) }
                else { UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.portKey) }
            }
            UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.portKey)
            check("hookPrefs: listenPort 未设置 → 默认 39277",
                  ClaudeHookPreferences.listenPort == ClaudeHookPreferences.defaultPort)
            UserDefaults.standard.set(80, forKey: ClaudeHookPreferences.portKey)   // 手写越界低位
            check("hookPrefs: 越界低位读时钳到 1024", ClaudeHookPreferences.listenPort == 1024)
            UserDefaults.standard.set(99999, forKey: ClaudeHookPreferences.portKey)
            check("hookPrefs: 越界高位读时钳到 65535", ClaudeHookPreferences.listenPort == 65535)
            ClaudeHookPreferences.listenPort = 80   // setter 同样钳制落库
            check("hookPrefs: setter 越界钳制落库", ClaudeHookPreferences.listenPort == 1024)
            check("hookPrefs: clampedUserPort 0 → 回默认",
                  ClaudeHookPreferences.clampedUserPort(0, defaultValue: 39277) == 39277)
            check("hookPrefs: clampedUserPort 域外双端钳制",
                  ClaudeHookPreferences.clampedUserPort(80) == 1024
                  && ClaudeHookPreferences.clampedUserPort(70000) == 65535
                  && ClaudeHookPreferences.clampedUserPort(5000) == 5000)
        }

        // ===== ClaudeHookPreferences：triggerOnStop 翻转取证分支（B192 防再犯） =====
        do {
            let savedStop = UserDefaults.standard.object(forKey: ClaudeHookPreferences.triggerOnStopKey)
            defer {
                if let savedStop { UserDefaults.standard.set(savedStop, forKey: ClaudeHookPreferences.triggerOnStopKey) }
                else { UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.triggerOnStopKey) }
            }
            UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.triggerOnStopKey)
            check("hookPrefs: triggerOnStop 未设置 → false（B192 默认关）",
                  ClaudeHookPreferences.triggerOnStop == false)
            ClaudeHookPreferences.triggerOnStop = true    // 翻转 → 落 INFO 取证行
            check("hookPrefs: triggerOnStop 翻转 true 生效",
                  ClaudeHookPreferences.triggerOnStop == true)
            ClaudeHookPreferences.triggerOnStop = false   // 同值写旧值读取分支
            ClaudeHookPreferences.triggerOnStop = false   // 翻转回默认
            check("hookPrefs: triggerOnStop 翻转回 false",
                  ClaudeHookPreferences.triggerOnStop == false)
        }

        // ===== LANHookPreferences：parseLegacyBindings 混态解析 =====
        do {
            let parsed = LANHookPreferences.parseLegacyBindings(from: [
                "u32": UInt32(77),
                "int": 88,
                "garbage": "not-a-number",
                "double": 3.5,
            ])
            check("lanPrefs: UInt32 直取", parsed["u32"] == Optional(Optional(UInt32(77))))
            check("lanPrefs: Int 转 UInt32", parsed["int"] == Optional(Optional(UInt32(88))))
            check("lanPrefs: 非数值垃圾跳过", parsed["garbage"] == nil && parsed["double"] == nil)
            check("lanPrefs: 空表解析为空",
                  LANHookPreferences.parseLegacyBindings(from: [:]).isEmpty)
        }

        // ===== LANHookPreferences：lanMode 三态 + remoteBindings 旧格式迁移写回 =====
        do {
            let savedMode = UserDefaults.standard.object(forKey: LANHookPreferences.lanModeKey)
            let savedBindings = UserDefaults.standard.string(forKey: "claudeHookRemoteBindings")
            defer {
                if let savedMode { UserDefaults.standard.set(savedMode, forKey: LANHookPreferences.lanModeKey) }
                else { UserDefaults.standard.removeObject(forKey: LANHookPreferences.lanModeKey) }
                if let savedBindings { UserDefaults.standard.set(savedBindings, forKey: "claudeHookRemoteBindings") }
                else { UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings") }
            }
            UserDefaults.standard.removeObject(forKey: LANHookPreferences.lanModeKey)
            check("lanPrefs: lanMode 未设置 → false（默认本机模式）",
                  LANHookPreferences.lanMode == false)
            LANHookPreferences.lanMode = true
            check("lanPrefs: lanMode set true → 回读 true", LANHookPreferences.lanMode == true)

            UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings")
            // 新格式 JSON string 源（setter 对 nil 值 compactMap 丢弃）
            LANHookPreferences.remoteBindings = ["m-1": 42, "m-2": nil]
            let roundtrip = LANHookPreferences.remoteBindings
            check("lanPrefs: 新格式读写往返（nil 值落库即丢弃）",
                  roundtrip["m-1"] == Optional(Optional(UInt32(42))) && roundtrip["m-2"] == nil)
            // 旧格式 dictionary（plist Int 混态）→ getter 迁移解析
            UserDefaults.standard.removeObject(forKey: "claudeHookRemoteBindings")
            UserDefaults.standard.set(["legacy-a": 7, "legacy-b": 8], forKey: "claudeHookRemoteBindings")
            let migrated = LANHookPreferences.remoteBindings
            check("lanPrefs: 旧格式 dictionary 迁移解析",
                  migrated["legacy-a"] == Optional(Optional(UInt32(7)))
                  && migrated["legacy-b"] == Optional(Optional(UInt32(8))))
            // 迁移结果写回成新格式 JSON string
            check("lanPrefs: 迁移后写回 JSON string 格式",
                  (UserDefaults.standard.string(forKey: "claudeHookRemoteBindings") ?? "").contains("legacy-a"))
        }

        // ===== ScreenIndexPreferences：单源解码三态（savesLegacyUpgrade:false 免落库） =====
        do {
            let current = ScreenIndexPreferences.default
            let currentData = try! JSONEncoder().encode(current)
            let fromCurrent = ScreenIndexPreferences.decodeWithLegacyFallback(
                currentData, source: "test", savesLegacyUpgrade: false)
            check("overlayPrefs: 当前格式解码保真",
                  fromCurrent?.isEnabled == true && fromCurrent?.position == .topRight
                  && fromCurrent?.usePerScreenSpaceIndexing == true)

            // legacy：无 usePerScreenSpaceIndexing 字段，panelScale/Margin 缺省补齐
            let legacyJSON = """
            {"isEnabled":false,"position":"bottomLeft","fontSize":32,"opacity":0.5,
             "textColor":{"red":1,"green":0,"blue":0,"opacity":1},
             "backgroundColor":{"red":0,"green":0,"blue":0,"opacity":0.6},
             "yabaiPath":null}
            """
            let fromLegacy = ScreenIndexPreferences.decodeWithLegacyFallback(
                Data(legacyJSON.utf8), source: "test", savesLegacyUpgrade: false)
            check("overlayPrefs: legacy 解码迁移（缺省字段补齐+per-screen 强制开）",
                  fromLegacy?.isEnabled == false && fromLegacy?.position == .bottomLeft
                  && fromLegacy?.fontSize == 32 && fromLegacy?.panelScale == 1.0
                  && fromLegacy?.panelMargin == 20
                  && fromLegacy?.usePerScreenSpaceIndexing == true)

            check("overlayPrefs: 垃圾数据 → nil",
                  ScreenIndexPreferences.decodeWithLegacyFallback(
                      Data("garbage".utf8), source: "test", savesLegacyUpgrade: false) == nil)

            // enforce：已开启 per-screen → 原样返回（无迁移副作用）
            let passthrough = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(current)
            check("overlayPrefs: per-screen 已开 → passthrough",
                  passthrough.isEnabled == current.isEnabled && passthrough.position == current.position
                  && passthrough.fontSize == current.fontSize && passthrough.opacity == current.opacity
                  && passthrough.panelScale == current.panelScale
                  && passthrough.panelMargin == current.panelMargin
                  && passthrough.usePerScreenSpaceIndexing == current.usePerScreenSpaceIndexing)
        }

        // ===== CodableColor：SwiftUI 颜色编解码往返 =====
        do {
            let wrapped = CodableColor(Color(red: 0.25, green: 0.5, blue: 0.75, opacity: 0.9))
            let back = wrapped.swiftUIColor
            let rewrapped = CodableColor(back)
            check("overlayPrefs: CodableColor 颜色往返保真（浮点容差）",
                  abs(rewrapped.red - 0.25) < 0.001 && abs(rewrapped.green - 0.5) < 0.001
                  && abs(rewrapped.blue - 0.75) < 0.001 && abs(rewrapped.opacity - 0.9) < 0.001)
        }
    }
}
