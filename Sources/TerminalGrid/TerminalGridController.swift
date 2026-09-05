import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格编排器
/// 创建 n×m 终端网格 / 捕获当前摆法（含 Claude session）/ 恢复布局并自动 --resume。
/// AppleScript 经 osascript 子进程在后台队列执行（Apple Events 权限首次使用会弹
/// 系统授权框，-1743 时返回引导文案）。
@MainActor
final class TerminalGridController {

    static let shared = TerminalGridController()

    struct OperationResult {
        let ok: Bool
        let message: String
    }

    private let store: TerminalGridStore

    init(store: TerminalGridStore = .shared) {
        self.store = store
    }

    /// 建窗竞态缓冲：连续 `do script` 时 front window 语义需要窗口真正弹出
    private static let interWindowDelayNanos: UInt64 = 200_000_000

    // MARK: 创建网格

    func createGrid() async -> OperationResult {
        let op = makeOperationID(prefix: "grid-create")
        let rows = TerminalGridPreferences.rows
        let cols = TerminalGridPreferences.cols

        guard let (screen, screenNote) = resolveTargetScreen() else {
            return OperationResult(ok: false, message: "无法确定目标显示器")
        }
        guard let appBundleID = resolveAppBundleID() else {
            return OperationResult(ok: false, message: "终端应用不可用（Terminal/iTerm2）")
        }

        // 显式选了非当前工作区 → 先把视角切过去（切换失败不阻断，落在该屏当前工作区）
        let spaceNote = await focusTargetSpaceIfNeeded(screen: screen, op: op)

        // 规划可用区：visibleFrame 扣「已学习保留区」。副屏菜单栏等隐形钳制
        // 真机实证（P40UG）：visibleFrame 谎报整屏 3440×1440，但窗口写不进顶部
        // 25px——按原始 visibleFrame 规划的网格顶行必留一条空带（用户反馈的
        // "空隙"来源之一）。
        let baseVisible = CoordinateKit.quartzVisibleFrame(of: screen)
        let gridDisplayID = CoordinateKit.cgDisplayID(for: screen) ?? 0
        let learnedInsets = DisplayWorkArea.learnedInsets(displayID: gridDisplayID)
        var planningFrame = DisplayWorkArea.plannedFrame(visibleFrame: baseVisible, insets: learnedInsets)
        var frames = TerminalGridPlanner.cells(
            visibleFrame: planningFrame,
            spec: .init(rows: rows, cols: cols, gap: TerminalGridPreferences.gap)
        )
        guard frames.count == rows * cols else {
            return OperationResult(ok: false, message: "网格规划失败（屏幕可视区异常）")
        }

        log("[TerminalGrid] createGrid started", fields: [
            "op": op, "rows": String(rows), "cols": String(cols), "app": appBundleID
        ])

        let launchCommand = TerminalGridPreferences.launchCommand
        var cells: [TerminalGridCellSnapshot] = []
        var createdWindowIDs: [UInt32] = []
        var correctedCells = 0

        for (index, frame) in frames.enumerated() {
            let placement = await createTerminalCell(
                appBundleID: appBundleID,
                command: launchCommand.isEmpty ? nil : launchCommand,
                frame: frame,
                op: op
            )
            guard let windowID = placement.cgWindowID else {
                let detail = lastScriptError ?? "osascript 执行失败或超时"
                log("[TerminalGrid] createGrid cell failed", level: .error, fields: [
                    "op": op, "index": String(index), "detail": detail
                ])
                return OperationResult(
                    ok: false,
                    message: "第 \(index + 1) 个终端窗口创建失败：\(detail)（若为自动化权限问题，请在 系统设置 → 隐私与安全性 → 自动化 中允许 VibeFocus 控制终端）"
                )
            }
            if placement.corrected { correctedCells += 1 }
            createdWindowIDs.append(windowID)
            cells.append(TerminalGridCellSnapshot(
                index: index,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                ttyPath: nil,
                sessionID: nil,
                cwd: nil,
                title: nil
            ))
        }
        if correctedCells > 0 {
            log("[TerminalGrid] createGrid yabai corrections applied", fields: [
                "op": op, "cells": String(correctedCells)
            ])
        }

        // 保留区学习：回读实际落点，与规划 frame 反推四边钳制（副屏菜单栏等）。
        // 学到非零 → 叠加进缓存并按新可用区整体重排。
        func readbackFrames() -> [CGRect?] {
            let entries = cgWindowListAll()
            return createdWindowIDs.map { id in entries.first(where: { $0.windowID == id })?.bounds }
        }
        var insets = learnedInsets
        let observed = DisplayWorkArea.inferInsets(planned: frames, actual: readbackFrames(), planningFrame: planningFrame)
        if !observed.isZero {
            insets = insets.merged(with: observed)
            DisplayWorkArea.store(insets, displayID: gridDisplayID)
            let fields: [String: String] = [
                "op": op,
                "displayID": "\(gridDisplayID)",
                "top": "\(insets.top)",
                "left": "\(insets.left)",
                "bottom": "\(insets.bottom)",
                "right": "\(insets.right)"
            ]
            log("[TerminalGrid] createGrid work-area learned", fields: fields)
        } else if !learnedInsets.isZero {
            // 缓存非零但本轮格子都到达了规划边缘 → 探测写验证能否缩回
            // （菜单栏改自动隐藏等设置变化后自愈）。
            if let probeFrame = TerminalGridPlanner.cells(
                visibleFrame: baseVisible,
                spec: .init(rows: 1, cols: 1, gap: 0)
            ).first, let probeID = createdWindowIDs.first {
                _ = WindowManager.shared.placeWindow(windowID: probeID, frame: probeFrame, operationID: op)
                if let actual = readbackFrames().first ?? nil {
                    let probed = DisplayWorkArea.probedInsets(probeTarget: probeFrame, actual: actual, learned: learnedInsets)
                    if probed != learnedInsets {
                        insets = probed
                        DisplayWorkArea.store(insets, displayID: gridDisplayID)
                        log("[TerminalGrid] createGrid work-area probe shrunk", fields: [
                            "op": op,
                            "top": "\(insets.top)",
                            "left": "\(insets.left)"
                        ])
                    }
                }
            }
        }
        if insets != learnedInsets {
            planningFrame = DisplayWorkArea.plannedFrame(visibleFrame: baseVisible, insets: insets)
            frames = TerminalGridPlanner.cells(
                visibleFrame: planningFrame,
                spec: .init(rows: rows, cols: cols, gap: TerminalGridPreferences.gap)
            )
            for (index, windowID) in createdWindowIDs.enumerated() where index < frames.count {
                _ = WindowManager.shared.placeWindow(windowID: windowID, frame: frames[index], operationID: op)
            }
        }

        // 收敛复核：逐格摆放各允许 ≤10px 残余漂移，相邻格累积成肉眼可见的缝
        // （用户反馈"格子间空隙很大"）。单次 CGWindowList 快照全量回读，
        // 偏离 >4px 的格子再用 placeWindow 直写纠一次。
        let recheckEntries = cgWindowListAll()
        var reCorrected = 0
        for (frame, windowID) in zip(frames, createdWindowIDs) {
            guard let actual = recheckEntries.first(where: { $0.windowID == windowID })?.bounds,
                  !CoordinateKit.isFrameConverged(actual: actual, target: frame, tolerance: 4) else {
                continue
            }
            if WindowManager.shared.placeWindow(windowID: windowID, frame: frame, operationID: op) {
                reCorrected += 1
            }
        }
        if reCorrected > 0 {
            log("[TerminalGrid] createGrid convergence recheck", fields: [
                "op": op, "reCorrected": String(reCorrected)
            ])
        }

        // 快照记录最终 frame（保留区学习可能已整体重排）
        for index in cells.indices where index < frames.count {
            cells[index].x = frames[index].origin.x
            cells[index].y = frames[index].origin.y
            cells[index].width = frames[index].width
            cells[index].height = frames[index].height
        }

        // Terminal.app：回填 tty（AppleScript window id == CGWindowNumber）
        if appBundleID == "com.apple.Terminal" {
            let ttyMap = await terminalWindowTTYMap()
            for index in cells.indices where index < createdWindowIDs.count {
                cells[index].ttyPath = ttyMap[createdWindowIDs[index]]
            }
        }

        let name = "\(rows)×\(cols) 网格 " + Self.dateFormatter.string(from: Date())
        let snapshot = TerminalGridSnapshot(
            name: name,
            appBundleID: appBundleID,
            displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0,
            displayYabaiIndex: CoordinateKit.yabaiDisplayIndex(for: screen),
            rows: rows,
            cols: cols,
            cells: cells,
            launchCommand: launchCommand.isEmpty ? nil : launchCommand
        )
        store.upsert(snapshot)
        log("[TerminalGrid] createGrid done", fields: [
            "op": op, "windows": String(createdWindowIDs.count), "snapshot": snapshot.id
        ])
        let whereLabel = "「\(screen.localizedName)」" + (activeSpaceIndex(for: screen).map { " · Space \($0)" } ?? "")
        let notes = [screenNote, spaceNote].compactMap { $0 }
        let noteSuffix = notes.isEmpty ? "" : "；" + notes.joined(separator: "；")
        return OperationResult(ok: true, message: "已创建 \(rows)×\(cols) 网格（\(whereLabel)）并保存快照「\(name)」\(noteSuffix)")
    }

