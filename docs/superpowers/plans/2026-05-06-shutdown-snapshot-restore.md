# Shutdown Snapshot & Terminal Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在 macOS 关机时自动采集所有 Terminal 窗口状态（屏幕 ID、Space ID、窗口位置、Claude Code 项目路径、Session ID），下次开机时自动恢复这些 Terminal 窗口到原始位置并恢复 Claude Code 会话。

**Architecture:** 关机事件触发 → `ShutdownSnapshotManager` 遍历 CGWindowList 采集所有 Terminal 窗口 → 关联 SessionWindowRegistry 获取 Claude 绑定信息 → 序列化为 JSON 持久化到 `~/.vibefocus/shutdown-snapshot.json`。开机后 AppLauncher 检测快照文件 → 通过 AppleScript 打开 Terminal 窗口并执行 `claude --resume` → 使用 NativeSpaceBridge 移动窗口到原始 Space → 定位到原始屏幕坐标。复用现有 WindowManager/SpaceController 的窗口枚举、Space 切换、窗口定位能力。

**Tech Stack:** Swift 5.9, macOS 14+, CGWindowListCopyWindowInfo, NSWorkspace Notifications, AppleScript (Terminal automation), NativeSpaceBridge (SLS private API), SQLite (WindowStateStore)

**Risks:**
- macOS 关机时 app 可用时间极短（~5s），快照必须同步且极速 → 缓解：JSON 文件写入 + 保持数据结构简单
- `willPowerOffNotification` 对菜单栏 app 不一定触发 → 缓解：同时监听 `willTerminateNotification` + 定时自动快照（每 10 分钟）
- Terminal 窗口恢复依赖 AppleScript，不同终端 app 脚本不同 → 缓解：Phase 1 先支持 Terminal.app，后续扩展 iTerm2/Warp
- Claude Code session 可能已过期无法 resume → 缓解：降级为 `cd <project_dir> && claude` 启动新 session
- 窗口移动到指定 Space 需要辅助功能权限 → 缓解：启动时检查权限，无权限则跳过 Space 恢复只恢复位置

---

### Task 1: Shutdown Snapshot Data Model & Persistence

**Depends on:** None
**Files:**
- Create: `Sources/ShutdownSnapshot.swift`

- [ ] **Step 1: 创建 ShutdownSnapshot 数据模型 — 定义关机快照的完整数据结构**

```swift
// Sources/ShutdownSnapshot.swift
import Foundation
import CoreGraphics

/// 关机时的终端窗口快照，用于下次开机恢复
struct ShutdownSnapshot: Codable {
    /// 快照采集时间
    let capturedAt: Date
    /// 采集时的 macOS 启动时间（用于判断快照是否属于上次启动）
    let systemUptimeAtCapture: TimeInterval
    /// 所有终端窗口快照
    var terminalWindows: [TerminalWindowSnapshot]
}

/// 单个终端窗口在关机时的状态
struct TerminalWindowSnapshot: Codable, Equatable {
    /// CGWindowNumber — 窗口唯一标识（恢复后窗口 ID 会变化）
    let windowID: UInt32
    /// 终端进程 PID（恢复后会变化）
    let pid: Int32
    /// 终端 App 名称（如 "Terminal", "iTerm2"）
    let appName: String
    /// Bundle Identifier（如 "com.apple.Terminal"）
    let bundleIdentifier: String
    /// 窗口标题
    let title: String?
    /// 窗口在屏幕上的位置和大小
    let frame: SnapshotRect
    /// 所在屏幕的 Display ID (CGDirectDisplayID)
    let displayID: UInt32
    /// 所在 Space 的全局 index (yabai) — 可为 nil（无 yabai 时）
    let spaceIndex: Int?
    /// 所在 Space 的 display-local index
    let displayLocalSpaceIndex: Int?
    /// 终端 TTY 路径（如 /dev/ttys001）
    let tty: String?
    /// Terminal.app 的 TERM_SESSION_ID
    let termSessionID: String?
    /// iTerm2 的 ITERM_SESSION_ID
    let itermSessionID: String?
    // MARK: - Claude Code 关联信息
    /// Claude Code Session ID
    let claudeSessionID: String?
    /// Claude Code 项目绝对路径
    let claudeProjectDir: String?
    /// Claude Code 使用的模型
    let claudeModel: String?
}

/// CGRect 的 Codable 包装
struct SnapshotRect: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
```

