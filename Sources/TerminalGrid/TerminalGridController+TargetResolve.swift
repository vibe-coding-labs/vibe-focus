import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格 · 目标屏解析与终端选择（2026-09-07 从 TerminalGridController 拆分，行为不变）

extension TerminalGridController {

    /// 目标屏：GridTargetCode 解析（main/focused/显式屏/显式屏+工作区）。
    /// 显式屏已断开或焦点屏不可得时回落主屏，note 随结果消息告知用户。
    func resolveTargetScreen() -> (screen: NSScreen, note: String?)? {
        let target = GridTargetCode.parse(TerminalGridPreferences.target) ?? .main
        switch target {
        case .main:
            guard let screen = primaryScreen() else { return nil }
            return (screen, nil)
        case .focused:
            if let screen = focusedWindowScreen() {
                return (screen, nil)
            }
            guard let screen = primaryScreen() else { return nil }
            return (screen, "焦点屏不可得，已回落主屏")
        case .display(let displayID), .displaySpace(let displayID, _):
            if let screen = CoordinateKit.nsScreen(forCGDisplayID: displayID) {
                return (screen, nil)
            }
            guard let screen = primaryScreen() else { return nil }
            return (screen, "目标显示器已断开，已回落主屏")
        }
    }

    /// 该屏当前可见工作区（yabai 全局索引；yabai 不可用时 nil）
    func activeSpaceIndex(for screen: NSScreen) -> Int? {
        guard let displayIndex = CoordinateKit.yabaiDisplayIndex(for: screen) else { return nil }
        return SpaceController.shared.visibleSpaceIndex(forDisplayIndex: displayIndex, spaces: nil, ignoreCache: true)?.yabaiIndex
    }

    /// 网格规划可用区：visibleFrame 扣该屏已学习保留区（重排/恢复共用同一事实源）
    func gridPlanningFrame(for screen: NSScreen) -> CGRect {
        let base = CoordinateKit.quartzVisibleFrame(of: screen)
        let insets = DisplayWorkArea.learnedInsets(displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0)
        return DisplayWorkArea.plannedFrame(visibleFrame: base, insets: insets)
    }

    /// 显式目标带工作区且非该屏当前可见 → 切视角（yabai 直切 → 聚焦带动双层），
    /// 切换后轮询等 visible space 到位（~2s）。任何一层失败都不阻断编排：
    /// 返回说明 note，格子落在该屏当前工作区（结果可用性优先于目标保真）。
    func focusTargetSpaceIfNeeded(screen: NSScreen, op: String) async -> String? {
        guard case .displaySpace(_, let spaceIndex) = GridTargetCode.parse(TerminalGridPreferences.target) ?? .main else {
            return nil
        }
        guard let displayIndex = CoordinateKit.yabaiDisplayIndex(for: screen) else {
            return "yabai 不可用，无法定位工作区，已在该屏当前工作区创建"
        }
        let spaces = SpaceController.shared.querySpaces() ?? []
        let displaySpaces = spaces.filter { $0.display == displayIndex }
        guard displaySpaces.contains(where: { $0.index == spaceIndex }) else {
            return "Space \(spaceIndex) 不在「\(screen.localizedName)」上，已在该屏当前工作区创建"
        }
        if activeSpaceIndex(for: screen) == spaceIndex {
            return nil
        }
        if !SpaceController.shared.focusSpace(.yabai(spaceIndex), operationID: op) {
            // 直切依赖 scripting addition（SA 失效时必败）；退聚焦带动通道
            _ = SpaceController.shared.refocusWindowOnSpace(spaceIndex, excludingWindowID: nil, operationID: op, prefetchedWindows: nil)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if activeSpaceIndex(for: screen) == spaceIndex {
                return nil
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return "未能切换到 Space \(spaceIndex)（视角切换通道不可用），已在该屏当前工作区创建"
    }

    func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { CoordinateKit.cgDisplayID(for: $0) == CGMainDisplayID() }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func focusedWindowScreen() -> NSScreen? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let windows = cgWindowListAll().filter { entry in
            entry.ownerPID == frontApp.processIdentifier && entry.layer == 0 && entry.isOnScreen && entry.bounds != nil
        }
        guard let frame = windows.first?.bounds else { return nil }
        return displayContextDisplayID(for: frame).flatMap { CoordinateKit.nsScreen(forCGDisplayID: $0) }
    }

    /// 采集候选观测并解析编排目标（设置页预览与 createGrid 共用同一逻辑）
    func selectionPreview() -> TerminalSelection {
        let runningIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        let usageRank = TerminalUsageTracker.shared.table.ranked()
        let usageCounts = Dictionary(uniqueKeysWithValues: usageRank.map { ($0.bundleID, $0.count) })
        let lastUsed = Dictionary(usageRank.map { ($0.bundleID, $0.lastAt) },
                                  uniquingKeysWith: { first, _ in first })

        let candidates = TerminalSelectionResolver.supportTable.keys.sorted().map { bundleID in
            TerminalSelectionCandidate(
                bundleID: bundleID,
                name: TerminalSelectionResolver.knownNames[bundleID] ?? bundleID,
                support: TerminalSelectionResolver.supportLevel(forBundleID: bundleID),
                usageCount: usageCounts[bundleID] ?? 0,
                lastUsedAt: lastUsed[bundleID],
                isRunning: runningIDs.contains(bundleID)
            )
        }
        let manualBundleID: String? = {
            switch TerminalGridPreferences.appPreference {
            case .auto: return nil
            case .terminal: return "com.apple.Terminal"
            case .iterm2: return "com.googlecode.iterm2"
            }
        }()
        return TerminalSelectionResolver.resolve(manualBundleID: manualBundleID, candidates: candidates)
    }

    func resolveAppBundleID() -> String? {
        let selection = selectionPreview()
        lastTerminalSelection = selection
        log("[TerminalGrid] terminal selected", fields: [
            "bundleID": selection.bundleID,
            "source": String(describing: selection.source),
            "reason": selection.reason
        ])
        return selection.bundleID
    }

    /// CGWindowList bounds（Quartz）→ 所属 displayID（复用 WindowManager 判定语义）
    func displayContextDisplayID(for frame: CGRect) -> UInt32? {
        let cocoaFrame = CGRect(
            x: frame.origin.x,
            y: CoordinateKit.mainScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return NSScreen.screens.first { $0.frame.contains(cocoaFrame) || $0.frame.intersects(cocoaFrame) }
            .flatMap { CoordinateKit.cgDisplayID(for: $0) }
    }

    func bundleIdentifier(ofPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