    // MARK: 捕获当前摆法

    func captureLayout(name: String? = nil) async -> OperationResult {
        let op = makeOperationID(prefix: "grid-capture")

        guard let (screen, _) = resolveTargetScreen(),
              let displayID = CoordinateKit.cgDisplayID(for: screen) else {
            return OperationResult(ok: false, message: "无法确定目标显示器")
        }

        // 目标屏上全部终端窗口（layer 0 + onscreen + 尺寸合理）
        let terminalEntries = cgWindowListAll().filter { entry in
            guard entry.layer == 0, entry.isOnScreen,
                  let bounds = entry.bounds,
                  bounds.width >= 100, bounds.height >= 100 else {
                return false
            }
            guard let bundleID = bundleIdentifier(ofPID: entry.ownerPID),
                  TerminalRegistry.isTerminalBundleID(bundleID) else {
                return false
            }
            return displayContextDisplayID(for: bounds) == displayID
        }

        guard !terminalEntries.isEmpty else {
            return OperationResult(ok: false, message: "目标屏上没有发现终端窗口")
        }
        // 桌面污染护栏：异常数量的终端窗（批量恢复风暴）拒绝捕获，
        // 防止生成数百格快照后被反复恢复成窗口风暴（真机事故实证）
        guard TerminalGridPlanner.isValidSnapshotCellCount(terminalEntries.count) else {
            let message = "检测到 \(terminalEntries.count) 个终端窗口，超过单次捕获上限 \(TerminalGridPlanner.maxSnapshotCells)——桌面疑似被批量窗口污染，已拒绝捕获"
            log("[TerminalGrid] capture refused: cell overflow", level: .error, fields: [
                "op": op, "windows": String(terminalEntries.count)
            ])
            return OperationResult(ok: false, message: message)
        }

        let frames = terminalEntries.compactMap { $0.bounds }
        let grid = TerminalGridPlanner.inferGrid(from: frames) ?? (rows: 1, cols: terminalEntries.count)
        // row-major 遍历「窗口条目」而非 frames——两个窗口叠在同一格位时 bounds
        // 几乎相等，按 bounds 精确相等反查会串窗（真机 E2E 实证：tty 重复、
        // claude 窗口被挤丢），排序比较器与 rowMajorOrder 同语义。
        let orderedEntries = terminalEntries.sorted { lhs, rhs in
            guard let lb = lhs.bounds, let rb = rhs.bounds else { return lhs.windowID < rhs.windowID }
            if abs(lb.midY - rb.midY) > 40 { return lb.midY < rb.midY }
            return lb.midX < rb.midX
        }

        // Terminal.app 窗口 → tty 映射
        let terminalPIDs = Set(terminalEntries.map { $0.ownerPID })
        let isAppleTerminal = terminalPIDs.contains { bundleIdentifier(ofPID: $0) == "com.apple.Terminal" }
        let ttyMap = isAppleTerminal ? await terminalWindowTTYMap() : [:]

        var cells: [TerminalGridCellSnapshot] = []
        var sessionCount = 0
        for (index, entry) in orderedEntries.enumerated() {
            guard let frame = entry.bounds else { continue }
            let windowID = entry.windowID
            let ttyPath = ttyMap[windowID]

            // session 主路径：Hook 链路早已持久化的绑定（session_id/cwd/tty）
            var sessionID: String?
            var cwd: String?
            if let state = WindowStateStore.shared.findWindowState(windowID: windowID) {
                sessionID = state.sessionID
                cwd = state.cwd
            }
            // 兜底：TTY → claude 进程 → cwd → 最新 jsonl
            if sessionID == nil, let ttyPath {
                if let located = ClaudeSessionLocator.locateSessionID(ttyPath: ttyPath) {
                    sessionID = located.sessionID
                    cwd = located.cwd ?? cwd
                }
            }
            // 纯 shell 格子没有 session 也要记住目录（恢复时 cd 回去）
            if cwd == nil, let ttyPath {
                cwd = ClaudeSessionLocator.shellWorkingDirectory(onTTY: ttyPath)
            }
            if sessionID != nil {
                sessionCount += 1
            }

            cells.append(TerminalGridCellSnapshot(
                index: index,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                ttyPath: ttyPath,
                sessionID: sessionID,
                cwd: cwd,
                title: entry.name
            ))
        }

        let dominantBundleID = terminalEntries.compactMap { bundleIdentifier(ofPID: $0.ownerPID) }.first ?? "com.apple.Terminal"
        let snapshotName = name ?? "捕获布局 " + Self.dateFormatter.string(from: Date())
        let snapshot = TerminalGridSnapshot(
            name: snapshotName,
            appBundleID: dominantBundleID,
            displayID: displayID,
            displayYabaiIndex: CoordinateKit.yabaiDisplayIndex(for: screen),
            rows: grid.rows,
            cols: grid.cols,
            cells: cells,
            launchCommand: TerminalGridPreferences.launchCommand.isEmpty ? nil : TerminalGridPreferences.launchCommand
        )
        store.upsert(snapshot)
        log("[TerminalGrid] captureLayout done", fields: [
            "op": op,
            "windows": String(cells.count),
            "sessions": String(sessionCount),
            "grid": "\(grid.rows)x\(grid.cols)"
        ])
        return OperationResult(
            ok: true,
            message: "已捕获 \(cells.count) 个终端窗口（\(grid.rows)×\(grid.cols)），其中 \(sessionCount) 个关联到 Claude session"
        )
    }