- [ ] **Step 2: 验证数据模型编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/ShutdownSnapshot.swift && git commit -m "feat(snapshot): add shutdown snapshot data model"`

---

### Task 2: Shutdown Event Detection & Periodic Snapshot

**Depends on:** Task 1
**Files:**
- Create: `Sources/ShutdownSnapshotManager.swift`

- [ ] **Step 1: 创建 ShutdownSnapshotManager — 监听关机事件并触发快照采集**

```swift
// Sources/ShutdownSnapshotManager.swift
import Foundation
import AppKit

@MainActor
final class ShutdownSnapshotManager {
    static let shared = ShutdownSnapshotManager()

    /// 快照文件路径
    private let snapshotDir: String
    private let snapshotPath: String

    /// 定时快照间隔（秒）
    private let periodicInterval: TimeInterval = 10 * 60 // 10 分钟
    private var periodicTimer: Timer?

    /// 是否已启用关机快照
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shutdownSnapshotEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "shutdownSnapshotEnabled")
            PreferencesSync.persistToDisk()
        }
    }

    private init() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".vibefocus")
        snapshotDir = dir
        snapshotPath = (dir as NSString).appendingPathComponent("shutdown-snapshot.json")
    }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled else {
            log("[ShutdownSnapshot] disabled, skipping startup")
            return
        }
        registerShutdownNotifications()
        startPeriodicSnapshot()
        log("[ShutdownSnapshot] started — monitoring shutdown events + periodic snapshots every \(Int(periodicInterval/60))min")
    }

    func stop() {
        unregisterShutdownNotifications()
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Shutdown Notifications

    private func registerShutdownNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerOff(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        log("[ShutdownSnapshot] registered shutdown notifications")
    }

    private func unregisterShutdownNotifications() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handlePowerOff(_ notification: Notification) {
        log("[ShutdownSnapshot] power-off event received: \(notification.name.rawValue)")
        captureAndSave(reason: "shutdown_\(notification.name.rawValue)")
    }

    // MARK: - Periodic Snapshot

    private func startPeriodicSnapshot() {
        periodicTimer = Timer.scheduledTimer(withTimeInterval: periodicInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureAndSave(reason: "periodic")
            }
        }
    }

    // MARK: - Snapshot Capture

    func captureAndSave(reason: String) {
        let startTime = Date()
        log("[ShutdownSnapshot] capturing snapshot (reason: \(reason))")

        let snapshot = captureSnapshot()
        let elapsed = Date().timeIntervalSince(startTime)

        guard saveSnapshot(snapshot) else {
            log("[ShutdownSnapshot] failed to save snapshot", level: .error)
            return
        }

        log("[ShutdownSnapshot] captured \(snapshot.terminalWindows.count) terminal windows in \(String(format: "%.0f", elapsed * 1000))ms (reason: \(reason))")
    }

    /// 采集当前所有终端窗口快照
    func captureSnapshot() -> ShutdownSnapshot {
        var terminalWindows: [TerminalWindowSnapshot] = []

        // 获取所有终端类 App 的窗口
        let terminalBundleIDs: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
        ]

        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            log("[ShutdownSnapshot] failed to enumerate windows", level: .error)
            return ShutdownSnapshot(
                capturedAt: Date(),
                systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
                terminalWindows: []
            )
        }

        // 按 PID 分组，过滤终端 App
        var pidToBundleID: [pid_t: String] = [:]
        var pidToAppName: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, terminalBundleIDs.contains(bundleID) {
                pidToBundleID[app.processIdentifier] = bundleID
                pidToAppName[app.processIdentifier] = app.localizedName ?? bundleID
            }
        }

        // 逐窗口采集
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bundleID = pidToBundleID[pid],
                  let appName = pidToAppName[pid] else {
                continue
            }

            // 跳过不可见窗口（layer != 0）
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? UInt32 else { continue }

            // 窗口位置
            var frame = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
                frame = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
            }
            guard frame.width > 50, frame.height > 50 else { continue }

            let title = info[kCGWindowName as String] as? String
                ?? info["kCGWindowName" as String] as? String

            // 获取屏幕 ID
            let displayID = WindowManager.shared.displayID(for: frame)

            // 获取 Space 信息
            let spaceContext = SpaceController.shared.captureSpaceContext(for: windowID)

            // 从 SessionWindowRegistry 查找 Claude Code 绑定
            let claudeBinding = SessionWindowRegistry.shared.findBinding(forWindowID: windowID)

            let snapshot = TerminalWindowSnapshot(
                windowID: windowID,
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleID,
                title: title,
                frame: SnapshotRect(frame),
                displayID: displayID ?? 0,
                spaceIndex: spaceContext.sourceSpaceIndex,
                displayLocalSpaceIndex: spaceContext.sourceDisplaySpaceIndex,
                tty: claudeBinding?.tty,
                termSessionID: claudeBinding?.termSessionID,
                itermSessionID: claudeBinding?.itermSessionID,
                claudeSessionID: claudeBinding?.sessionID,
                claudeProjectDir: claudeBinding?.cwd,
                claudeModel: claudeBinding?.model
            )

            terminalWindows.append(snapshot)
        }

        return ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
            terminalWindows: terminalWindows
        )
    }

    // MARK: - Persistence

    private func saveSnapshot(_ snapshot: ShutdownSnapshot) -> Bool {
        guard FileManager.default.fileExists(atPath: snapshotDir) else {
            try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
        }

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            return true
        } catch {
            log("[ShutdownSnapshot] save failed: \(error)", level: .error)
            return false
        }
    }

    /// 读取上次关机快照
    func loadSnapshot() -> ShutdownSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    }

    /// 快照是否来自上次启动（判断 systemUptime 是否小于当前 uptime）
    func isSnapshotFromPreviousBoot(_ snapshot: ShutdownSnapshot) -> Bool {
        snapshot.systemUptimeAtCapture < ProcessInfo.processInfo.systemUptime - 60
    }

    /// 清除快照文件（恢复完成后调用）
    func clearSnapshot() {
        try? FileManager.default.removeItem(atPath: snapshotPath)
        log("[ShutdownSnapshot] snapshot file cleared")
    }

    /// 快照文件是否存在
    var hasPendingSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotPath)
    }
}
```

- [ ] **Step 2: 添加 SessionWindowRegistry 查询方法和 WindowManager displayID 辅助方法**
文件: `Sources/SessionWindowRegistry.swift`（在 class 末尾 ~line 209 之前添加）
文件: `Sources/WindowManager+ScreenPosition.swift`（在 class 末尾添加）

在 `SessionWindowRegistry.swift` 添加查找方法：

```swift
// Sources/SessionWindowRegistry.swift — 在 class 末尾添加

