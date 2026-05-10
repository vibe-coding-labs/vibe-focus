import Foundation
import AppKit

@MainActor
final class TerminalRestoreService {
    static let shared = TerminalRestoreService()

    private init() {}

    /// 检查是否有可恢复的快照，如果有则执行恢复
    func checkAndRestore() {
        let manager = ShutdownSnapshotManager.shared

        guard manager.hasPendingSnapshot else {
            log("[TerminalRestore] no pending snapshot found")
            return
        }

        guard let snapshot = manager.loadSnapshot() else {
            log("[TerminalRestore] failed to load snapshot", level: .warn)
            manager.clearSnapshot()
            return
        }

        guard manager.isSnapshotFromPreviousBoot(snapshot) else {
            log("[TerminalRestore] snapshot is from current boot session, skipping")
            return
        }

        log("[TerminalRestore] found snapshot from previous boot with \(snapshot.terminalWindows.count) terminal windows")

        // 检查是否启用自动恢复
        let autoRestore = UserDefaults.standard.object(forKey: "autoRestoreOnBoot") as? Bool ?? true
        if autoRestore {
            performRestore(snapshot)
        } else {
            log("[TerminalRestore] auto-restore disabled, snapshot preserved for manual restore")
        }
    }

    /// 执行恢复流程
    func performRestore(_ snapshot: ShutdownSnapshot) {
        log("[TerminalRestore] starting restore of \(snapshot.terminalWindows.count) windows")

        var restoredCount = 0
        var skippedCount = 0
        var failedCount = 0

        // 按终端 App 分组
        let byApp = Dictionary(grouping: snapshot.terminalWindows) { $0.bundleIdentifier }

        for (bundleID, windows) in byApp {
            switch bundleID {
            case "com.apple.Terminal":
                let results = restoreTerminalApp(windows: windows)
                restoredCount += results.restored
                skippedCount += results.skipped
                failedCount += results.failed
            default:
                log("[TerminalRestore] unsupported terminal app: \(bundleID), skipping \(windows.count) windows", level: .warn)
                failedCount += windows.count
            }
        }

        log("[TerminalRestore] restore complete: \(restoredCount) restored, \(skippedCount) skipped (already exist), \(failedCount) failed")

        // 恢复完成后清除快照
        ShutdownSnapshotManager.shared.clearSnapshot()
    }

    // MARK: - Terminal.app Restore

    private struct RestoreResult {
        var restored = 0
        var skipped = 0
        var failed = 0
    }

