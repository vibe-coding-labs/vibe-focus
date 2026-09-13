import AppKit
import CoreGraphics
import Foundation

// MARK: - 会话恢复控制器（v2 捕获/恢复/自动恢复唯一入口）
/// 多屏 × 多工作区 × 多窗 × 多 pane 的会话快照与重建。数据骨架是 yabai 全量
/// 窗口查询（跨屏跨 Space 全可见），pane 层由 iTerm2 AppleScript / Terminal
/// tty 枚举补齐，会话层三层联动：Hook 绑定库 → 本机进程定位 → 远程探针。
@MainActor
final class SessionRestoreController {

    static let shared = SessionRestoreController()

    typealias OperationResult = TerminalGridController.OperationResult

    let store: SessionRestoreStore
    var hasRunAutoRestoreThisLaunch = false

    init(store: SessionRestoreStore = .shared) {
        self.store = store
    }

    // MARK: 捕获

    func captureCurrentLayout(name: String? = nil) async -> OperationResult {
        let op = makeOperationID(prefix: "session-capture")

        // 1. yabai 全量窗口（捕获的存在前提：yabai 不可用 = 无法跨屏跨 Space 采集）
        guard let allWindows = SpaceController.shared.queryAllWindows() else {
            return OperationResult(ok: false, message: "yabai 不可用，无法采集跨工作区窗口（会话恢复依赖 yabai）")
        }
        let terminalWindows = allWindows.filter { Self.isCapturableYabaiWindow($0, bundleIDOf: bundleIdentifier(ofPID:)) }
        guard !terminalWindows.isEmpty else {
            return OperationResult(ok: false, message: "没有发现可编排的终端窗口（支持 Terminal.app / iTerm2）")
        }
        guard TerminalGridPlanner.isValidSnapshotCellCount(terminalWindows.count) else {
            return OperationResult(
                ok: false,
                message: "检测到 \(terminalWindows.count) 个终端窗口，超过单次捕获上限 \(TerminalGridPlanner.maxSnapshotCells)——桌面疑似被批量窗口污染，已拒绝捕获"
            )
        }
        // 不支持自动化方言的其它终端（Warp 等）：看到了但要如实交代没捕
        let unsupportedCount = allWindows.filter { entry in
            guard let pid = entry.pid, let bundleID = bundleIdentifier(ofPID: pid_t(pid)) else { return false }
            return TerminalRegistry.isTerminalBundleID(bundleID)
                && !TerminalAutomationScript.automationBundleIDs.contains(bundleID)
        }.count

        // 2. pane 枚举（按在场的终端 app 各跑一次 AppleScript）
        let hasIterm = terminalWindows.contains { $0.app == "iTerm2" }
        let hasAppleTerminal = terminalWindows.contains { $0.app == "Terminal" }
        var itermEntries: [ITermSessionEntry] = []
        if hasIterm {
            itermEntries = await runAppleScript(PaneEnumeration.itermEnumerateSessions())
                .map { PaneEnumeration.parseITermSessions($0) } ?? []
        }
        var terminalTTYs: [UInt32: [String]] = [:]
        if hasAppleTerminal {
            terminalTTYs = await runAppleScript(TerminalAutomationScript.terminalEnumerateWindowTTYs())
                .map { PaneEnumeration.parseTerminalTabTTYs($0) } ?? [:]
        }

        // 3. 窗口骨架：yabai 窗 × pane tty 就近拼接
        let skeletons = Self.joinPanes(
            yabaiWindows: terminalWindows,
            itermEntries: itermEntries,
            terminalTTYs: terminalTTYs
        )

        // 4. 逐 pane 会话定位：Hook 绑定（窗口级）→ 本机/远端进程分类 → 远程探针
        var ttys: [String] = []
        for skeleton in skeletons {
            ttys.append(contentsOf: skeleton.panes.compactMap(\.tty))
        }
        var classifications: [String: PaneClassifier.Classification] = [:]
        for tty in ttys where classifications[tty] == nil {
            classifications[tty] = Self.classifyTTY(tty)
        }
        let hookStates: [UInt32: WindowState] = skeletons.reduce(into: [:]) { dict, skeleton in
            dict[skeleton.cgWindowID] = WindowStateStore.shared.findWindowState(windowID: skeleton.cgWindowID)
        }

        // 5. 远程探针：remoteSSH pane 的目的地去重后小并发打探（免密才行，失败即降级）
        var remoteTargets: [(target: String, port: String?)] = []
        var seenTargets = Set<String>()
        for cls in classifications.values where cls.kind == .remoteSSH {
            guard let target = cls.sshTarget else { continue }
            let port = cls.sshCommand.flatMap { SessionCommandBuilder.parseTarget(from: $0)?.port }
            if seenTargets.insert(target + "@" + (port ?? "")).inserted {
                remoteTargets.append((target, port))
            }
        }
        let probeResults = await Self.probeRemoteTargets(remoteTargets)

        // 6. 组装快照
        var windows: [SessionWindowSnapshot] = []
        var sessionCount = 0
        var remoteLiveCount = 0
        for skeleton in skeletons {
            var panes: [SessionPaneSnapshot] = []
            for paneTTY in skeleton.panes {
                let tty = paneTTY.tty
                let cls = tty.flatMap { classifications[$0] }
                    ?? PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil)
                let hookState = hookStates[skeleton.cgWindowID]
                // 窗口级 Hook 绑定只有一条；多 pane 窗口里对不上 tty 的 pane 不吃这条绑定
                let hookMatchesPane = skeleton.panes.count == 1
                    || hookState?.tty == nil || hookState?.tty == tty
                let pane = await Self.resolvePane(
                    classification: cls,
                    hookSessionID: hookMatchesPane ? hookState?.sessionID : nil,
                    hookCWD: hookMatchesPane ? hookState?.cwd : nil,
                    paneTitle: paneTTY.title,
                    probeResults: probeResults
                )
                if pane.sessionID != nil { sessionCount += 1 }
                if pane.kind == .remoteSSH, pane.wasRemoteSessionLive { remoteLiveCount += 1 }
                panes.append(pane)
            }
            windows.append(SessionWindowSnapshot(
                appBundleID: skeleton.appBundleID,
                frame: skeleton.frame,
                displayID: skeleton.displayID ?? 0,
                yabaiDisplay: skeleton.yabaiWindow.display,
                yabaiSpace: skeleton.yabaiWindow.space,
                title: skeleton.yabaiWindow.title,
                wasMinimized: skeleton.yabaiWindow.isMinimized,
                panes: panes
            ))
        }

