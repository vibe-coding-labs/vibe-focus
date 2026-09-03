import AppKit
import Foundation

// MARK: - 窗口管理器共存探测
/// 检测机器上已安装/正在运行的同类摆位窗口管理器（Rectangle/Magnet 等）。
/// 设计原则照 YabaiEnvironmentProbe：判定核心 `evaluate` 零 I/O 可完整单测，
/// 生产入口 `probe` 只做枚举与喂参。
///
/// 处理策略（docs/design-rectangle-integration.md §3）：
/// - 竞品运行中 + 用户未做显式选择 → 摆位热键自动停用（不弹窗）；
/// - 提示展示在设置页与菜单，用户显式选择后不再自动改。
struct WindowLayoutManagerCandidate: Equatable {
    let name: String
    let bundleID: String
    let installed: Bool
    let running: Bool
}

struct WindowLayoutManagerProfile: Equatable {
    let candidates: [WindowLayoutManagerCandidate]

    /// 正在运行的摆位竞品（会抢同一批全局热键/贴边行为）
    var runningConflicts: [WindowLayoutManagerCandidate] {
        candidates.filter { $0.running }
    }

    var hasRunningConflict: Bool { !runningConflicts.isEmpty }

    /// 供 UI 展示的一行摘要，如 "Rectangle（运行中）"
    var conflictSummary: String? {
        guard hasRunningConflict else { return nil }
        return runningConflicts.map { "\($0.name)（运行中）" }.joined(separator: "、")
    }
}

enum WindowLayoutManagerProbe {

    /// 摆位竞品名单（name 用于应用名匹配，bundleID 用于精确匹配；yabai/skhd 不在名单
    /// ——yabai 是 VibeFocus 集成的增强层，不是摆位竞品）。
    static let knownManagers: [(name: String, bundleID: String)] = [
        ("Rectangle", "com.knollsoft.Rectangle"),
        ("Rectangle Pro", "com.knollsoft.RectanglePro"),
        ("Magnet", "com.coredigest.WndManager"),
        ("Moom", "com.manytricks.Moom"),
        ("SizeUp", "com.irradiatedsoftware.SizeUp"),
        ("Spectacle", "com.wondersofspectacle.Spectacle"),
        ("Amethyst", "com.amethyst.Amethyst"),
        ("Hammerspoon", "org.hammerspoon.Hammerspoon"),
        ("BetterSnapTool", "com.hegenberg.BetterSnapTool"),
        ("Swish", "net.mattpallott.Swish"),
        ("Loop", "com.Midwinter.Duncan.Loop")
    ]

    /// 纯判定核心：running/installed 集合由生产入口注入。
    /// name 精确匹配 + bundleID 精确匹配双通道（bundleID 名单可能过期，name 兜底）。
    static func evaluate(
        runningAppNames: Set<String>,
        runningBundleIDs: Set<String>,
        installedAppNames: Set<String>
    ) -> WindowLayoutManagerProfile {
        let candidates = knownManagers.map { known -> WindowLayoutManagerCandidate in
            let running = runningBundleIDs.contains(known.bundleID) || runningAppNames.contains(known.name)
            let installed = running || installedAppNames.contains(known.name)
            return WindowLayoutManagerCandidate(name: known.name, bundleID: known.bundleID, installed: installed, running: running)
        }
        return WindowLayoutManagerProfile(candidates: candidates)
    }

    /// 生产入口：枚举运行中应用 + 应用目录。
    static func probe() -> WindowLayoutManagerProfile {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningNames = Set(runningApps.compactMap { $0.localizedName })
        let runningIDs = Set(runningApps.compactMap { $0.bundleIdentifier })

        var installedNames: Set<String> = []
        let searchDirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in searchDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                installedNames.insert(String(item.dropLast(4)))
            }
        }

        return evaluate(
            runningAppNames: runningNames,
            runningBundleIDs: runningIDs,
            installedAppNames: installedNames
        )
    }

    /// 共存策略落点：竞品运行且用户未显式选择 → 自动停用摆位热键并返回 true（状态变化）。
    /// 幂等：已显式选择（keepDisabled/enableAnyway）后不再自动改。
    @discardableResult
    static func applyCoexistencePolicy(profile: WindowLayoutManagerProfile) -> Bool {
        guard profile.hasRunningConflict else { return false }
        guard LayoutPreferences.coexistenceChoice == .unspecified else { return false }
        guard LayoutPreferences.isEnabled else { return false }
        LayoutPreferences.isEnabled = false
        log(
            "[Layout] Coexistence policy disabled layout hotkeys",
            fields: ["conflicts": profile.conflictSummary ?? "unknown"]
        )
        return true
    }
}
