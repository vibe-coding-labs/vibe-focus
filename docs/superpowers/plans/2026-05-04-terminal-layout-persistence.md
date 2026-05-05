# Terminal Window Layout Persistence & Restore

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 持续追踪所有 Terminal 窗口的屏幕 ID + 工作区 ID + 屏幕位置 + 窗口大小，在机器重启后自动恢复完整的终端工作区布局。

**Architecture:** VibeFocus 启动时创建 LayoutSnapshotManager 单例，通过 CGWindowListCopyWindowInfo 每 5 秒轮询所有 Terminal 类 app 窗口，记录 (bundleID, title, displayID, spaceIndex, frame) 到 JSON 文件。当 VibeFocus 在机器重启后启动时，读取快照文件，枚举当前 Terminal 窗口，通过 (title + displayIndex + approximate position) 启发式匹配，然后用 AXUIElement 恢复窗口位置/大小，通过 NativeSpaceBridge 或 yabai 恢复 Space 分配。Claude Code 的 SessionStart hook 触发时立即进行一次快照并启动定时追踪。

**Tech Stack:** Swift 5.9, macOS 14+, CoreGraphics (CGWindowList), ApplicationServices (AXUIElement), SkyLight Private API, yabai (optional), GCDWebServer (hooks)

**Risks:**
- CGWindowList 每 5 秒轮询有 CPU 开销 → 缓解：只过滤 Terminal 类 app (bundleID 白名单)，跳过最小化窗口
- macOS Space ID 跨重启不稳定 → 缓解：记录 display-relative position 作为 fallback，不依赖绝对 Space ID
- yabai 未安装时无法获取 Space 信息 → 缓解：NativeSpaceBridge + position-only restore
- Accessibility 权限丢失导致无法操控窗口 → 缓解：权限检查 + 用户提示，快照仍可记录

---

### Task 1: Layout Snapshot Data Model

**Depends on:** None
**Files:**
- Create: `Sources/LayoutSnapshot.swift`
- Create: `Sources/LayoutSnapshotManager.swift` (partial — data structures only)

- [ ] **Step 1: 创建 LayoutSnapshot 数据结构 — 定义终端窗口快照的所有字段**

```swift
// Sources/LayoutSnapshot.swift
import Foundation
import CoreGraphics

/// 单个终端窗口的快照，用于跨重启恢复
struct TerminalWindowSnapshot: Codable, Equatable {
    /// 稳定标识：bundleID + title hash（不依赖 CGWindowID）
    let stableID: String
    /// 应用 Bundle Identifier（com.apple.Terminal, com.googlecode.iterm2 等）
    let bundleIdentifier: String
    /// 应用名称
    let appName: String
    /// 窗口标题（Terminal 中通常是 "cwd — command" 格式）
    let title: String?
    /// 窗口所在的 Display ID（CGDirectDisplayID）
    let displayID: UInt32
    /// 窗口所在的 Display 索引（0=主屏, 1=副屏...）
    let displayIndex: Int
    /// 窗口所在的 Space 索引（yabai index，可能为 nil）
    let spaceIndex: Int?
    /// 窗口位置和大小（屏幕坐标）
    let frame: RectPayload
    /// 进程 PID（辅助匹配，重启后无效）
    let pid: Int32
    /// 快照时间
    let capturedAt: Date

    /// 启发式匹配键：用于跨重启匹配同一窗口
    var matchKey: String {
        // bundleID + title prefix (取第一个空格前的路径/命令部分)
        let titlePrefix = title?.split(separator: " ").first.map(String.init) ?? title ?? ""
        return "\(bundleIdentifier):\(titlePrefix):\(displayIndex)"
    }
}

/// 完整的终端布局快照，包含所有终端窗口
struct TerminalLayoutSnapshot: Codable {
    /// 快照 ID
    let id: String
    /// 所有终端窗口快照
    let windows: [TerminalWindowSnapshot]
    /// 快照时间
    let capturedAt: Date
    /// 创建快照时连接的显示器数量
    let displayCount: Int
    /// 创建快照时连接的显示器 ID 列表
    let displayIDs: [UInt32]
}

/// 支持追踪的终端应用 Bundle ID 白名单
enum TerminalAppBundle: String, CaseIterable {
    case appleTerminal = "com.apple.Terminal"
    case iterm2 = "com.googlecode.iterm2"
    case kitty = "net.kovidgoyal.kitty"
    case wezterm = "com.github.wez.wezterm"
    case warp = "dev.warp.Warp-Stable"
    case alacritty = "io.alacritty"
    case hyper = "co.zeit.hyper"
    case tabby = "org.tabby"

    var displayName: String {
        switch self {
        case .appleTerminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .kitty: return "Kitty"
        case .wezterm: return "WezTerm"
        case .warp: return "Warp"
        case .alacritty: return "Alacritty"
        case .hyper: return "Hyper"
        case .tabby: return "Tabby"
        }
    }

    static var allBundleIDs: Set<String> {
        Set(TerminalAppBundle.allCases.map { $0.rawValue })
    }
}
```