/// 根据 windowID 查找绑定信息（返回轻量结构，不暴露内部 WindowState）
func findBinding(forWindowID windowID: UInt32) -> (tty: String?, termSessionID: String?, itermSessionID: String?, sessionID: String?, cwd: String?, model: String?)? {
    guard let state = windowStates[windowID] else { return nil }
    return (
        tty: state.tty,
        termSessionID: state.termSessionID,
        itermSessionID: state.itermSessionID,
        sessionID: state.sessionID,
        cwd: state.cwd,
        model: state.model
    )
}
```

在 `WindowManager+ScreenPosition.swift` 添加 displayID(for frame:) 辅助方法：

```swift
// Sources/WindowManager+ScreenPosition.swift — 在 class 末尾添加

/// 根据窗口 frame 确定所在屏幕的 Display ID
func displayID(for frame: CGRect) -> UInt32? {
    let context = displayContext(for: frame)
    return context.displayID
}
```

- [ ] **Step 3: 在 SpaceController 添加 captureSpaceContext(for:) 方法**
文件: `Sources/SpaceController.swift`（在 class 末尾添加）

```swift
// Sources/SpaceController.swift — 在 class 末尾添加

/// 根据窗口 ID 采集 Space 上下文信息
func captureSpaceContext(for windowID: UInt32) -> SpaceContext {
    let sourceSpace = windowSpaceIndex(windowID: windowID)
    let displayIdx = windowDisplayIndex(windowID: windowID)
    let displayLocal = displayIdx.flatMap { displayLocalSpaceIndex(globalSpaceIndex: sourceSpace ?? 0, displayIndex: $0) }
    return SpaceContext(
        sourceSpaceIndex: sourceSpace,
        targetSpaceIndex: nil,
        sourceDisplayIndex: displayIdx,
        sourceDisplaySpaceIndex: displayLocal
    )
}
```

- [ ] **Step 4: 在 AppLauncher 启动流程中注册 ShutdownSnapshotManager**
文件: `Sources/AppLauncher.swift:100-103`（在 startingServices phase 内添加）

```swift
// 替换 Sources/AppLauncher.swift:100-103 的 startingServices phase
await executePhase(.startingServices) {
    ScreenOverlayManager.shared.refreshOverlays()
    ClaudeHookServer.shared.applyPreferences()
    ShutdownSnapshotManager.shared.start()
    return (true, "服务启动完成", nil)
}
```

- [ ] **Step 5: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/ShutdownSnapshotManager.swift Sources/ShutdownSnapshot.swift Sources/SessionWindowRegistry.swift Sources/WindowManager+ScreenPosition.swift Sources/SpaceController.swift Sources/AppLauncher.swift && git commit -m "feat(snapshot): add shutdown detection, periodic snapshots, and terminal window capture"`

