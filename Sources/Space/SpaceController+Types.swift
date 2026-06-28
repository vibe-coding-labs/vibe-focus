// SpaceController+Types.swift
// VibeFocus — Space 模块类型定义
// 从 SpaceController.swift 中提取

import Foundation

// MARK: - Space Types

/// Represents whether Space management features are available.
enum SpaceAvailability: String {
    case unknown
    case notInstalled
    case unavailable
    case available
}

/// Strategy for restoring a window to its original Space after toggle.
enum SpaceRestoreStrategy: String, CaseIterable {
    case switchToOriginal
    case pullToCurrent
}

/// Persistent Space management preferences.
struct SpacePreferences {
    static let integrationEnabledKey = "spaceIntegrationEnabled"
    static let restoreStrategyKey = "spaceRestoreStrategy"

    static let defaultIntegrationEnabled = true
    static let defaultRestoreStrategy = SpaceRestoreStrategy.switchToOriginal

    static var integrationEnabled: Bool {
        get {
            // P-INST-153: space integration enabled UserDefaults 读耗时（CFPreferences 同步读；SpaceController.refreshAvailability:69 调用，决定 isEnabled 即 space 移动是否启用，toggle/restore 路径间接调用）。
            let iegStart = Date()
            let value = UserDefaults.standard.object(forKey: integrationEnabledKey) as? Bool ?? defaultIntegrationEnabled
            log("[SpacePreferences] integrationEnabled get finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: iegStart)),
                "value": String(value)
            ])
            return value
        }
        set {
            // P-INST-153: space integration enabled UserDefaults 写耗时（CFPreferences 同步写；设置 UI toggle）。
            let iesStart = Date()
            UserDefaults.standard.set(newValue, forKey: integrationEnabledKey)
            log("[SpacePreferences] integrationEnabled set finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: iesStart))
            ])
        }
    }

    static var restoreStrategy: SpaceRestoreStrategy {
        get {
            // P-INST-154: restore strategy UserDefaults 读耗时（CFPreferences 同步读 string；restore 路径读取决定 switchToOriginal/pullToCurrent，每次 restore 调用）。
            let rsgStart = Date()
            let raw = UserDefaults.standard.string(forKey: restoreStrategyKey) ?? SpaceRestoreStrategy.switchToOriginal.rawValue
            let value = SpaceRestoreStrategy(rawValue: raw) ?? .switchToOriginal
            log("[SpacePreferences] restoreStrategy get finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rsgStart)),
                "strategy": value.rawValue
            ])
            return value
        }
        set {
            // P-INST-154: restore strategy UserDefaults 写耗时（CFPreferences 同步写 rawValue；设置 UI 切换）。
            let rssStart = Date()
            UserDefaults.standard.set(newValue.rawValue, forKey: restoreStrategyKey)
            log("[SpacePreferences] restoreStrategy set finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: rssStart))
            ])
        }
    }
}

/// Snapshot of the current Space and display configuration for a window.
struct SpaceContext {
    let sourceSpaceIndex: SpaceIdentifier?
    let targetSpaceIndex: SpaceIdentifier?
    let sourceDisplayIndex: DisplayIdentifier?
    let sourceDisplaySpaceIndex: Int?
}

// MARK: - Yabai Data Types

typealias ShellResult = YabaiClient.YabaiResult

/// yabai space 查询结果
/// - `id`: macOS native space ID (CGS)，用于 NativeSpaceBridge.moveWindow
/// - `index`: yabai 全局 space 索引 (1-based)，用于 yabai space 命令
/// - `display`: yabai display 索引 (1-based, 1=主屏)
struct YabaiSpaceInfo: Decodable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case display
        case isVisible = "is-visible"
    }
}

/// yabai window 查询结果
/// - `space`: 窗口所在的 yabai 全局 space 索引 (1-based)
/// - `display`: 窗口所在的 yabai display 索引 (1-based)
struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
    let frame: Frame?
    let isFloatingRaw: Bool?
    let hasAXReferenceRaw: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, space, display, frame
        case isFloatingRaw = "is-floating"
        case hasAXReferenceRaw = "has-ax-reference"
    }

    var isFloating: Bool { isFloatingRaw == true }

    /// yabai 是否能通过 AXUIElement 管理此窗口。
    /// has-ax-reference=false 时所有 yabai 命令（move/float/focus）都会失败，
    /// 必须跳过 yabai 改用 AX/NativeSpaceBridge 等替代方案。
    var isManageableByYabai: Bool { hasAXReferenceRaw == true }

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }
}

/// Display information parsed from yabai query output.
struct YabaiDisplayInfo: Decodable {
    let index: Int?
    let frame: Frame?

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
}
