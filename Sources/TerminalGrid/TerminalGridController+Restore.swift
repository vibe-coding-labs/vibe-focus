import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格 · 恢复布局 + 自动恢复（2026-09-07 从 TerminalGridController 拆分，行为不变）

extension TerminalGridController {

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

        let targetFrames = restoreTargetFrames(for: snapshot, screen: screen)

        log("[TerminalGrid] restoreLayout started", fields: [
            "op": op,
            "snapshot": snapshot.id,
            "cells": String(snapshot.cells.count),
            "reuseFrames": String(CoordinateKit.cgDisplayID(for: screen) == snapshot.displayID)
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
        let targetFrames = restoreTargetFrames(for: snapshot, screen: screen)

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

    func resolveRestoreScreen(for snapshot: TerminalGridSnapshot) -> NSScreen? {
        if let screen = CoordinateKit.nsScreen(forCGDisplayID: snapshot.displayID) {
            return screen
        }
        return primaryScreen()
    }

    /// 恢复目标帧规划（restoreLayout 与 autoRestore 共用唯一事实源）：
    /// 目标屏仍是记录屏 → 按记录 frame clamp 进可用区；失效 → 按 rows×cols 重排。
    /// （纯决策，输入全部真值采集；Runner 穷尽锁定）
    static func restoreTargetFrames(
        snapshot: TerminalGridSnapshot,
        recordedDisplayStillFits: Bool,
        visibleFrame: CGRect
    ) -> [CGRect] {
        if recordedDisplayStillFits {
            return snapshot.cells.map { TerminalGridPlanner.clampToVisible(frame: $0.frame, visibleFrame: visibleFrame) }
        }
        return TerminalGridPlanner.cells(
            visibleFrame: visibleFrame,
            spec: .init(rows: snapshot.rows, cols: snapshot.cols, gap: TerminalGridPreferences.gap)
        )
    }

    func restoreTargetFrames(for snapshot: TerminalGridSnapshot, screen: NSScreen) -> [CGRect] {
        Self.restoreTargetFrames(
            snapshot: snapshot,
            recordedDisplayStillFits: CoordinateKit.cgDisplayID(for: screen) == snapshot.displayID,
            visibleFrame: gridPlanningFrame(for: screen)
        )
    }
}

extension TerminalGridSnapshot {
    var hasSessionCells: Bool {
        cells.contains { $0.sessionID != nil }
    }
}