    // MARK: 恢复布局

    func restoreLayout(snapshotID: String? = nil) async -> OperationResult {
        let op = makeOperationID(prefix: "grid-restore")

        let snapshot: TerminalGridSnapshot?
        if let snapshotID {
            snapshot = store.snapshots().first { $0.id == snapshotID }
        } else {
            snapshot = store.latest()
        }
        guard let snapshot else {
            return OperationResult(ok: false, message: "没有可恢复的布局快照（先创建网格或捕获布局）")
        }

        guard TerminalGridPlanner.isValidSnapshotCellCount(snapshot.cells.count) else {
            let message = "快照包含 \(snapshot.cells.count) 个格子（上限 \(TerminalGridPlanner.maxSnapshotCells)），疑似异常快照，已拒绝恢复以防窗口风暴"
            log("[TerminalGrid] restore refused: cell overflow", level: .error, fields: [
                "op": op, "snapshot": snapshot.id, "cells": String(snapshot.cells.count)
            ])
            return OperationResult(ok: false, message: message)
        }
        guard let screen = resolveRestoreScreen(for: snapshot) else {
            return OperationResult(ok: false, message: "目标显示器不可用")
        }

        // 目标屏仍在 → 按记录 frame 恢复（clamp 进可用区）；失效 → 按 rows×cols 重排
        let recordedStillFits = CoordinateKit.cgDisplayID(for: screen) == snapshot.displayID
        let visibleFrame = gridPlanningFrame(for: screen)
        let targetFrames: [CGRect]
        if recordedStillFits {
            targetFrames = snapshot.cells.map { TerminalGridPlanner.clampToVisible(frame: $0.frame, visibleFrame: visibleFrame) }
        } else {
            targetFrames = TerminalGridPlanner.cells(
                visibleFrame: visibleFrame,
                spec: .init(rows: snapshot.rows, cols: snapshot.cols, gap: TerminalGridPreferences.gap)
            )
        }

        log("[TerminalGrid] restoreLayout started", fields: [
            "op": op,
            "snapshot": snapshot.id,
            "cells": String(snapshot.cells.count),
            "reuseFrames": String(recordedStillFits)
        ])

        var restored = 0
        var failures: [String] = []
        for (index, cell) in snapshot.cells.enumerated() {
            guard index < targetFrames.count else { break }
            let command = TerminalAutomationScript.cellCommand(
                sessionID: cell.sessionID,
                cwd: cell.cwd,
                launchCommand: snapshot.launchCommand
            )
            let placement = await createTerminalCell(
                appBundleID: snapshot.appBundleID,
                command: command,
                frame: targetFrames[index],
                op: op
            )
            if placement.cgWindowID != nil {
                restored += 1
            } else {
                failures.append("#\(index + 1)" + (cell.sessionID != nil ? "（session \(cell.sessionID!)）" : ""))
            }
        }

        let summary: String
        if failures.isEmpty {
            summary = "已恢复 \(restored)/\(snapshot.cells.count) 个终端窗口" + (snapshot.hasSessionCells ? "（含 claude --resume）" : "")
        } else {
            summary = "恢复 \(restored)/\(snapshot.cells.count) 个，失败：\(failures.joined(separator: "、"))"
        }
        log("[TerminalGrid] restoreLayout done", fields: ["op": op, "restored": String(restored)])
        return OperationResult(ok: restored > 0, message: summary)
    }