---

### Task 3: Boot Restore — Detect & Restore Terminal Windows

**Depends on:** Task 2
**Files:**
- Create: `Sources/TerminalRestoreService.swift`

- [ ] **Step 1: 创建 TerminalRestoreService — 开机后恢复终端窗口**

```swift
// Sources/TerminalRestoreService.swift
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
        let autoRestore = UserDefaults.standard.object(forKey: "autoRestoreOnBoot") as? Bool ?? false
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
        var failedCount = 0

        // 按终端 App 分组
        let byApp = Dictionary(grouping: snapshot.terminalWindows) { $0.bundleIdentifier }

        for (bundleID, windows) in byApp {
            switch bundleID {
            case "com.apple.Terminal":
                let results = restoreTerminalApp(windows: windows)
                restoredCount += results.restored
                failedCount += results.failed
            default:
                log("[TerminalRestore] unsupported terminal app: \(bundleID), skipping \(windows.count) windows", level: .warn)
                failedCount += windows.count
            }
        }

        log("[TerminalRestore] restore complete: \(restoredCount) restored, \(failedCount) failed")

        // 恢复完成后清除快照
        ShutdownSnapshotManager.shared.clearSnapshot()
    }

    // MARK: - Terminal.app Restore

    private struct RestoreResult {
        var restored = 0
        var failed = 0
    }

    private func restoreTerminalApp(windows: [TerminalWindowSnapshot]) -> RestoreResult {
        var result = RestoreResult()

        for win in windows {
            // 构建恢复命令
            var command = ""
            if let projectDir = win.claudeProjectDir, !projectDir.isEmpty {
                command += "cd \(escapeAppleScript(projectDir))"
                if let sessionID = win.claudeSessionID, !sessionID.isEmpty {
                    command += " && claude --resume \(escapeAppleScript(sessionID))"
                } else {
                    command += " && claude"
                }
            } else if let projectDir = extractProjectDirFromTitle(win.title) {
                command = "cd \(escapeAppleScript(projectDir)) && claude"
            }

            guard !command.isEmpty else {
                log("[TerminalRestore] no project dir for window \(win.windowID), skipping", level: .debug)
                result.failed += 1
                continue
            }

            // 使用 AppleScript 打开 Terminal 窗口并执行命令
            let script = """
            tell application "Terminal"
                activate
                set w to do script "\(command)"
                set the bounds of front window to {\(win.frame.x), \(win.frame.y), \(win.frame.x + win.frame.width), \(win.frame.y + win.frame.height)}
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
        if result.restored > 0 {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 等待 3 秒
                await repositionAndMoveToSpace(windows: windows)
            }
        }

        return result
    }

    // MARK: - Window Reposition & Space Movement

    private func repositionAndMoveToSpace(windows: [TerminalWindowSnapshot]) async {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // 查找刚打开的 Terminal 窗口（通过 bundleID 匹配）
        let terminalWindows = windowList.filter { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let name = info[kCGWindowOwnerName as String] as? String else { return false }
            return name == "Terminal"
        }

        for snapshot in windows {
            guard let targetFrame = findMatchingWindow(
                snapshot: snapshot,
                candidates: terminalWindows
            ) else {
                continue
            }

            // 移动窗口到原始 Space
            if let spaceIndex = snapshot.spaceIndex {
                let moved = NativeSpaceBridge.moveWindow(
                    targetFrame.windowID,
                    toSpaceID: Int64(spaceIndex)
                )
                log("[TerminalRestore] move window \(targetFrame.windowID) to space \(spaceIndex): \(moved)")
            }
        }
    }

    private struct WindowCandidate {
        let windowID: UInt32
        let frame: CGRect
    }

    private func findMatchingWindow(
        snapshot: TerminalWindowSnapshot,
        candidates: [[String: Any]]
    ) -> WindowCandidate? {
        // 简单匹配：取 Terminal 的活跃窗口（按窗口 ID 倒序，最新打开的在前面）
        // 后续可以通过 title 匹配提高精度
        for info in candidates {
            guard let wid = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            return WindowCandidate(windowID: wid, frame: frame)
        }
        return nil
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
    }

    /// 从窗口标题中提取项目路径（如 "vim — project (bash)" 不提取）
    private func extractProjectDirFromTitle(_ title: String?) -> String? {
        // Terminal.app 标题通常不包含路径，返回 nil
        return nil
    }
}
```