- [ ] **Step 2: 创建 LayoutSnapshotManager 骨架 — 定义管理器的接口和属性**

```swift
// Sources/LayoutSnapshotManager.swift
import Foundation
import CoreGraphics
import AppKit

@MainActor
final class LayoutSnapshotManager: ObservableObject {
    static let shared = LayoutSnapshotManager()

    // MARK: - Published State
    @Published private(set) var lastSnapshot: TerminalLayoutSnapshot?
    @Published private(set) var isTracking = false
    @Published private(set) var snapshotCount = 0

    // MARK: - Configuration
    /// 快照轮询间隔（秒）
    private let snapshotInterval: TimeInterval = 5.0
    /// 快照文件最大保留数量
    private let maxSnapshotHistory = 10
    /// 快照过期时间（7天）
    private let snapshotExpiration: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Private State
    private var snapshotTimer: Timer?
    private let snapshotFileURL: URL
    private let historyDirectoryURL: URL

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vibefocusDir = appSupport.appendingPathComponent("VibeFocus", isDirectory: true)
        let layoutDir = vibefocusDir.appendingPathComponent("LayoutSnapshots", isDirectory: true)

        self.snapshotFileURL = layoutDir.appendingPathComponent("current-snapshot.json")
        self.historyDirectoryURL = layoutDir.appendingPathComponent("history", isDirectory: true)

        // 确保目录存在
        try? FileManager.default.createDirectory(at: layoutDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)

        // 加载上次快照
        self.lastSnapshot = loadLatestSnapshot()
    }

    // MARK: - Public Interface

    /// 启动定时快照追踪
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        // 立即拍一次快照
        captureSnapshot()
        // 启动定时器
        snapshotTimer = Timer.scheduledTimer(
            withTimeInterval: snapshotInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureSnapshot()
            }
        }
        log("[LayoutSnapshotManager] started tracking, interval=\(snapshotInterval)s")
    }

    /// 停止定时快照追踪
    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        log("[LayoutSnapshotManager] stopped tracking")
    }

    /// 手动触发一次快照
    func captureSnapshot() {
        let windows = enumerateTerminalWindows()
        let displays = NSScreen.screens
        let displayIDs = displays.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

        let snapshot = TerminalLayoutSnapshot(
            id: UUID().uuidString,
            windows: windows,
            capturedAt: Date(),
            displayCount: displays.count,
            displayIDs: displayIDs
        )

        lastSnapshot = snapshot
        snapshotCount += 1
        persistSnapshot(snapshot)
        rotateHistory()
    }

    /// 根据保存的快照恢复所有终端窗口布局
    func restoreFromSnapshot() -> Int {
        guard let snapshot = loadLatestSnapshot() else {
            log("[LayoutSnapshotManager] no snapshot to restore")
            return 0
        }
        return restoreLayout(snapshot)
    }

    // MARK: - Window Enumeration (to be implemented in Task 2)

    func enumerateTerminalWindows() -> [TerminalWindowSnapshot] {
        // Task 2 will implement this
        return []
    }

    // MARK: - Layout Restore (to be implemented in Task 4)

    func restoreLayout(_ snapshot: TerminalLayoutSnapshot) -> Int {
        // Task 4 will implement this
        return 0
    }

    // MARK: - Persistence

    private func persistSnapshot(_ snapshot: TerminalLayoutSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotFileURL, options: .atomic)
    }

    private func loadLatestSnapshot() -> TerminalLayoutSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: snapshotFileURL),
              let snapshot = try? decoder.decode(TerminalLayoutSnapshot.self, from: data) else {
            return nil
        }
        // 检查过期
        guard Date().timeIntervalSince(snapshot.capturedAt) < snapshotExpiration else {
            log("[LayoutSnapshotManager] snapshot expired, removing")
            try? FileManager.default.removeItem(at: snapshotFileURL)
            return nil
        }
        return snapshot
    }

    private func rotateHistory() {
        // 每小时保存一份历史快照到 history 目录
        guard snapshotCount % (Int(3600 / snapshotInterval)) == 0 else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(lastSnapshot) else { return }
        let filename = "snapshot-\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: historyDirectoryURL.appendingPathComponent(filename), options: .atomic)

        // 清理过期历史
        cleanupHistory()
    }

    private func cleanupHistory() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let sorted = files.sorted { a, b in
            (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970 ?? 0) ?? 0
                < (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970 ?? 0) ?? 0
        }

        // 只保留最新的 maxSnapshotHistory 份
        if sorted.count > maxSnapshotHistory {
            for file in sorted.prefix(sorted.count - maxSnapshotHistory) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
```