    // MARK: 自动恢复（重启 / 登录后）

    private var hasRunAutoRestoreThisLaunch = false

    /// 启动钩子入口（AppDelegate 延迟调用）。每次启动至多执行一次；
    /// 未勾选 / 无快照时静默返回。
    func runAutoRestoreIfEnabled() {
        guard TerminalGridPreferences.autoRestoreEnabled else {
            log("[TerminalGrid] auto-restore skipped: disabled", level: .debug)
            return
        }
        guard !hasRunAutoRestoreThisLaunch else {
            log("[TerminalGrid] auto-restore skipped: already ran this launch", level: .debug)
            return
        }
        hasRunAutoRestoreThisLaunch = true

        let preferredID = TerminalGridPreferences.autoRestoreSnapshotID
        let snapshot = preferredID.flatMap { id in store.snapshots().first { $0.id == id } } ?? store.latest()
        guard let snapshot else {
            log("[TerminalGrid] auto-restore skipped: no snapshot", level: .debug)
            return
        }
        log("[TerminalGrid] auto-restore starting", fields: ["snapshot": snapshot.id, "cells": String(snapshot.cells.count)])
        Task { [weak self] in
            guard let self else { return }
            let result = await self.autoRestore(snapshot: snapshot)
            log("[TerminalGrid] auto-restore done", fields: ["ok": String(result.ok), "message": result.message])
        }
    }