        let snapshotName = name ?? "会话快照 " + TerminalGridController.dateFormatter.string(from: Date())
        let snapshot = SessionRestoreSnapshot(
            name: snapshotName,
            windows: windows,
            launchCommand: TerminalGridPreferences.launchCommand.isEmpty ? nil : TerminalGridPreferences.launchCommand
        )
        store.upsert(snapshot)
        log("[SessionRestore] capture done", fields: [
            "op": op,
            "windows": String(windows.count),
            "sessions": String(sessionCount),
            "remoteLive": String(remoteLiveCount),
            "spaces": String(snapshot.spaceCount),
            "displays": String(snapshot.displayCount),
        ])
        var summary = "已捕获 \(windows.count) 窗（\(snapshot.displayCount) 屏 · \(snapshot.spaceCount) 工作区）· \(sessionCount) 个 Claude 会话"
        if remoteLiveCount > 0 { summary += " · \(remoteLiveCount) 个远程会话" }
        if unsupportedCount > 0 { summary += "；另有 \(unsupportedCount) 个不支持自动化的终端窗口未捕获" }
        return OperationResult(ok: true, message: summary)
    }

    // MARK: 恢复入口

    func runAutoRestoreIfEnabled() {
        guard TerminalGridPreferences.autoRestoreEnabled else {
            log("[SessionRestore] auto-restore skipped: disabled", level: .debug)
            return
        }
        guard !hasRunAutoRestoreThisLaunch else { return }
        hasRunAutoRestoreThisLaunch = true
        let preferredID = TerminalGridPreferences.autoRestoreSnapshotID
        let snapshot = preferredID.flatMap { id in store.snapshots().first { $0.id == id } } ?? store.latest()
        guard let snapshot else {
            log("[SessionRestore] auto-restore skipped: no snapshot", level: .debug)
            return
        }
        log("[SessionRestore] auto-restore starting", fields: [
            "snapshot": snapshot.id, "windows": String(snapshot.windows.count)
        ])
        Task { [weak self] in
            guard let self else { return }
            let result = await SessionRestoreExecutor(controller: self).restore(snapshot: snapshot)
            log("[SessionRestore] auto-restore done", fields: ["ok": String(result.ok), "message": result.message])
        }
    }

    func restoreLayout(snapshotID: String? = nil) async -> OperationResult {
        let snapshot: SessionRestoreSnapshot?
        if let snapshotID {
            snapshot = store.snapshots().first { $0.id == snapshotID }
        } else {
            snapshot = store.latest()
        }
        guard let snapshot else {
            return OperationResult(ok: false, message: "没有可恢复的布局快照（先捕获当前布局）")
        }
        return await SessionRestoreExecutor(controller: self).restore(snapshot: snapshot)
    }

    // MARK: 快照列表（UI）

    func snapshotsForRefresh() -> [SessionRestoreSnapshot] {
        store.snapshots()
    }

    func removeSnapshot(id: String) {
        store.remove(id: id)
        TerminalGridStore.shared.remove(id: id)   // 旧格式库存量一并清除
    }

    func latestSnapshotID() -> String? {
        store.snapshots().last?.id
    }

    // MARK: - 采集与分类（MainActor 静态决策层；Runner assumeIsolated 直测）

    static func isCapturableYabaiWindow(
        _ window: YabaiWindowInfo,
        bundleIDOf: (pid_t) -> String?
    ) -> Bool {
        guard let pid = window.pid, let frame = window.frame,
              frame.w >= 100, frame.h >= 100 else { return false }
        guard let bundleID = bundleIDOf(pid_t(pid)) else { return false }
        return TerminalAutomationScript.isAutomationSupported(bundleID)
    }

    /// yabai 窗 × iTerm2 session 行 × Terminal tty 表 → 窗口骨架（含每窗 pane 列表）。
    /// iTerm2 window 用 bounds 就近匹配 yabai frame（两坐标同空间：左上原点全局）；
    /// Terminal.app 的 AppleScript window id == CGWindowNumber，直查表。
    static func joinPanes(
        yabaiWindows: [YabaiWindowInfo],
        itermEntries: [ITermSessionEntry],
        terminalTTYs: [UInt32: [String]]
    ) -> [WindowSkeleton] {
        var usedASIDs = Set<String>()
        var result: [WindowSkeleton] = []
        for window in yabaiWindows {
            guard let frame = window.frame, let pid = window.pid else { continue }
            let bundleID = bundleIDForYabaiWindow(window, pid: pid_t(pid))
            let rect = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
            var panes: [PaneTTY] = []
            var matchedASID: String?
            if TerminalAutomationScript.usesITermDialect(bundleID) {
                let candidates = itermEntries.map { (windowASID: $0.windowASID, bounds: $0.windowBounds) }
                if let asid = PaneEnumeration.matchITermWindow(cgFrame: rect, candidates: candidates, usedASIDs: usedASIDs) {
                    usedASIDs.insert(asid)
                    matchedASID = asid
                    panes = itermEntries
                        .filter { $0.windowASID == asid }
                        .sorted { ($0.tabIndex, $0.sessionIndex) < ($1.tabIndex, $1.sessionIndex) }
                        .map { PaneTTY(tty: $0.tty, title: $0.name.isEmpty ? nil : $0.name, tabIndex: $0.tabIndex, sessionIndex: $0.sessionIndex) }
                }
            } else if let cgID = window.id.flatMap(UInt32.init(exactly:)), let ttys = terminalTTYs[cgID] {
                panes = ttys.map { PaneTTY(tty: $0, title: nil, tabIndex: nil, sessionIndex: nil) }
            }
            if panes.isEmpty {
                // pane 枚举失败：至少留一个空位，窗口级 Hook 绑定仍有机会落地
                panes = [PaneTTY(tty: nil, title: nil, tabIndex: nil, sessionIndex: nil)]
            }
            let displayID = SpaceController.shared.exactNSScreen(forYabaiDisplayIndex: window.display ?? -1)
                .flatMap { CoordinateKit.cgDisplayID(for: $0) }
            result.append(WindowSkeleton(
                cgWindowID: window.id.flatMap(UInt32.init(exactly:)) ?? 0,
                yabaiWindow: window,
                appBundleID: bundleID,
                frame: rect,
                displayID: displayID,
                itermWindowASID: matchedASID,
                panes: panes
            ))
        }
        return result
    }

    /// yabai app 名 → bundle id（NSRunningApplication 兜底；测试注入纯映射）
    nonisolated static func bundleIDForYabaiWindow(_ window: YabaiWindowInfo, pid: pid_t) -> String {
        switch window.app {
        case "iTerm2": return "com.googlecode.iterm2"
        case "Terminal": return "com.apple.Terminal"
        default: break
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? window.app ?? ""
    }

    /// 窗口骨架（joinPanes 产物）
    struct WindowSkeleton {
        let cgWindowID: UInt32
        let yabaiWindow: YabaiWindowInfo
        let appBundleID: String
        let frame: CGRect
        let displayID: UInt32?
        /// iTerm2 的 AppleScript window id（就近匹配命中才有；注入/追加 tab 定位用）
        let itermWindowASID: String?
        var panes: [PaneTTY]
    }

    struct PaneTTY: Equatable {
        var tty: String?
        var title: String?
        /// iTerm2 pane 的 AppleScript 定位序（1 起；Terminal.app 为 nil）
        var tabIndex: Int?
        var sessionIndex: Int?
    }

    /// 单 tty 进程分类（IO：一次 ps fork）
    nonisolated static func classifyTTY(_ tty: String) -> PaneClassifier.Classification {
        let shortTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        guard let result = ShellRunner.run(executable: "/bin/ps", arguments: ["-t", shortTTY, "-o", "pid=,command="], timeout: 2),
              result.exitCode == 0 else {
            return PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil)
        }
        return PaneClassifier.classify(processLines: result.stdout.split(separator: "\n").map(String.init))
    }

    /// pane 会话定位（三层联动）。IO：本机 claude cwd 走 lsof。
    nonisolated static func resolvePane(
        classification: PaneClassifier.Classification,
        hookSessionID: String?,
        hookCWD: String?,
        paneTitle: String?,
        probeResults: [String: [RemoteSessionEntry]]
    ) async -> SessionPaneSnapshot {
        switch classification.kind {
        case .localClaude:
            // Hook 绑定优先；兜底本机进程定位（claude cwd → projects 最新 jsonl）
            if let hookSessionID, !hookSessionID.isEmpty {
                return SessionPaneSnapshot(kind: .localClaude, sessionID: hookSessionID, cwd: hookCWD, title: paneTitle)
            }
            guard let pid = classification.pid else {
                return SessionPaneSnapshot(kind: .shell, cwd: hookCWD, title: paneTitle)
            }
            let cwd = ClaudeSessionLocator.workingDirectory(ofPID: pid)
            guard let cwd else {
                return SessionPaneSnapshot(kind: .shell, title: paneTitle)
            }
            let sessionID = ClaudeSessionLocator.latestSessionID(
                inProjectDir: ClaudeSessionLocator.escapedProjectDir(forCWD: cwd))
            if let sessionID {
                return SessionPaneSnapshot(kind: .localClaude, sessionID: sessionID, cwd: cwd, title: paneTitle)
            }
            return SessionPaneSnapshot(kind: .shell, cwd: cwd, title: paneTitle)
        case .remoteSSH:
            guard let target = classification.sshTarget else {
                // 目的地解析不出：恢复时原样回放整条命令行
                return SessionPaneSnapshot(
                    kind: .remoteSSH, sshCommand: classification.sshCommand, title: paneTitle)
            }
            let port = classification.sshCommand.flatMap { SessionCommandBuilder.parseTarget(from: $0)?.port }
            let entries = probeResults[target + "@" + (port ?? "")] ?? []
            if let hookSessionID, !hookSessionID.isEmpty {
                // Hook 绑定的远程会话（forwarder 事件）——cwd/session 都取绑定
                return SessionPaneSnapshot(
                    kind: .remoteSSH, sessionID: hookSessionID, cwd: hookCWD,
                    sshCommand: classification.sshCommand, sshTarget: target,
                    wasRemoteSessionLive: !entries.isEmpty, title: paneTitle)
            }
            if let hit = RemoteSessionProbe.matchSession(remoteCWD: hookCWD, paneTitle: paneTitle, entries: entries) {
                return SessionPaneSnapshot(
                    kind: .remoteSSH, sessionID: hit.sessionID, cwd: hit.cwd ?? hookCWD,
                    sshCommand: classification.sshCommand, sshTarget: target,
                    wasRemoteSessionLive: true, title: paneTitle)
            }
            return SessionPaneSnapshot(
                kind: .remoteSSH, cwd: hookCWD,
                sshCommand: classification.sshCommand, sshTarget: target,
                wasRemoteSessionLive: !entries.isEmpty, title: paneTitle)
        case .shell:
            var cwd = hookCWD
            if cwd == nil, let pid = classification.pid {
                cwd = ClaudeSessionLocator.workingDirectory(ofPID: pid)
            }
            return SessionPaneSnapshot(kind: .shell, cwd: cwd, title: paneTitle)
        }
    }

    /// 远程探针 fan-out（并发 4 封顶；每目标一次 ssh，失败空表）
    nonisolated static func probeRemoteTargets(
        _ targets: [(target: String, port: String?)]
    ) async -> [String: [RemoteSessionEntry]] {
        guard !targets.isEmpty else { return [:] }
        var result: [String: [RemoteSessionEntry]] = [:]
        for batchStart in stride(from: 0, to: targets.count, by: 4) {
            let batch = Array(targets[batchStart..<min(batchStart + 4, targets.count)])
            await withTaskGroup(of: (String, [RemoteSessionEntry]).self) { group in
                for entry in batch {
                    group.addTask {
                        let entries = RemoteSessionProbe.probe(target: entry.target, port: entry.port)
                        return (entry.target + "@" + (entry.port ?? ""), entries)
                    }
                }
                for await (key, entries) in group {
                    result[key] = entries
                }
            }
        }
        return result
    }

    // MARK: 辅助 IO

    func runAppleScript(_ script: String) async -> String? {
        let result = await Task.detached(priority: .userInitiated) {
            ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
        }.value
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout
    }

    func bundleIdentifier(ofPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