- [ ] **Step 3: 验证数据结构编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/LayoutSnapshot.swift Sources/LayoutSnapshotManager.swift && git commit -m "feat(layout): add terminal window layout snapshot data model"`

---

### Task 2: Terminal Window Enumeration

**Depends on:** Task 1
**Files:**
- Modify: `Sources/LayoutSnapshotManager.swift:108-112` (replace enumerateTerminalWindows stub)
- Modify: `Sources/WindowManager.swift` — add findDisplayIndex helper

- [ ] **Step 1: 实现 enumerateTerminalWindows — 通过 CGWindowList 枚举所有终端窗口**

```swift
// Replace LayoutSnapshotManager.enumerateTerminalWindows() stub
// File: Sources/LayoutSnapshotManager.swift

func enumerateTerminalWindows() -> [TerminalWindowSnapshot] {
    let terminalBundleIDs = TerminalAppBundle.allBundleIDs
    let options: CGWindowListOption = [.optionOnScreenOnly]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    let displays = NSScreen.screens
    var displayMap: [UInt32: Int] = [:]
    for (index, screen) in displays.enumerated() {
        if let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            displayMap[screenID] = index
        }
    }

    var snapshots: [TerminalWindowSnapshot] = []

    for window in windowList {
        guard let bundleID = window["kCGWindowOwnerName"] as? String ?? window[kCGWindowBundleIdentifier as String] as? String,
              let pid = window[kCGWindowOwnerPID as String] as? Int32,
              let windowNumber = window[kCGWindowNumber as String] as? UInt32,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
            continue
        }

        // 过滤：只追踪终端类应用
        let resolvedBundleID = resolveBundleIdentifier(pid: pid, ownerName: bundleID)
        guard terminalBundleIDs.contains(resolvedBundleID) else { continue }

        // 过滤：跳过零大小窗口（最小化或隐藏）
        let width = bounds["Width"] ?? 0
        let height = bounds["Height"] ?? 0
        guard width > 50 && height > 50 else { continue }

        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let title = window["kCGWindowName"] as? String

        // 确定窗口所在的 Display
        let windowFrame = CGRect(x: x, y: y, width: width, height: height)
        let (displayID, displayIndex) = findDisplayForFrame(windowFrame, displayMap: displayMap, displays: displays)

        // 获取 Space Index（需要 yabai 或 NativeSpaceBridge）
        let spaceIndex = querySpaceIndex(windowID: windowNumber)

        // 生成稳定 ID
        let titlePrefix = title?.split(separator: " ").first.map(String.init) ?? title ?? ""
        let stableID = "\(resolvedBundleID)-\(titlePrefix)-\(displayIndex)"

        let snapshot = TerminalWindowSnapshot(
            stableID: stableID,
            bundleIdentifier: resolvedBundleID,
            appName: bundleID,
            title: title,
            displayID: displayID,
            displayIndex: displayIndex,
            spaceIndex: spaceIndex,
            frame: RectPayload(x: x, y: y, width: width, height: height),
            pid: pid,
            capturedAt: Date()
        )
        snapshots.append(snapshot)
    }

    return snapshots
}

/// 通过 PID 获取真实的 Bundle Identifier（CGWindowList 的 kCGWindowOwnerName 返回的是 app 名不是 bundle ID）
private func resolveBundleIdentifier(pid: Int32, ownerName: String) -> String {
    let runningApps = NSRunningApplication.getRunningApplicationsWithProcessIdentifier(pid)
    if let app = runningApps, let bundleID = app.bundleIdentifier {
        return bundleID
    }
    // Fallback: 用 ownerName 匹配已知的终端 app
    let knownNames: [String: String] = [
        "Terminal": "com.apple.Terminal",
        "iTerm2": "com.googlecode.iterm2",
        "kitty": "net.kovidgoyal.kitty",
        "WezTerm": "com.github.wez.wezterm",
        "Warp": "dev.warp.Warp-Stable",
        "Alacritty": "io.alacritty",
        "Hyper": "co.zeit.hyper",
        "Tabby": "org.tabby",
    ]
    return knownNames[ownerName] ?? ownerName
}

