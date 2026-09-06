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

    // 跨扩展文件的共享状态（extension 不能声明存储属性，统一收拢在类体）
    let store: TerminalGridStore
    var lastScriptError: String?
    var lastTerminalSelection: TerminalSelection?
    var hasRunAutoRestoreThisLaunch = false

    init(store: TerminalGridStore = .shared) {
        self.store = store
    }

    /// 建窗竞态缓冲：连续 `do script` 时 front window 语义需要窗口真正弹出
    static let interWindowDelayNanos: UInt64 = 200_000_000

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

        // Space 投递：AppleScript 建窗可能落进终端 app 自己的活跃 space 而非当前
        // 可见 space（真机实证 2026-09-06：视角在 Space 5，iTerm2 把 6 窗全部建进
        // 不可见的 Space 4）。逐窗校验，错的走「泊到另一屏 → 写回目标格位」跨屏
        // 往返投递（yabai --space/--sticky 在本机 v7 无 SA 环境静默失效，不可用）。
        let delivery = await deliverCellsToTargetSpace(
            windowIDs: createdWindowIDs,
            frames: frames,
            screen: screen,
            op: op
        )

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
        let targetSpaceIndex: Int? = {
            if case .displaySpace(_, let idx) = GridTargetCode.parse(TerminalGridPreferences.target) ?? .main {
                return idx
            }
            return nil
        }()
        // 位置标签诚实化：显式选了工作区时回显用户选择（配合投递结果注记），
        // 只有非显式目标才回显实际可见 space——旧实现回显「实际可见」会把
        // "视角切到了 5 但窗口全落 4" 的失败伪装成成功。
        let whereLabel: String
        if let targetSpaceIndex {
            whereLabel = "「\(screen.localizedName)」 · Space \(targetSpaceIndex)"
        } else {
            whereLabel = "「\(screen.localizedName)」" + (activeSpaceIndex(for: screen).map { " · Space \($0)" } ?? "")
        }
        var notes = [screenNote, spaceNote].compactMap { $0 }
        if let targetSpaceIndex {
            let undelivered = createdWindowIDs.count - delivery.delivered
            if delivery.parkingUnavailable {
                notes.append("本机只有一块显示器，无法投递到 Space \(targetSpaceIndex)，窗口落在该屏当前工作区")
            } else if undelivered > 0 {
                notes.append("有 \(undelivered) 窗未能送达 Space \(targetSpaceIndex)（终端将其建在了其它工作区），可手动移动或重新创建")
            }
        }
        let noteSuffix = notes.isEmpty ? "" : "；" + notes.joined(separator: "；")
        return OperationResult(ok: true, message: "已创建 \(rows)×\(cols) 网格（\(whereLabel)）并保存快照「\(name)」\(noteSuffix)")
    }

    // MARK: 辅助

    /// 设置页快照列表刷新入口
    func snapshotsForRefresh() -> [TerminalGridSnapshot] {
        store.snapshots()
    }

    func removeSnapshot(id: String) {
        store.remove(id: id)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