- [ ] **Step 2: 在 AppLauncher 的 startingServices phase 中集成恢复检查**
文件: `Sources/AppLauncher.swift:100-103`（在 startingServices phase 末尾添加恢复检查）

```swift
// 修改 Sources/AppLauncher.swift:100-103 的 startingServices phase
await executePhase(.startingServices) {
    ScreenOverlayManager.shared.refreshOverlays()
    ClaudeHookServer.shared.applyPreferences()
    ShutdownSnapshotManager.shared.start()
    // 检查关机快照恢复（异步，不阻塞启动）
    TerminalRestoreService.shared.checkAndRestore()
    return (true, "服务启动完成", nil)
}
```

注意：恢复检查合入 `startingServices` phase 而非单独 phase，避免修改 `LaunchPhase` enum（它是 `CaseIterable`，改动需同步 UI 进度映射）。

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/TerminalRestoreService.swift Sources/AppLauncher.swift && git commit -m "feat(restore): add terminal window restore service with AppleScript automation"`

---

### Task 4: Settings UI — Enable/Disable Controls

**Depends on:** Task 2
**Files:**
- Modify: `Sources/SettingsUI.swift`（在关机快照区域添加开关）

- [ ] **Step 1: 在 SettingsUI 中添加关机快照设置开关**

在 `SettingsUI.swift` 中找到合适的位置（搜索 "LoginItemManager" 或 "开机启动" 相关 UI 区域），添加关机快照控制面板：

```swift
// 在 SettingsUI.swift 中适当位置添加关机快照设置区块