/// 确定窗口所在的 Display ID 和索引
private func findDisplayForFrame(
    _ frame: CGRect,
    displayMap: [UInt32: Int],
    displays: [NSScreen]
) -> (displayID: UInt32, displayIndex: Int) {
    let windowCenter = CGPoint(x: frame.midX, y: frame.midY)

    for screen in displays {
        let screenFrame = screen.visibleFrame
        if screenFrame.contains(windowCenter) {
            if let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
               let index = displayMap[screenID] {
                return (screenID, index)
            }
        }
    }

    // Fallback: 取重叠面积最大的屏幕
    var bestOverlap: CGFloat = 0
    var bestIndex = 0
    var bestID: UInt32 = 0

    for screen in displays {
        let sf = screen.visibleFrame
        let overlapX = max(0, min(frame.maxX, sf.maxX) - max(frame.minX, sf.minX))
        let overlapY = max(0, min(frame.maxY, sf.maxY) - max(frame.minY, sf.minY))
        let overlap = overlapX * overlapY

        if overlap > bestOverlap {
            bestOverlap = overlap
            if let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                bestID = screenID
                bestIndex = displayMap[screenID] ?? 0
            }
        }
    }

    return (bestID, bestIndex)
}

/// 查询窗口所在的 Space 索引
private func querySpaceIndex(windowID: UInt32) -> Int? {
    // 优先通过 yabai 查询
    if let spaceController = SpaceController.shared {
        return spaceController.windowSpaceIndex(windowID: windowID)
    }
    return nil
}
```

- [ ] **Step 2: 验证枚举功能编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/LayoutSnapshotManager.swift && git commit -m "feat(layout): implement terminal window enumeration via CGWindowList"`

---

### Task 3: Periodic Snapshot Tracking & Hook Integration

**Depends on:** Task 2
**Files:**
- Modify: `Sources/ClaudeHookServer.swift` — 在 SessionStart hook 中启动快照追踪
- Modify: `Sources/VibeFocusApp.swift` — 在 app 启动时恢复布局

- [ ] **Step 1: 在 ClaudeHookServer 的 SessionStart handler 中启动布局追踪**

```swift
// File: Sources/ClaudeHookServer.swift
// 在 handleSessionStart 方法末尾（session binding 完成后）添加：

// 启动终端窗口布局快照追踪
// Claude Code 启动时立即开始记录所有 Terminal 窗口位置
LayoutSnapshotManager.shared.startTracking()
```

- [ ] **Step 2: 在 ClaudeHookServer 的 Stop handler 中停止追踪**

```swift
// File: Sources/ClaudeHookServer.swift
// 在 handleStop 方法末尾添加：

// Claude Code session 结束，停止定时追踪（但保留最后一次快照）
LayoutSnapshotManager.shared.stopTracking()
```

- [ ] **Step 3: 在 VibeFocusApp 启动时检查并恢复布局**

在 `VibeFocusApp.swift` 的 `init()` 或 `onAppear` 中，在 WindowManager 初始化之后添加布局恢复逻辑：

```swift
// File: Sources/VibeFocusApp.swift
// 在 app 初始化阶段（WindowManager.shared 初始化之后）添加：

// 尝试恢复上次保存的终端布局
// 仅在启动后 3 秒执行，等待 Terminal.app 等应用完成启动
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
    let restored = LayoutSnapshotManager.shared.restoreFromSnapshot()
    if restored > 0 {
        log("[VibeFocusApp] restored layout for \(restored) terminal windows")
    }
}
```

- [ ] **Step 4: 验证 Hook 集成编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/ClaudeHookServer.swift Sources/VibeFocusApp.swift && git commit -m "feat(layout): integrate snapshot tracking with Claude hooks and app startup"`

---

### Task 4: Layout Restore Engine

**Depends on:** Task 2
**Files:**
- Modify: `Sources/LayoutSnapshotManager.swift` — replace restoreLayout stub

- [ ] **Step 1: 实现 restoreLayout — 从快照恢复终端窗口位置、大小和 Space 分配**

```swift
// Replace LayoutSnapshotManager.restoreLayout() stub
// File: Sources/LayoutSnapshotManager.swift

