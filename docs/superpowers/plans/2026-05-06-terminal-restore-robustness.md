# Terminal Restore Robustness Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 TerminalRestoreService 的 7 个关键问题，确保开机恢复可靠工作，并防止与 Terminal.app 内置恢复机制冲突。

**Architecture:** 恢复前先检测系统级窗口恢复是否启用 → 枚举已有 Terminal 窗口做去重 → 用 AppleScript 打开缺失的窗口（带 claude --resume 降级） → 轮询等待窗口就绪 → 多维度匹配快照窗口并移动到正确 Space。

**Tech Stack:** Swift 5.9, AppleScript, CGWindowListCopyWindowInfo, NSWorkspace

**Risks:**
- AppleScript 窗口匹配依赖标题/位置，可能不精确 → 缓解：用多维度匹配 + 容差
- macOS 系统级恢复无法 per-app 禁用 → 缓解：运行时检测 + 去重
- 轮询等待窗口可能导致启动变慢 → 缓解：设置 10s 超时上限

---

### Task 1: 修复 TerminalRestoreService 核心恢复逻辑

**Depends on:** None
**Files:**
- Modify: `Sources/TerminalRestoreService.swift`

- [ ] **Step 1: 重写 restoreTerminalApp — 添加去重检测、Terminal 启动检查、claude resume 降级**

文件: `Sources/TerminalRestoreService.swift:66-129`（替换整个 `restoreTerminalApp` 方法和辅助方法）

```swift
// Sources/TerminalRestoreService.swift — 替换 restoreTerminalApp 及其后的所有方法

    // MARK: - Terminal.app Restore

    private struct RestoreResult {
        var restored = 0
        var skipped = 0  // 已存在的窗口（去重跳过）
        var failed = 0
    }

    private func restoreTerminalApp(windows: [TerminalWindowSnapshot]) -> RestoreResult {
        var result = RestoreResult()

        // 检查系统级窗口恢复是否可能已创建了 Terminal 窗口
        let existingWindows = enumerateExistingTerminalWindows()
        log("[TerminalRestore] found \(existingWindows.count) existing Terminal windows before restore")

        for win in windows {
            // 去重：检查是否已有匹配的窗口（Terminal.app 自身恢复的）
            if let match = findExistingMatch(for: win, in: existingWindows) {
                log("[TerminalRestore] skipping duplicate window for \(win.claudeProjectDir ?? "?") — matched existing window \(match.windowID)")
                result.skipped += 1
                continue
            }

            // 构建恢复命令
            let command = buildRestoreCommand(for: win)

            guard !command.isEmpty else {
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
                await waitForTerminalWindowsReady()
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
            return ExistingWindow(windowID: wid, frame: frame, title: title)
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
    private func waitForTerminalWindowsReady() async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            let count = enumerateExistingTerminalWindows().count
            if count > 0 {
                log("[TerminalRestore] Terminal windows ready (\(count) found)")
                return
            }
        }
        log("[TerminalRestore] timeout waiting for Terminal windows after 10s", level: .warn)
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

            // 移动窗口到原始 Space
            if let spaceIndex = snapshot.spaceIndex {
                let moved = NativeSpaceBridge.moveWindow(
                    target.windowID,
                    toSpaceID: Int64(spaceIndex)
                )
                log("[TerminalRestore] move window \(target.windowID) to space \(spaceIndex): \(moved)")
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
```

- [ ] **Step 2: 更新 performRestore 报告 — 区分 restored/skipped/failed**

文件: `Sources/TerminalRestoreService.swift:43-65`（替换 `performRestore` 方法）

```swift
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
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/TerminalRestoreService.swift && git commit -m "fix(restore): add duplicate detection, claude resume fallback, smart window matching"`

---

### Task 2: 在 ShutdownSnapshot 中记录已运行的终端 App

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ShutdownSnapshot.swift:8-10`（添加 runningTerminalApps 字段）
- Modify: `Sources/ShutdownSnapshotManager.swift:155-162`（采集时记录运行中的终端 App）

- [ ] **Step 1: 扩展 ShutdownSnapshot — 添加 runningTerminalApps 字段**

文件: `Sources/ShutdownSnapshot.swift:8-10`

```swift
struct ShutdownSnapshot: Codable {
    /// 快照采集时间
    let capturedAt: Date
    /// 采集时的 macOS 启动时间（用于判断快照是否属于上次启动）
    let systemUptimeAtCapture: TimeInterval
    /// 所有终端窗口快照
    var terminalWindows: [TerminalWindowSnapshot]
    /// 采集时正在运行的终端 App bundle IDs（用于区分"终端没开"和"终端开了但没窗口"）
    let runningTerminalApps: Set<String>
}
```

- [ ] **Step 2: 更新 captureSnapshot — 记录运行中的终端 App**

文件: `Sources/ShutdownSnapshotManager.swift:131-162`（在 `pidToBundleID` 构建后、window 枚举前添加记录）

在 `captureSnapshot()` 方法中，`pidToBundleID` 构建循环之后添加一行：

```swift
        let runningTerminalApps = Set(pidToBundleID.values)
```

然后修改方法末尾的 return 语句：

```swift
        return ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
            terminalWindows: terminalWindows,
            runningTerminalApps: runningTerminalApps
        )
```

同时更新方法开头的空返回：

```swift
            return ShutdownSnapshot(
                capturedAt: Date(),
                systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
                terminalWindows: [],
                runningTerminalApps: []
            )
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/ShutdownSnapshot.swift Sources/ShutdownSnapshotManager.swift && git commit -m "feat(snapshot): track running terminal apps in shutdown snapshot"`

---

### Task 3: 更新测试以匹配新字段

**Depends on:** Task 2
**Files:**
- Modify: `Tests/ShutdownSnapshotTests.swift`

- [ ] **Step 1: 更新测试 — 添加 runningTerminalApps 字段**

文件: `Tests/ShutdownSnapshotTests.swift`（所有 `ShutdownSnapshot` 构造调用添加 `runningTerminalApps: []`）

需要在所有创建 ShutdownSnapshot 的地方添加 `runningTerminalApps` 参数，并添加一个新测试验证该字段。

在所有 `ShutdownSnapshot(...)` 调用中添加 `runningTerminalApps: []`（或具体值），然后添加新测试：

```swift
// Test 5: runningTerminalApps field
print("Test 5: runningTerminalApps tracking")
do {
    let snapshot = ShutdownSnapshot(
        capturedAt: Date(),
        systemUptimeAtCapture: 12345.0,
        terminalWindows: [],
        runningTerminalApps: ["com.apple.Terminal", "com.googlecode.iterm2"]
    )
    check("runningApps count", snapshot.runningTerminalApps.count == 2)
    check("contains Terminal", snapshot.runningTerminalApps.contains("com.apple.Terminal"))
    check("contains iTerm2", snapshot.runningTerminalApps.contains("com.googlecode.iterm2"))

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    check("decoded runningApps", decoded.runningTerminalApps == snapshot.runningTerminalApps)
} catch {
    failed += 1; print("  FAIL: runningTerminalApps threw \(error)")
}
```

- [ ] **Step 2: 运行测试验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift Tests/ShutdownSnapshotTests.swift`
Expected:
  - Exit code: 0
  - Output contains: "passed" and does NOT contain "FAIL"

- [ ] **Step 3: 提交**
Run: `git add Tests/ShutdownSnapshotTests.swift && git commit -m "test(snapshot): update tests for runningTerminalApps field"`