    /// 自动恢复：与手动恢复的差异在"活窗口联动"——
    /// - 格位上已有活窗口且 claude 会话还在跑 → 跳过（绝不能重复拉起/往 REPL 注入）；
    /// - 有活窗口但只是空闲 shell → 向它注入 cd + resume（不重建，防窗口翻倍）；
    /// - 格位空了（关过窗/重启后）→ 新建窗口执行命令。
    func autoRestore(snapshot: TerminalGridSnapshot) async -> OperationResult {
        let op = makeOperationID(prefix: "grid-autorestore")
        guard TerminalGridPlanner.isValidSnapshotCellCount(snapshot.cells.count) else {
            log("[TerminalGrid] autoRestore refused: cell overflow", level: .error, fields: [
                "op": op, "snapshot": snapshot.id, "cells": String(snapshot.cells.count)
            ])
            return OperationResult(ok: false, message: "快照格子数超过上限，已拒绝自动恢复")
        }
        guard let screen = resolveRestoreScreen(for: snapshot) else {
            return OperationResult(ok: false, message: "自动恢复失败：目标显示器不可用")
        }
        let recordedStillFits = CoordinateKit.cgDisplayID(for: screen) == snapshot.displayID
        let visibleFrame = gridPlanningFrame(for: screen)
        let targetFrames: [CGRect]
        if recordedStillFits {
            targetFrames = snapshot.cells.map { TerminalGridPlanner.clampToVisible(frame: $0.frame, visibleFrame: visibleFrame) }
        } else {
            targetFrames = TerminalGridPlanner.cells(
                visibleFrame: visibleFrame,
                spec: .init(rows: snapshot.rows, cols: snapshot.cols, gap: TerminalGridPreferences.gap)
            )
        }

        let injectEnabled = snapshot.appBundleID == "com.apple.Terminal"
        let liveWindows = await observeLiveWindows(appBundleID: snapshot.appBundleID)
        let actions = TerminalAutoRestorePlanner.plan(
            cells: snapshot.cells,
            targetFrames: targetFrames,
            liveWindows: liveWindows,
            injectEnabled: injectEnabled
        )

        log("[TerminalGrid] auto-restore plan", fields: [
            "op": op,
            "live": String(liveWindows.count),
            "create": String(actions.filter { $0 == .create }.count),
            "inject": String(actions.filter { if case .inject = $0 { return true }; return false }.count),
            "skip": String(actions.filter { $0 == .skipRunning }.count)
        ])

        var created = 0
        var injected = 0
        var skipped = 0
        var failures = 0
        for (index, action) in actions.enumerated() where index < snapshot.cells.count {
            let cell = snapshot.cells[index]
            let command = TerminalAutomationScript.cellCommand(
                sessionID: cell.sessionID,
                cwd: cell.cwd,
                launchCommand: snapshot.launchCommand
            )
            switch action {
            case .skipRunning:
                skipped += 1
            case .inject(let windowID):
                // 无可注入内容（纯 shell 且无 cwd/启动命令）→ 无事可做，不算失败
                guard let command else {
                    skipped += 1
                    continue
                }
                if let script = injectScript(appBundleID: snapshot.appBundleID, windowID: windowID, command: command),
                   await runScript(script)?.exitCode == 0 {
                    injected += 1
                } else {
                    failures += 1
                }
            case .create:
                let placement = await createTerminalCell(
                    appBundleID: snapshot.appBundleID,
                    command: command,
                    frame: targetFrames[index],
                    op: op
                )
                if placement.cgWindowID != nil { created += 1 } else { failures += 1 }
            }
        }

        let summary = "自动恢复：新建 \(created)、注入 \(injected)、跳过运行中 \(skipped)" + (failures > 0 ? "、失败 \(failures)" : "")
        return OperationResult(ok: failures == 0 || created + injected + skipped > 0, message: summary)
    }