func restoreLayout(_ snapshot: TerminalLayoutSnapshot) -> Int {
    // 获取当前所有终端窗口
    let currentWindows = enumerateTerminalWindows()
    guard !currentWindows.isEmpty else {
        log("[LayoutSnapshotManager] no terminal windows found to restore")
        return 0
    }

    var restoredCount = 0

    // 按匹配质量排序：先恢复精确匹配，再恢复模糊匹配
    let matches = matchWindows(saved: snapshot.windows, current: currentWindows)

    for match in matches {
        guard let saved = match.saved, let current = match.current else { continue }

        // 1. 恢复窗口位置和大小
        if restoreWindowFrame(windowID: current.pid, targetFrame: saved.frame) {
            restoredCount += 1
            log(
                "[LayoutSnapshotManager] restored window",
                fields: [
                    "app": saved.appName,
                    "title": saved.title ?? "nil",
                    "displayIndex": String(saved.displayIndex),
                    "spaceIndex": saved.spaceIndex.map(String.init) ?? "nil",
                ]
            )
        }

        // 2. 恢复 Space 分配
        if let spaceIndex = saved.spaceIndex {
            restoreWindowSpace(pid: current.pid, spaceIndex: spaceIndex)
        }
    }

    log("[LayoutSnapshotManager] restore complete: \(restoredCount)/\(snapshot.windows.count) windows restored")
    return restoredCount
}

// MARK: - Window Matching

private struct WindowMatch {
    let saved: TerminalWindowSnapshot?
    let current: TerminalWindowSnapshot?
    let score: Double // 0.0-1.0, higher = better match
}

private func matchWindows(
    saved: [TerminalWindowSnapshot],
    current: [TerminalWindowSnapshot]
) -> [WindowMatch] {
    var matches: [WindowMatch] = []
    var usedCurrentIndices: Set<Int> = []

    for savedWindow in saved {
        var bestMatch: (index: Int, score: Double)? = nil

        for (i, currentWindow) in current.enumerated() {
            guard !usedCurrentIndices.contains(i) else { continue }

            let score = computeMatchScore(saved: savedWindow, current: currentWindow)
            if score > 0.3, (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (i, score)
            }
        }

        if let match = bestMatch {
            usedCurrentIndices.insert(match.index)
            matches.append(WindowMatch(
                saved: savedWindow,
                current: current[match.index],
                score: match.score
            ))
        } else {
            // 没有匹配的当前窗口 — 可能已关闭
            matches.append(WindowMatch(saved: savedWindow, current: nil, score: 0))
        }
    }

    // 添加没有匹配的新窗口
    for (i, currentWindow) in current.enumerated() {
        if !usedCurrentIndices.contains(i) {
            matches.append(WindowMatch(saved: nil, current: currentWindow, score: 0))
        }
    }

    return matches.sorted { $0.score > $1.score }
}

/// 计算两个窗口的匹配分数
private func computeMatchScore(saved: TerminalWindowSnapshot, current: TerminalWindowSnapshot) -> Double {
    var score: Double = 0

    // 1. Bundle ID 必须匹配（权重 40%）
    if saved.bundleIdentifier == current.bundleIdentifier {
        score += 0.4
    } else {
        return 0 // 不同 app 不匹配
    }

    // 2. Title 匹配（权重 30%）
    if let savedTitle = saved.title, let currentTitle = current.title {
        if savedTitle == currentTitle {
            score += 0.3
        } else if savedTitle.hasPrefix(currentTitle) || currentTitle.hasPrefix(savedTitle) {
            score += 0.2
        } else if titleCommandMatch(saved: savedTitle, current: currentTitle) {
            score += 0.15
        }
    }

    // 3. Display 索引匹配（权重 15%）
    if saved.displayIndex == current.displayIndex {
        score += 0.15
    }

    // 4. 位置接近度（权重 15%）
    let positionDistance = hypot(
        saved.frame.x - current.frame.x,
        saved.frame.y - current.frame.y
    )
    if positionDistance < 50 {
        score += 0.15
    } else if positionDistance < 200 {
        score += 0.08
    }

    return score
}