    private func restoreTerminalApp(windows: [TerminalWindowSnapshot]) -> RestoreResult {
        var result = RestoreResult()

        // 检查系统级窗口恢复是否可能已创建了 Terminal 窗口
        let existingWindows = enumerateExistingTerminalWindows()
        log("[TerminalRestore] found \(existingWindows.count) existing Terminal windows before restore")

        for win in windows {
            // 去重：检查是否已有匹配的窗口（Terminal.app 自身恢复的）
            if let _ = findExistingMatch(for: win, in: existingWindows) {
                log("[TerminalRestore] skipping duplicate window for \(win.claudeProjectDir ?? "?") — matched existing window")
                result.skipped += 1
                continue
            }

            // 构建恢复命令
            let command = buildRestoreCommand(for: win)

            if command.isEmpty {
                // 非 Claude 窗口：打开空 Terminal 窗口恢复位置
                let emptyScript = """
                tell application "Terminal"
                    activate
                    do script ""
                end tell
                """
                if runAppleScript(emptyScript) {
                    result.restored += 1
                    log("[TerminalRestore] opened empty Terminal window (non-Claude)")
                } else {
                    result.failed += 1
                }
                continue
            }

            // 使用 AppleScript 打开 Terminal 窗口并执行命令
            let script = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """

            let success = runAppleScript(script)
            if success {
                result.restored += 1
                log("[TerminalRestore] opened Terminal window for \(win.claudeProjectDir ?? "?")")

                // 延迟一下避免同时开太多窗口
                if result.restored < windows.count {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            } else {
                result.failed += 1
                log("[TerminalRestore] failed to open Terminal window for \(win.claudeProjectDir ?? "?")", level: .warn)
            }
        }

        // 窗口位置和 Space 恢复（需要等窗口完全打开）
        if result.restored > 0 || result.skipped > 0 {
            Task {
                await waitForTerminalWindowsReady(expectedCount: windows.count)
                repositionAndMoveToSpace(windows: windows)
            }
        }

        return result
    }

    /// 构建恢复命令（带 claude --resume 降级）
    private func buildRestoreCommand(for win: TerminalWindowSnapshot) -> String {
        guard let projectDir = win.claudeProjectDir, !projectDir.isEmpty else {
            return ""
        }

        var command = "cd \(escapeAppleScript(projectDir))"
        if let sessionID = win.claudeSessionID, !sessionID.isEmpty {
            // resume 失败时降级为启动新 session
            command += " && claude --resume \(escapeAppleScript(sessionID)) 2>/dev/null || claude"
        } else {
            command += " && claude"
        }
        return command
    }

    // MARK: - Duplicate Detection

    private struct ExistingWindow {
        let windowID: UInt32
        let pid: pid_t
        let frame: CGRect
        let title: String
    }

    /// 枚举当前已有的 Terminal 窗口
    private func enumerateExistingTerminalWindows() -> [ExistingWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { info in
            guard let name = info[kCGWindowOwnerName as String] as? String,
                  name == "Terminal",
                  let wid = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else {
                return nil
            }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
            guard frame.width > 50, frame.height > 50 else { return nil }
            let title = info[kCGWindowName as String] as? String ?? ""
            return ExistingWindow(windowID: wid, pid: pid, frame: frame, title: title)
        }
    }

    /// 检查快照窗口是否已在现有窗口中存在（去重）
    private func findExistingMatch(for snapshot: TerminalWindowSnapshot, in existing: [ExistingWindow]) -> ExistingWindow? {
        for win in existing {
            // 匹配策略 1：标题包含项目路径
            if let projectDir = snapshot.claudeProjectDir,
               !projectDir.isEmpty,
               win.title.contains(projectDir) || win.title.contains(URL(fileURLWithPath: projectDir).lastPathComponent) {
                return win
            }
            // 匹配策略 2：位置接近（容差 100px）
            let snapshotFrame = snapshot.frame.cgRect
            if abs(win.frame.origin.x - snapshotFrame.origin.x) < 100 &&
               abs(win.frame.origin.y - snapshotFrame.origin.y) < 100 &&
               abs(win.frame.width - snapshotFrame.width) < 100 &&
               abs(win.frame.height - snapshotFrame.height) < 100 {
                return win
            }
        }
        return nil
    }

    // MARK: - Window Wait & Reposition

    /// 轮询等待 Terminal 窗口就绪（最多 10 秒）
    private func waitForTerminalWindowsReady(expectedCount: Int = 1) async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            let count = enumerateExistingTerminalWindows().count
            if count >= expectedCount {
                log("[TerminalRestore] Terminal windows ready (\(count) found, expected \(expectedCount))")
                return
            }
        }
        log("[TerminalRestore] timeout waiting for Terminal windows after 10s (expected \(expectedCount))", level: .warn)
    }

    private func repositionAndMoveToSpace(windows: [TerminalWindowSnapshot]) {
        let existingWindows = enumerateExistingTerminalWindows()
        log("[TerminalRestore] repositioning \(existingWindows.count) windows")

        // 按 snapshot 顺序匹配并移动（使用更智能的匹配）
        var usedWindowIDs = Set<UInt32>()

        for snapshot in windows {
            guard let target = findBestMatch(
                snapshot: snapshot,
                candidates: existingWindows,
                usedWindowIDs: usedWindowIDs
            ) else {
                log("[TerminalRestore] no match found for snapshot window \(snapshot.windowID)", level: .debug)
                continue
            }

            usedWindowIDs.insert(target.windowID)

            // 先移动窗口到原始 Space，再设置位置
            // 顺序很重要：坐标是相对于目标屏幕的，必须先让窗口到正确的 Space/Display
            if let spaceIndex = snapshot.spaceIndex {
                let moved = SpaceController.shared.moveWindow(
                    target.windowID,
                    toSpaceIndex: spaceIndex,
                    focus: false
                )
                log("[TerminalRestore] move window \(target.windowID) to space \(spaceIndex): \(moved)")
            }

            // 恢复窗口位置和大小（通过 AX API，使用当前 PID）
            // 快照中存储的是 CGWindowList 的 Quartz 坐标（Y 向下），AX API 使用 AppKit 坐标（Y 向上）
            let targetFrame = snapshot.frame.cgRect
            // Space 移动后 AX 引用可能失效，重新获取
            if let axWindow = WindowManager.shared.findWindowByPID(target.pid, windowID: target.windowID) {
                // 先设置大小（大小在两个坐标系中相同）
                var size = CGSize(width: targetFrame.width, height: targetFrame.height)
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                }
                // 转换 Quartz Y → AppKit Y：appKitY = mainScreenHeight - quartzY - height
                let mainScreenHeight = NSScreen.screens[0].frame.height
                var origin = CGPoint(x: targetFrame.origin.x, y: mainScreenHeight - targetFrame.origin.y - targetFrame.height)
                if let originValue = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, originValue)
                }
                log("[TerminalRestore] repositioned window \(target.windowID) to (\(origin.x), \(origin.y)) \(targetFrame.width)x\(targetFrame.height)")
            }
        }
    }

    /// 智能匹配：用多维度评分找最佳匹配窗口
    private func findBestMatch(
        snapshot: TerminalWindowSnapshot,
        candidates: [ExistingWindow],
        usedWindowIDs: Set<UInt32>
    ) -> ExistingWindow? {
        var bestMatch: ExistingWindow?
        var bestScore = 0

        for candidate in candidates {
            guard !usedWindowIDs.contains(candidate.windowID) else { continue }

            var score = 0
            let snapshotFrame = snapshot.frame.cgRect

            // 位置接近度（越高越好）
            let distX = abs(candidate.frame.origin.x - snapshotFrame.origin.x)
            let distY = abs(candidate.frame.origin.y - snapshotFrame.origin.y)
            if distX < 100 && distY < 100 { score += 50 }
            else if distX < 200 && distY < 200 { score += 20 }

            // 标题匹配
            if let projectDir = snapshot.claudeProjectDir,
               !projectDir.isEmpty {
                let dirName = URL(fileURLWithPath: projectDir).lastPathComponent
                if candidate.title.contains(dirName) { score += 40 }
                if candidate.title.contains(projectDir) { score += 20 }
            }

            // 大小接近
            let sizeDiff = abs(candidate.frame.width - snapshotFrame.width) + abs(candidate.frame.height - snapshotFrame.height)
            if sizeDiff < 100 { score += 10 }

            if score > bestScore {
                bestScore = score
                bestMatch = candidate
            }
        }

        return bestMatch
    }

    // MARK: - Helpers

    private func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            log("[TerminalRestore] AppleScript error: \(error)", level: .warn)
            return false
        }
        return true
    }

    private func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}