    /// 观测当前该终端 app 的全部可见窗口：CG 枚举 + tty 映射 + claude 存活标记
    private func observeLiveWindows(appBundleID: String) async -> [TerminalLiveWindow] {
        let isIterm = appBundleID == "com.googlecode.iterm2"
        let entries = cgWindowListAll().filter { entry in
            guard entry.layer == 0, entry.isOnScreen,
                  let bounds = entry.bounds,
                  bounds.width >= 100, bounds.height >= 100 else {
                return false
            }
            return bundleIdentifier(ofPID: entry.ownerPID) == appBundleID
        }
        var ttyByWindow: [UInt32: String] = [:]
        if !isIterm {
            ttyByWindow = await terminalWindowTTYMap()
        }
        var claudeByTTY: [String: Bool] = [:]
        var result: [TerminalLiveWindow] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard let bounds = entry.bounds else { continue }
            let tty = ttyByWindow[entry.windowID]
            let hasClaude: Bool
            if let tty {
                if let cached = claudeByTTY[tty] {
                    hasClaude = cached
                } else {
                    hasClaude = ClaudeSessionLocator.claudePID(onTTY: tty) != nil
                    claudeByTTY[tty] = hasClaude
                }
            } else {
                hasClaude = false
            }
            result.append(TerminalLiveWindow(
                windowID: entry.windowID,
                frame: bounds,
                ttyPath: tty,
                hasLiveClaude: hasClaude
            ))
        }
        return result
    }

    private func injectScript(appBundleID: String, windowID: UInt32, command: String) -> String? {
        switch appBundleID {
        case "com.googlecode.iterm2":
            return TerminalAutomationScript.itermInjectCommand(windowID: String(windowID), command: command)
        case "com.apple.Terminal":
            return TerminalAutomationScript.terminalInjectCommand(windowID: windowID, command: command)
        default:
            return nil
        }
    }

    // MARK: 辅助

    /// 设置页快照列表刷新入口
    func snapshotsForRefresh() -> [TerminalGridSnapshot] {
        store.snapshots()
    }

    func removeSnapshot(id: String) {
        store.remove(id: id)
    }

    private var lastScriptError: String?

    private func runScript(_ script: String) async -> YabaiClient.YabaiResult? {
        let result = await Task.detached(priority: .userInitiated) {
            // 30s：建窗脚本含等窗轮询 + 多窗环境下 AppleScript 枚举，远超 ShellRunner
            // 默认 2s（为 yabai 短命令设计）；超时会掐死半执行脚本泄漏孤儿窗（真机实证）。
            ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
        }.value
        if let result, result.exitCode != 0, !result.stderr.isEmpty {
            lastScriptError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result == nil {
            lastScriptError = "无法启动 osascript"
        }
        return result
    }

    /// 目标屏：GridTargetCode 解析（main/focused/显式屏/显式屏+工作区）。
    /// 显式屏已断开或焦点屏不可得时回落主屏，note 随结果消息告知用户。
    private func resolveTargetScreen() -> (screen: NSScreen, note: String?)? {
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
    private func activeSpaceIndex(for screen: NSScreen) -> Int? {
        guard let displayIndex = CoordinateKit.yabaiDisplayIndex(for: screen) else { return nil }
        return SpaceController.shared.visibleSpaceIndex(forDisplayIndex: displayIndex, spaces: nil, ignoreCache: true)?.yabaiIndex
    }

    /// 网格规划可用区：visibleFrame 扣该屏已学习保留区（重排/恢复共用同一事实源）
    private func gridPlanningFrame(for screen: NSScreen) -> CGRect {
        let base = CoordinateKit.quartzVisibleFrame(of: screen)
        let insets = DisplayWorkArea.learnedInsets(displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0)
        return DisplayWorkArea.plannedFrame(visibleFrame: base, insets: insets)
    }

    /// 显式目标带工作区且非该屏当前可见 → 切视角（yabai 直切 → 聚焦带动双层），
    /// 切换后轮询等 visible space 到位（~2s）。任何一层失败都不阻断编排：
    /// 返回说明 note，格子落在该屏当前工作区（结果可用性优先于目标保真）。
    private func focusTargetSpaceIfNeeded(screen: NSScreen, op: String) async -> String? {
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

    private func primaryScreen() -> NSScreen? {
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

    private func resolveRestoreScreen(for snapshot: TerminalGridSnapshot) -> NSScreen? {
        if let screen = CoordinateKit.nsScreen(forCGDisplayID: snapshot.displayID) {
            return screen
        }
        return primaryScreen()
    }

    /// 最近一次编排目标选择（设置页预览/日志用）
    private(set) var lastTerminalSelection: TerminalSelection?

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

    private func resolveAppBundleID() -> String? {
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
    private func displayContextDisplayID(for frame: CGRect) -> UInt32? {
        let cocoaFrame = CGRect(
            x: frame.origin.x,
            y: CoordinateKit.mainScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return NSScreen.screens.first { $0.frame.contains(cocoaFrame) || $0.frame.intersects(cocoaFrame) }
            .flatMap { CoordinateKit.cgDisplayID(for: $0) }
    }

    private func bundleIdentifier(ofPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// 建一个终端窗口并确保落到目标格子：
    /// 1) AppleScript 建窗 + set bounds（Terminal 的 bounds 是"窗口当前屏局部坐标"
    ///    语义，真机实证跨屏必漂移）；
    /// 2) 读回 bounds 校验，漂移 >10px 走 WindowManager.placeWindow（float 脱管 +
    ///    yabai frame 直写）纠偏——与主流程跨屏写同一引擎。
    private func createTerminalCell(
        appBundleID: String,
        command: String?,
        frame: CGRect,
        op: String
    ) async -> (cgWindowID: UInt32?, corrected: Bool) {
        let isIterm = appBundleID == "com.googlecode.iterm2"
        let script = isIterm
            ? TerminalAutomationScript.itermCreateWindow(command: command, quartzFrame: frame)
            : TerminalAutomationScript.terminalCreateWindow(command: command, quartzFrame: frame)
        guard let result = await runScript(script), result.exitCode == 0 else {
            return (nil, false)
        }
        let appleScriptID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(nanoseconds: Self.interWindowDelayNanos)

        let boundsScript = isIterm
            ? TerminalAutomationScript.itermGetBounds(windowID: appleScriptID)
            : TerminalAutomationScript.terminalGetBounds(windowID: UInt32(appleScriptID) ?? 0)
        let readback = (await runScript(boundsScript))
            .flatMap { TerminalAutomationScript.parseBounds($0.stdout) }

        // CG window id：Terminal 的 AppleScript id == CGWindowNumber；iTerm2 按落点 bounds 就近匹配
        var cgID: UInt32?
        if !isIterm, let id = UInt32(appleScriptID) {
            cgID = id
        } else {
            cgID = cgWindowID(forBundleID: appBundleID, nearBounds: readback)
        }

        let converged = readback.map { CoordinateKit.isFrameConverged(actual: $0, target: frame, tolerance: 10) } ?? false
        if converged {
            return (cgID, false)
        }
        guard let cgID else {
            return (nil, false)
        }
        log("[TerminalGrid] cell placement drifted, correcting via yabai", fields: [
            "op": op,
            "windowID": String(cgID),
            "readback": readback.map { "\($0.origin.x),\($0.origin.y),\($0.width)x\($0.height)" } ?? "nil"
        ])
        let corrected = WindowManager.shared.placeWindow(windowID: cgID, frame: frame, operationID: op)
        return (cgID, corrected)
    }

    /// 按 bundleID + 就近 bounds 找 CG window id（iTerm2 的 AppleScript id 不是 CGWindowNumber）
    private func cgWindowID(forBundleID bundleID: String, nearBounds bounds: CGRect?) -> UInt32? {
        let entries = cgWindowListAll().filter { entry in
            entry.layer == 0 && entry.isOnScreen && entry.bounds != nil
                && bundleIdentifier(ofPID: entry.ownerPID) == bundleID
        }
        guard let bounds else {
            return entries.first?.windowID
        }
        var best: (id: UInt32, distance: CGFloat)?
        for entry in entries {
            let b = entry.bounds!
            let d = hypot(b.midX - bounds.midX, b.midY - bounds.midY)
            if best == nil || d < best!.distance {
                best = (entry.windowID, d)
            }
        }
        guard let best, best.distance < 40 else { return nil }
        return best.id
    }

    /// Terminal.app 全量 windowID→tty 映射
    private func terminalWindowTTYMap() async -> [UInt32: String] {
        guard let result = await runScript(TerminalAutomationScript.terminalEnumerateWindowTTYs()),
              result.exitCode == 0 else {
            return [:]
        }
        var mapping: [UInt32: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let windowID = UInt32(parts[0]) else { continue }
            var tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !tty.hasPrefix("/dev/") {
                tty = "/dev/" + tty
            }
            mapping[windowID] = tty
        }
        return mapping
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private extension TerminalGridSnapshot {
    var hasSessionCells: Bool {
        cells.contains { $0.sessionID != nil }
    }
}