// 关机快照设置
VStack(alignment: .leading, spacing: 8) {
    Text("关机快照")
        .font(.headline)

    Toggle("关机时自动保存终端窗口状态", isOn: Binding(
        get: { ShutdownSnapshotManager.shared.isEnabled },
        set: { ShutdownSnapshotManager.shared.isEnabled = $0 }
    ))

    if ShutdownSnapshotManager.shared.hasPendingSnapshot {
        HStack {
            Text("检测到上次关机快照")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("立即恢复") {
                if let snapshot = ShutdownSnapshotManager.shared.loadSnapshot() {
                    TerminalRestoreService.shared.performRestore(snapshot)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("清除快照") {
                ShutdownSnapshotManager.shared.clearSnapshot()
            }
            .controlSize(.small)
        }
    }

    Toggle("开机时自动恢复终端窗口", isOn: Binding(
        get: { UserDefaults.standard.object(forKey: "autoRestoreOnBoot") as? Bool ?? false },
        set: { UserDefaults.standard.set($0, forKey: "autoRestoreOnBoot"); PreferencesSync.persistToDisk() }
    ))
}
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/SettingsUI.swift && git commit -m "feat(ui): add shutdown snapshot settings with restore controls"`

---

### Task 5: Integration Test & Manual Verification

**Depends on:** Task 3, Task 4
**Files:**
- Create: `Tests/ShutdownSnapshotTests.swift`

- [ ] **Step 1: 创建快照数据模型测试**

```swift
// Tests/ShutdownSnapshotTests.swift
import XCTest
@testable import VibeFocus

final class ShutdownSnapshotTests: XCTestCase {

    func testSnapshotEncodingDecoding() {
        let rect = SnapshotRect(CGRect(x: 100, y: 200, width: 800, height: 600))
        let window = TerminalWindowSnapshot(
            windowID: 12345,
            pid: 67890,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            title: "bash — 80x24",
            frame: rect,
            displayID: 1234567,
            spaceIndex: 3,
            displayLocalSpaceIndex: 1,
            tty: "/dev/ttys001",
            termSessionID: "ABC-123",
            itermSessionID: nil,
            claudeSessionID: "session-xyz-789",
            claudeProjectDir: "/Users/test/projects/myapp",
            claudeModel: "claude-sonnet-4-6"
        )

        let snapshot = ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: 12345.0,
            terminalWindows: [window]
        )

        // 编码
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else {
            XCTFail("Failed to encode snapshot")
            return
        }

        // 解码
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(ShutdownSnapshot.self, from: data) else {
            XCTFail("Failed to decode snapshot")
            return
        }

        XCTAssertEqual(decoded.terminalWindows.count, 1)
        XCTAssertEqual(decoded.terminalWindows[0], window)
        XCTAssertEqual(decoded.terminalWindows[0].claudeSessionID, "session-xyz-789")
        XCTAssertEqual(decoded.terminalWindows[0].claudeProjectDir, "/Users/test/projects/myapp")
        XCTAssertEqual(decoded.terminalWindows[0].displayID, 1234567)
        XCTAssertEqual(decoded.terminalWindows[0].spaceIndex, 3)
        XCTAssertEqual(decoded.systemUptimeAtCapture, 12345.0)
    }

    func testSnapshotRectConversion() {
        let original = CGRect(x: 50.5, y: 100.3, width: 1024.0, height: 768.0)
        let rect = SnapshotRect(original)
        XCTAssertEqual(rect.cgRect.origin.x, original.origin.x, accuracy: 0.01)
        XCTAssertEqual(rect.cgRect.origin.y, original.origin.y, accuracy: 0.01)
        XCTAssertEqual(rect.cgRect.width, original.width)
        XCTAssertEqual(rect.cgRect.height, original.height)
    }

    func testIsFromPreviousBoot() {
        let oldSnapshot = ShutdownSnapshot(
            capturedAt: Date().addingTimeInterval(-3600),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime - 3600,
            terminalWindows: []
        )
        // systemUptimeAtCapture < current uptime - 60 → should be from previous boot
        XCTAssertTrue(ShutdownSnapshotManager.shared.isSnapshotFromPreviousBoot(oldSnapshot))

        let freshSnapshot = ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
            terminalWindows: []
        )
        XCTAssertFalse(ShutdownSnapshotManager.shared.isSnapshotFromPreviousBoot(freshSnapshot))
    }

    func testEmptySnapshot() {
        let snapshot = ShutdownSnapshot(
            capturedAt: Date(),
            systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
            terminalWindows: []
        )
        XCTAssertTrue(snapshot.terminalWindows.isEmpty)

        let encoder = JSONEncoder()
        let data = try? encoder.encode(snapshot)
        XCTAssertNotNil(data)

        let decoder = JSONDecoder()
        let decoded = try? decoder.decode(ShutdownSnapshot.self, from: data!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.terminalWindows.count, 0)
    }
}
```

- [ ] **Step 2: 验证测试编译和运行**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Tests/ShutdownSnapshotTests.swift && git commit -m "test(snapshot): add shutdown snapshot data model tests"`
