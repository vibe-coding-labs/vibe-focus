import Foundation
import SwiftUI

// MARK: - Screen Index Position
/// Available screen positions for the overlay index display.
enum IndexPosition: String, CaseIterable, Codable {
    case topLeft = "topLeft"
    case topCenter = "topCenter"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"

    var displayName: String {
        switch self {
        case .topLeft: return "左上角"
        case .topCenter: return "正上方"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomCenter: return "正下方"
        case .bottomRight: return "右下角"
        }
    }

    var icon: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topCenter: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomCenter: return "arrow.down"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

// MARK: - Screen Index Preferences
/// Persistent preferences for the screen index overlay appearance and behavior.
struct ScreenIndexPreferences: Codable {
    var isEnabled: Bool
    var position: IndexPosition
    var fontSize: CGFloat
    var opacity: CGFloat
    var textColor: CodableColor
    var backgroundColor: CodableColor
    var panelScale: CGFloat
    var panelMargin: CGFloat
    var yabaiPath: String?
    var usePerScreenSpaceIndexing: Bool

    static let `default` = ScreenIndexPreferences(
        isEnabled: true,
        position: .topRight,
        fontSize: 48,
        opacity: 0.8,
        textColor: CodableColor(.white),
        backgroundColor: CodableColor(.black.opacity(0.6)),
        panelScale: 1.0,
        panelMargin: 20,
        yabaiPath: nil,
        usePerScreenSpaceIndexing: true
    )

    static let userDefaultsKey = "screenIndexPreferences"

    // MARK: 进程级持久化沙箱（2026-09-20 生产配置污染根治）
    /// 真实装机 app 判定：只有 Bundle.main 带 canonical bundle id 的进程才允许读写
    /// 生产三源（SQLite 主源 ~/.vibefocus/vibefocus.db + CFPreferences plist +
    /// UserDefaults）。其余一切进程（VibeFocusTestRunner、裸 .build 调试二进制）
    /// 读写一律落按 pid 隔离的 /tmp 沙箱文件。
    ///
    /// ## 背景（2026-09-20「屏幕序号无法渲染」事故根因）
    /// Runner 的偏好/渲染/退出链路测试会触发 `ScreenIndexPreferences.save()`（didSet →
    /// schedulePreferenceSave、legacy 迁移回写、flushPendingPreferenceSave），把测试
    /// 偏好（topLeft/48/0.8，含测试崩溃残留的 enabled=false 中间态）写进生产库；
    /// app 重启后加载测试垃圾 → 用户角标配置（右下角/32/30%）被静默改写甚至整体
    /// 熄灭。CFPreferences 写入此前经 `?? AppIdentity.bundleID` 兜底同样污染共享 plist。
    static var isProductionAppProcess: Bool {
        Bundle.main.bundleIdentifier == AppIdentity.bundleID
    }

    /// 沙箱偏好文件：按 pid 隔离——并行 Runner 进程互不污染，同进程内
    /// save→load 往返保真（依赖持久化的既有测试无需改动）。
    static var sandboxPreferencesURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibefocus-screen-index-prefs-sandbox-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    @MainActor
    static func load() -> ScreenIndexPreferences {
        // P-INST-205: 屏幕索引偏好加载端到端耗时（loadFromSQLite P-INST-101 + CFPreferencesCopyAppValue + UserDefaults.standard.string/data + JSONDecoder.decode + legacy migration save；启动 + overlay 刷新调用，多源 fallback 链）。
        #if PERF_INSTRUMENT
        let lpStart = Date()
        defer {
            log("[ScreenIndexPreferences] load finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: lpStart))])
        }
        #endif
        // 沙箱进程：只读沙箱文件，缺失回落 .default，生产三源零触碰（读取也不允许——
        // 否则测试断言会依赖装机实机的残留配置，跨机器不确定）。
        guard isProductionAppProcess else {
            if let data = FileManager.default.contents(atPath: sandboxPreferencesURL.path),
               let prefs = try? JSONDecoder().decode(ScreenIndexPreferences.self, from: data) {
                return enforcePerScreenSpaceIndexingIfNeeded(prefs)
            }
            return .default
        }
        // 1. SQLite 主源（~/.vibefocus/vibefocus.db — 不受 app rebuild 影响）
        if let sqlitePrefs = loadFromSQLite() {
            log("ScreenIndexPreferences loaded from SQLite: isEnabled=\(sqlitePrefs.isEnabled)")
            return enforcePerScreenSpaceIndexingIfNeeded(sqlitePrefs)
        }

        // 2. CFPreferences（次源）
        let bundleId = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        if let value = CFPreferencesCopyAppValue(userDefaultsKey as CFString, bundleId as CFString),
           let jsonString = value as? String,
           let prefs = decodeWithLegacyFallback(Data(jsonString.utf8), source: "CFPreferences") {
            log("ScreenIndexPreferences loaded: isEnabled=\(prefs.isEnabled)")
            return prefs
        }
        // 3. UserDefaults（兜底）— save() 写入 String，优先用 .string() 读取
        if let jsonString = UserDefaults.standard.string(forKey: userDefaultsKey),
           let prefs = decodeWithLegacyFallback(Data(jsonString.utf8), source: "UserDefaults") {
            log("ScreenIndexPreferences loaded from UserDefaults: isEnabled=\(prefs.isEnabled)")
            return prefs
        }
        // Fallback: 如果以 Data 形式存储（理论上不会，但做兼容）
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            do {
                let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
                let migrated = enforcePerScreenSpaceIndexingIfNeeded(prefs)
                log("ScreenIndexPreferences loaded from UserDefaults (data fallback): isEnabled=\(prefs.isEnabled)")
                return migrated
            } catch {
                log("ScreenIndexPreferences decode error from UserDefaults data fallback: \(error)")
            }
        }
        return .default
    }

