import AppKit
import CoreGraphics
import Foundation

// MARK: - 终端网格 · 捕获当前摆法（2026-09-07 从 TerminalGridController 拆分，行为不变）

extension TerminalGridController {

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
        let orderedEntries = Self.sortedByReadingOrder(terminalEntries)

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

    /// 捕获条目按阅读序（行优先）排序：40px 行带内按 midX，跨行带按 midY；
    /// 无 bounds 的条目按 windowID 兜底（纯函数，Runner 穷尽锁定）。
    static func sortedByReadingOrder(_ entries: [CGWindowEntry]) -> [CGWindowEntry] {
        entries.sorted { lhs, rhs in
            guard let lb = lhs.bounds, let rb = rhs.bounds else { return lhs.windowID < rhs.windowID }
            if abs(lb.midY - rb.midY) > 40 { return lb.midY < rb.midY }
            return lb.midX < rb.midX
        }
    }
}
