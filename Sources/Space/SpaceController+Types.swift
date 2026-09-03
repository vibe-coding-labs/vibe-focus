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

/// Persistent Space management preferences.
struct SpacePreferences {
    static let integrationEnabledKey = "spaceIntegrationEnabled"

    static let defaultIntegrationEnabled = true

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

/// yabai 各版本布尔字段类型漂移防御：同一字段既有 Bool 也有 Int(0/1) 两种形态
/// （Overlay 层 SpaceSnapshot.parse 已记录同源知识）。严格 Decodable 遇到
/// `is-visible: 1` 会整体解码失败 → querySpaces 返回 nil → toggle/restore 核心
/// 路径全瘫而 overlay 编号照常工作。统一经此函数解码布尔字段。
private func decodeFlexibleBool<K: CodingKey>(_ key: K, from c: KeyedDecodingContainer<K>) -> Bool? {
    guard c.contains(key) else { return nil }
    if let b = try? c.decode(Bool.self, forKey: key) { return b }
    if let i = try? c.decode(Int.self, forKey: key) { return i != 0 }
    return nil
}

/// yabai space 查询结果
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

    init(id: Int?, index: Int?, display: Int?, isVisible: Bool?) {
        self.id = id
        self.index = index
        self.display = display
        self.isVisible = isVisible
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        index = try? c.decodeIfPresent(Int.self, forKey: .index)
        display = try? c.decodeIfPresent(Int.self, forKey: .display)
        isVisible = decodeFlexibleBool(.isVisible, from: c)
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
    let isMinimizedRaw: Bool?
    /// 窗口是否持有键盘焦点（yabai `has-focus`）。守卫降级路径消费：一次
    /// `query --windows` 同时读出 focused space（判漂移）与候选窗口（聚焦带动），
    /// 省去独立的 spaces 查询 fork。字段缺失（旧版 yabai）按无焦点处理。
    let hasFocusRaw: Bool?

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, space, display, frame
        case isFloatingRaw = "is-floating"
        case hasAXReferenceRaw = "has-ax-reference"
        // yabai v7.1.18 实测字段名为 `is-minimized`（与 is-floating/is-visible 同族）；
        // 旧版 yabai 为 `minimized`，两者都收做版本漂移防御。
        case isMinimizedRaw = "is-minimized"
        case isMinimizedLegacyRaw = "minimized"
        case hasFocusRaw = "has-focus"
    }

    init(id: Int?, pid: Int?, app: String?, title: String?, space: Int?, display: Int?, frame: Frame?, isFloatingRaw: Bool?, hasAXReferenceRaw: Bool?, isMinimizedRaw: Bool? = nil, hasFocusRaw: Bool? = nil) {
        self.id = id
        self.pid = pid
        self.app = app
        self.title = title
        self.space = space
        self.display = display
        self.frame = frame
        self.isFloatingRaw = isFloatingRaw
        self.hasAXReferenceRaw = hasAXReferenceRaw
        self.isMinimizedRaw = isMinimizedRaw
        self.hasFocusRaw = hasFocusRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        space = try? c.decodeIfPresent(Int.self, forKey: .space)
        display = try? c.decodeIfPresent(Int.self, forKey: .display)
        frame = try? c.decodeIfPresent(Frame.self, forKey: .frame)
        isFloatingRaw = decodeFlexibleBool(.isFloatingRaw, from: c)
        hasAXReferenceRaw = decodeFlexibleBool(.hasAXReferenceRaw, from: c)
        isMinimizedRaw = decodeFlexibleBool(.isMinimizedRaw, from: c) ?? decodeFlexibleBool(.isMinimizedLegacyRaw, from: c)
        hasFocusRaw = decodeFlexibleBool(.hasFocusRaw, from: c)
    }

    var isFloating: Bool { isFloatingRaw == true }

    /// 窗口是否持有键盘焦点（守卫降级路径：focused space 判据）。缺失按 false。
    var hasFocus: Bool { hasFocusRaw == true }

    /// 窗口是否处于最小化。restore/refocus 路径消费：聚焦最小化窗口会把它从 Dock
    /// 拉出（扰动用户布局）或直接失败；字段缺失（旧版 yabai）按未最小化处理。
    var isMinimized: Bool { isMinimizedRaw == true }

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
