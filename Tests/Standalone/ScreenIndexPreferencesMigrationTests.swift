// Tests/Standalone/ScreenIndexPreferencesMigrationTests.swift
// Verification: 屏幕索引偏好的纯决策函数（legacy 迁移解码 / per-screen 迁移守卫）
// Mirrors: Sources/Overlay/ScreenIndexPreferences.swift
//         (loadLegacyPreferences(from:) / enforcePerScreenSpaceIndexingIfNeeded(_:) / CodableColor)
// Run: swift Tests/Standalone/ScreenIndexPreferencesMigrationTests.swift
//
// 背景（playbook 2.16a 第二十二刀）：四级回退加载链的两个纯决策函数按 2.13 裁决
// 口径属无覆盖（唯一测试在从未编译的 Tests/XCTest）。本刀只补测、不改加载行为
// ——偏好迁移涉及真实环境数据，四级回退的改动仍被 2.15 教训门禁挡住。
// 锁定语义：
// - legacy 解码：panelScale/panelMargin 可缺省（nil → 1.0/20），usePerScreenSpaceIndexing
//   恒置 true（迁移语义），未知键忽略，解码失败 → nil；
// - enforce：已开启 → 原样返回且不落盘；未开启 → 置 true + 落盘一次 + 其余字段不变。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors IndexPosition
enum MirrorIndexPosition: String, Codable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
}

/// Mirrors CodableColor（Codable 字段序即属性名；Equatable 仅为测试断言所需，
/// 生产 CodableColor 未声明 Equatable）
struct MirrorCodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double
}

/// Mirrors ScreenIndexPreferences（Codable 键与生产一致）
struct MirrorScreenIndexPreferences: Codable, Equatable {
    var isEnabled: Bool
    var position: MirrorIndexPosition
    var fontSize: Double
    var opacity: Double
    var textColor: MirrorCodableColor
    var backgroundColor: MirrorCodableColor
    var panelScale: Double
    var panelMargin: Double
    var yabaiPath: String?
    var usePerScreenSpaceIndexing: Bool
}

/// Mirrors loadLegacyPreferences 内嵌的 LegacyPreferences
private struct MirrorLegacyPreferences: Codable {
    var isEnabled: Bool
    var position: MirrorIndexPosition
    var fontSize: Double
    var opacity: Double
    var textColor: MirrorCodableColor
    var backgroundColor: MirrorCodableColor
    var panelScale: Double?
    var panelMargin: Double?
    var yabaiPath: String?
}

/// Mirrors loadLegacyPreferences(from:)
func mirrorLoadLegacyPreferences(from data: Data) -> MirrorScreenIndexPreferences? {
    do {
        let legacy = try JSONDecoder().decode(MirrorLegacyPreferences.self, from: data)
        return MirrorScreenIndexPreferences(
            isEnabled: legacy.isEnabled,
            position: legacy.position,
            fontSize: legacy.fontSize,
            opacity: legacy.opacity,
            textColor: legacy.textColor,
            backgroundColor: legacy.backgroundColor,
            panelScale: legacy.panelScale ?? 1.0,
            panelMargin: legacy.panelMargin ?? 20,
            yabaiPath: legacy.yabaiPath,
            usePerScreenSpaceIndexing: true
        )
    } catch {
        return nil
    }
}