/// 检查两个 Terminal 标题中的命令部分是否匹配
/// Terminal 标题格式通常是 "cwd — command" 或 "command — cwd"
private func titleCommandMatch(saved: String, current: String) -> Bool {
    let savedParts = saved.components(separatedBy: CharacterSet(charactersIn: " —–"))
    let currentParts = current.components(separatedBy: CharacterSet(charactersIn: " —–"))
    let savedCommands = Set(savedParts.filter { !$0.isEmpty && $0.hasPrefix("/") == false })
    let currentCommands = Set(currentParts.filter { !$0.isEmpty && $0.hasPrefix("/") == false })
    return !savedCommands.isDisjoint(with: currentCommands)
}

// MARK: - Window Frame Restore

private func restoreWindowFrame(windowID: Int32, targetFrame: RectPayload) -> Bool {
    // 通过 AXUIElement 设置窗口位置和大小
    let axApp = AXUIElementCreateApplication(windowID)
    var windows: AnyObject?
    let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows)

    guard err == .success, let axWindows = windows as? [AXUIElement] else {
        log("[LayoutSnapshotManager] failed to get AX windows for pid \(windowID)", level: .warn)
        return false
    }

    // 找到匹配的窗口（取第一个可见窗口）
    for axWindow in axWindows {
        var isMinimized: AnyObject?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &isMinimized)
        if (isMinimized as? Bool) == true { continue }

        // 设置位置
        let position = AXValueCreate(.cgPoint, CGPoint(x: targetFrame.x, y: targetFrame.y))
        if let pos = position {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pos)
        }

        // 设置大小
        let size = AXValueCreate(.cgSize, CGSize(width: targetFrame.width, height: targetFrame.height))
        if let sz = size {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sz)
        }

        return true
    }

    return false
}

// MARK: - Space Restore

private func restoreWindowSpace(pid: Int32, spaceIndex: Int) {
    guard let spaceController = SpaceController.shared else { return }

    // 通过 PID 找到 CGWindowID
    let options: CGWindowListOption = [.optionOnScreenOnly]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

    for window in windowList {
        if let windowPID = window[kCGWindowOwnerPID as String] as? Int32,
           windowPID == pid,
           let windowID = window[kCGWindowNumber as String] as? UInt32 {
            spaceController.moveWindowToSpace(windowID: windowID, targetSpaceIndex: spaceIndex)
            break
        }
    }
}
```

- [ ] **Step 2: 验证恢复引擎编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/LayoutSnapshotManager.swift && git commit -m "feat(layout): implement layout restore engine with heuristic window matching"`

---

### Task 5: End-to-End Testing & Deployment

**Depends on:** Task 3, Task 4
**Files:**
- No new files — integration testing and deployment

- [ ] **Step 1: Build release binary**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: Deploy to /Applications (follow deploy workflow)**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && ./scripts/deploy.sh`（或手动复制 app bundle 到 /Applications）
Expected:
  - VibeFocus.app 出现在 /Applications/
  - App 可正常启动

- [ ] **Step 3: 验证快照追踪功能**

手动测试步骤：
1. 启动 VibeFocus
2. 打开多个 Terminal 窗口，分布在不同屏幕和 Space
3. 启动一个 Claude Code session（触发 SessionStart hook）
4. 等待 10 秒（至少 2 次快照周期）
5. 检查 `~/Library/Application Support/VibeFocus/LayoutSnapshots/current-snapshot.json` 是否包含所有 Terminal 窗口的位置信息

Run: `cat ~/Library/Application\ Support/VibeFocus/LayoutSnapshots/current-snapshot.json | python3 -m json.tool | head -30`
Expected:
  - Output contains JSON with "windows" array
  - Each window has "bundleIdentifier", "displayIndex", "frame", "spaceIndex"

- [ ] **Step 4: 验证布局恢复功能**

手动测试步骤：
1. 记录当前 Terminal 窗口位置
2. 移动几个窗口到不同位置
3. 通过 VibeFocus UI 或 curl 触发布局恢复
4. 验证窗口是否恢复到之前记录的位置

Run: `curl -s "http://127.0.0.1:$(python3 -c "import json; print(json.load(open('$HOME/.vibefocus/hook-config.json')).get('port',39277))")/layout/restore?token=$(python3 -c "import json; print(json.load(open('$HOME/.vibefocus/hook-config.json')).get('token',''))")" | python3 -m json.tool`
Expected:
  - Returns JSON with "restored_count" > 0

- [ ] **Step 5: 提交所有变更**
Run: `git add -A && git commit -m "feat(layout): terminal window layout persistence and restore — e2e tested"`