    /// 单一源内解码：当前格式优先（enforce 守卫），legacy 旧格式迁移兜底（命中即回写升级格式）。
    /// `source` 仅用于诊断日志区分来源；`savesLegacyUpgrade` 测试注入 false 避免落库副作用。
    /// CFPreferences 与 UserDefaults 两个 String 源共用——消解历史上逐字重复的
    /// decode→enforce→legacy→save 双份块（B30 提纯，行为与原两块一致）。
    @MainActor
    static func decodeWithLegacyFallback(
        _ data: Data,
        source: String,
        savesLegacyUpgrade: Bool = true
    ) -> ScreenIndexPreferences? {
        do {
            return enforcePerScreenSpaceIndexingIfNeeded(
                try JSONDecoder().decode(ScreenIndexPreferences.self, from: data))
        } catch {
            log("ScreenIndexPreferences decode error from \(source): \(error)")
        }
        guard let legacy = loadLegacyPreferences(from: data) else { return nil }
        log("ScreenIndexPreferences: Loaded legacy preferences with migration from \(source)")
        if savesLegacyUpgrade { legacy.save() }
        return legacy
    }

    @MainActor
    private static func loadFromSQLite() -> ScreenIndexPreferences? {
        // P-INST-101: 屏幕索引偏好 SQLite 读取耗时（loadPreference SQLite 读 P-INST-69 + JSONDecoder 解码；load() public 包装调用；SQLite 读是主要成本，decode 纯计算）。
        #if PERF_INSTRUMENT
        let lfsStart = Date()
        defer {
            log("[ScreenIndexPreferences] loadFromSQLite finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: lfsStart))
            ])
        }
        #endif
        guard let json = WindowStateStore.shared.loadPreference(key: userDefaultsKey),
              let data = json.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
        } catch {
            log("ScreenIndexPreferences decode error from SQLite: \(error)")
            return nil
        }
    }

    static func loadLegacyPreferences(from data: Data) -> ScreenIndexPreferences? {
        // P-INST-225: legacy 屏幕索引偏好迁移解码耗时（JSONDecoder.decode LegacyPreferences + 字段映射；load() P-INST-205 旧格式 fallback 路径，migration 通常单次；slow-op ≥5ms warn）。
        #if PERF_INSTRUMENT
        let llpStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: llpStart)
            if durMs >= 5 { log("[ScreenIndexPreferences] loadLegacyPreferences slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        struct LegacyPreferences: Codable {
            var isEnabled: Bool
            var position: IndexPosition
            var fontSize: CGFloat
            var opacity: CGFloat
            var textColor: CodableColor
            var backgroundColor: CodableColor
            var panelScale: CGFloat?
            var panelMargin: CGFloat?
            var yabaiPath: String?
        }

        do {
            let legacy = try JSONDecoder().decode(LegacyPreferences.self, from: data)
            return ScreenIndexPreferences(
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
            log("ScreenIndexPreferences: Failed to load legacy preferences: \(error)")
            return nil
        }
    }

    @MainActor
    static func enforcePerScreenSpaceIndexingIfNeeded(_ preferences: ScreenIndexPreferences) -> ScreenIndexPreferences {
        guard !preferences.usePerScreenSpaceIndexing else {
            return preferences
        }

        var migrated = preferences
        migrated.usePerScreenSpaceIndexing = true
        log("ScreenIndexPreferences: Migrating global workspace index mode to per-screen mode")
        migrated.save()
        return migrated
    }

    @MainActor
    func save() {
        // P-INST-100: 屏幕索引偏好持久化耗时（JSONEncoder 编码 + savePreference SQLite 写 P-INST-69 + CFPreferencesSetAppValue plist daemon 写 + CFPreferencesAppSynchronize flush；三源写入；偏好变更时调用，CFPreferences 同步写可阻塞）。
        #if PERF_INSTRUMENT
        let sp2Start = Date()
        defer {
            log("[ScreenIndexPreferences] save finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: sp2Start))
            ])
        }
        #endif
        // 沙箱进程：原子写 /tmp 沙箱文件即返回，生产三源（SQLite/plist/defaults）零触碰。
        guard Self.isProductionAppProcess else {
            if let data = try? JSONEncoder().encode(self) {
                try? data.write(to: Self.sandboxPreferencesURL, options: .atomic)
            }
            return
        }
        guard let data = try? JSONEncoder().encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            log("ScreenIndexPreferences: Failed to encode")
            return
        }
        // SQLite 主源（不受 app rebuild 影响）
        WindowStateStore.shared.savePreference(key: Self.userDefaultsKey, value: jsonString)
        // CFPreferences + UserDefaults 次源
        let bundleId = Bundle.main.bundleIdentifier ?? AppIdentity.bundleID
        CFPreferencesSetAppValue(Self.userDefaultsKey as CFString, jsonString as CFString, bundleId as CFString)
        CFPreferencesAppSynchronize(bundleId as CFString)
        UserDefaults.standard.set(jsonString, forKey: Self.userDefaultsKey)
    }
}

// MARK: - Codable Color
/// Codable wrapper for NSColor serialization.
struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ color: Color) {
        #if os(macOS)
        let nsColor = NSColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.opacity = Double(a)
        #else
        self.red = 1
        self.green = 1
        self.blue = 1
        self.opacity = 1
        #endif
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}