/// Mirrors enforcePerScreenSpaceIndexingIfNeeded（save 副作用以闭包注入建模）
func mirrorEnforcePerScreenSpaceIndexing(
    _ preferences: MirrorScreenIndexPreferences,
    save: (MirrorScreenIndexPreferences) -> Void
) -> MirrorScreenIndexPreferences {
    guard !preferences.usePerScreenSpaceIndexing else {
        return preferences
    }
    var migrated = preferences
    migrated.usePerScreenSpaceIndexing = true
    save(migrated)
    return migrated
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

let white = #"{"red":1,"green":1,"blue":1,"opacity":1}"#
let blackDim = #"{"red":0,"green":0,"blue":0,"opacity":0.6}"#

// MARK: 1. loadLegacyPreferences — 解码与字段映射

print("1. loadLegacyPreferences 解码")

do {
    let json = """
    {"isEnabled":false,"position":"bottomLeft","fontSize":40,"opacity":0.5,
     "textColor":\(white),"backgroundColor":\(blackDim),
     "panelScale":1.5,"panelMargin":30,"yabaiPath":"/opt/homebrew/bin/yabai"}
    """
    let r = mirrorLoadLegacyPreferences(from: Data(json.utf8))
    check("全字段 legacy JSON → 各值原样映射", r != nil
          && r?.isEnabled == false && r?.position == .bottomLeft
          && r?.fontSize == 40 && r?.opacity == 0.5
          && r?.panelScale == 1.5 && r?.panelMargin == 30
          && r?.yabaiPath == "/opt/homebrew/bin/yabai")
    check("迁移语义：usePerScreenSpaceIndexing 恒置 true（legacy 无此字段）",
          r?.usePerScreenSpaceIndexing == true)
}
do {
    let json = """
    {"isEnabled":true,"position":"topCenter","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim)}
    """
    let r = mirrorLoadLegacyPreferences(from: Data(json.utf8))
    check("panelScale/panelMargin/yabaiPath 缺省 → 补默认 1.0/20/nil",
          r?.panelScale == 1.0 && r?.panelMargin == 20 && r?.yabaiPath == nil)
}
do {
    let json = """
    {"isEnabled":true,"position":"topRight","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim),
     "usePerScreenSpaceIndexing":false}
    """
    let r = mirrorLoadLegacyPreferences(from: Data(json.utf8))
    check("legacy JSON 若混入新字段也被忽略（未知键不参与解码），结果仍恒 true",
          r?.usePerScreenSpaceIndexing == true)
}
check("非 JSON 垃圾字节 → nil",
      mirrorLoadLegacyPreferences(from: Data("not json at all".utf8)) == nil)
do {
    let json = """
    {"position":"topRight","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim)}
    """
    check("缺必填字段（isEnabled）→ 解码失败 nil",
          mirrorLoadLegacyPreferences(from: Data(json.utf8)) == nil)
}
do {
    let json = """
    {"isEnabled":"yes","position":"topRight","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim)}
    """
    check("字段类型错误（isEnabled 为字符串）→ nil",
          mirrorLoadLegacyPreferences(from: Data(json.utf8)) == nil)
}
do {
    let json = """
    {"isEnabled":true,"position":"middleLeft","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim)}
    """
    check("非法 position 枚举值 → nil", mirrorLoadLegacyPreferences(from: Data(json.utf8)) == nil)
}

// MARK: 2. enforcePerScreenSpaceIndexingIfNeeded — 迁移守卫

print("\n2. enforce 迁移守卫")

do {
    let prefs = MirrorScreenIndexPreferences(
        isEnabled: true, position: .topRight, fontSize: 48, opacity: 0.8,
        textColor: MirrorCodableColor(red: 1, green: 1, blue: 1, opacity: 1),
        backgroundColor: MirrorCodableColor(red: 0, green: 0, blue: 0, opacity: 0.6),
        panelScale: 1.0, panelMargin: 20, yabaiPath: nil,
        usePerScreenSpaceIndexing: true)
    var saveCalls = 0
    let r = mirrorEnforcePerScreenSpaceIndexing(prefs) { _ in saveCalls += 1 }
    check("已开启 per-screen → 原样返回，不落盘", r == prefs && saveCalls == 0)
}
do {
    let prefs = MirrorScreenIndexPreferences(
        isEnabled: false, position: .bottomRight, fontSize: 32, opacity: 0.4,
        textColor: MirrorCodableColor(red: 0.1, green: 0.2, blue: 0.3, opacity: 0.9),
        backgroundColor: MirrorCodableColor(red: 0, green: 0, blue: 0, opacity: 0.5),
        panelScale: 1.25, panelMargin: 15, yabaiPath: "/usr/local/bin/yabai",
        usePerScreenSpaceIndexing: false)
    var saved: [MirrorScreenIndexPreferences] = []
    let r = mirrorEnforcePerScreenSpaceIndexing(prefs) { saved.append($0) }
    check("未开启 → 迁移为 true 且落盘恰一次", r.usePerScreenSpaceIndexing == true && saved.count == 1)
    check("迁移只翻迁移位：其余九个字段逐一不变",
          r.isEnabled == prefs.isEnabled && r.position == prefs.position
          && r.fontSize == prefs.fontSize && r.opacity == prefs.opacity
          && r.textColor == prefs.textColor && r.backgroundColor == prefs.backgroundColor
          && r.panelScale == prefs.panelScale && r.panelMargin == prefs.panelMargin
          && r.yabaiPath == prefs.yabaiPath)
    check("落盘内容即迁移后的值", saved.first == r)
}

// MARK: 3. 组合契约 — legacy 解码产物喂给 enforce 恒为恒等

print("\n3. 组合契约")

do {
    let json = """
    {"isEnabled":true,"position":"topLeft","fontSize":48,"opacity":0.8,
     "textColor":\(white),"backgroundColor":\(blackDim)}
    """
    let legacy = mirrorLoadLegacyPreferences(from: Data(json.utf8))!
    var saveCalls = 0
    let r = mirrorEnforcePerScreenSpaceIndexing(legacy) { _ in saveCalls += 1 }
    check("legacy 解码恒置 true → enforce 恒等（load() 链上不产生二次迁移落盘）",
          r == legacy && saveCalls == 0)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
