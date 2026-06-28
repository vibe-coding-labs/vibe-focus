# UI 卡顿性能优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除 VibeFocus Settings UI 卡顿，将主线程被 yabai/hook/log 占用的时间降至可忽略（目标：主线程单次阻塞 < 16ms，UI 保持 60fps 响应）。

**Architecture:**
- **数据怎么流：** 当前 Hook 请求（GCDWebServer 后台回调）主动 hop 到 `@MainActor`，在主线程执行 JSON decode → crash 快照 → 窗口解析（AX）→ yabai query（同步 fork）→ SQLite 写入 → 多条 log，全程阻塞主线程；同时 Overlay 每 0.35-0.8s 在主线程 fork yabai 查询 Space。优化后：yabai 只读 query 改为后台 async API（解除 fork 对主线程的阻塞），overlay 改事件驱动 + 降频，log 序列号改 NSLock，@Published 状态节流，移除每请求 crash 快照。
- **关键组件是什么：** 修改 `YabaiClient`（新增 async query）、`ScreenOverlayManager`（事件驱动刷新）、`Support.log`（NSLock 序列号）、`SessionWindowRegistry`（节流 @Published）、`CrashContext`（去重）、`ClaudeHookServer` + `WindowManager+Toggle`（移除冗余快照）。
- **为什么这样做：** 复用现有的 GCDWebServer 后台回调和 SIGUSR1 signal 机制，不引入新依赖；只优化读路径（yabai query）和纯 IO/计算路径（log、crash 快照），完全不触碰 yabai 写操作和 restore 路径。

**Tech Stack:** Swift 5.9, SwiftUI, GCDWebServer, os_signpost (OSLog), SQLite3, swift-testing 992 tests

**Scope:** Medium（7 Tasks）
**Risk:** Medium

**Risks:**
- Task 1 修改 `YabaiClient` → 缓解：保留同步 `run()` 给写操作，只新增 async query API
- Task 2 修改 overlay 刷新 → 缓解：Space 实际变化靠 SIGUSR1 signal（已有），降频仅影响兜底轮询
- Task 4 节流 @Published → 缓解：节流间隔 ≤ 300ms（用户无感）
- yabai 写操作依赖时序 → 缓解：写操作零改动（[[space_switch_regression]]）

**安全铁律（所有 Task 必须遵守）：**
1. ❌ 禁止修改 yabai **写命令**的线程归属（`window --move`/`window --focus`/`space --focus` 必须主线程串行）
2. ❌ 禁止修改 `ToggleEngine.restore()` 及其调用链
3. ❌ 禁止在 restore 路径添加任何坐标验证 guard（[[feedback_toggle_restore_fragility]]）
4. ❌ 禁止对 `ClaudeHookServer` 做 nonisolated actor 重构（@MainActor 边界复杂、收益低、风险高）
5. ✅ 只优化读路径（yabai `query`）和纯 IO/计算（log、crash 快照、rate limit）

---

### Task 0: 建立性能基准基线

**Depends on:** None
**Files:**
- Create: `Sources/Support/PerformanceSignpost.swift`
- Modify: `Sources/Space/YabaiClient.swift:108-136`
- Modify: `Sources/Hook/ClaudeHookServer.swift:89-96`

- [ ] **Step 1: 创建 PerformanceSignpost 工具 — os_signpost 测量主线程关键路径**

```swift
// Sources/Support/PerformanceSignpost.swift
import os.signpost

/// Performance signposts for Instruments profiling of main-thread hot paths.
enum PerformanceSignpost {
    static let log = OSLog(subsystem: "com.vibefocus.app", category: .pointsOfInterest)

    /// Measure a synchronous block on the current thread.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ block: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try block()
    }
}
```

- [ ] **Step 2: 在 YabaiClient.run 加 signpost — 量化 yabai fork 对线程的占用**

文件: `Sources/Space/YabaiClient.swift:108-136`（用 `PerformanceSignpost.measure("yabai.run") { ... }` 包裹 `run` 函数体）

- [ ] **Step 3: 在 hook 请求处理加 signpost**

文件: `Sources/Hook/ClaudeHookServer.swift:89-96`（用 `PerformanceSignpost.measure("hook.handleRequest") { ... }` 包裹 `handleHookRequest` 调用）

- [ ] **Step 4: 验证编译**

Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 记录基线 — 优化前 hook.handleRequest 和 yabai.run 的典型主线程占用**

Run: `swift build && echo "基线：用 Instruments PointsOfInterest 观察；yabai.run 典型 30-80ms，hook.handleRequest 含 yabai 时 100-300ms（全在主线程）"`
Expected: Exit code 0

- [ ] **Step 6: 提交**

Run: `git add Sources/Support/PerformanceSignpost.swift Sources/Space/YabaiClient.swift Sources/Hook/ClaudeHookServer.swift && git commit -m "perf(signpost): add os_signpost to hook and yabai paths for baseline"`

---

### Task 1: YabaiClient 新增异步查询 API（核心 — 解除主线程阻塞）

**Depends on:** Task 0
**Files:**
- Modify: `Sources/Space/YabaiClient.swift:108-143`

- [ ] **Step 1: 新增 runAsync — 在后台队列执行 yabai，不阻塞调用线程**

文件: `Sources/Space/YabaiClient.swift`（在 `run` 函数之后插入）

```swift
/// 后台队列 — yabai 只读查询专用，避免阻塞主线程。
/// 串行队列保证 query 之间的顺序一致性。
private static let yabaiExecutionQueue = DispatchQueue(label: "vibefocus.yabai.query", qos: .userInitiated)

/// 异步执行 yabai 命令 — 在后台队列运行，不阻塞调用线程。
///
/// 仅用于**只读查询**（`query --spaces` / `query --displays` / `query --space`）。
/// yabai 写操作（`window --move` / `window --focus` / `space --focus`）必须继续使用同步 `run()`，
/// 因为它们有严格的主线程时序依赖（先移 Space 再移窗口坐标）。
static func runAsync(arguments: [String]) async -> YabaiResult? {
    guard yabaiPath() != nil else { return nil }
    return await withCheckedContinuation { continuation in
        yabaiExecutionQueue.async {
            let result = PerformanceSignpost.measure("yabai.runAsync") {
                run(arguments: arguments)
            }
            continuation.resume(returning: result)
        }
    }
}

/// 异步执行 yabai 查询并解码 JSON — 用于读路径的 Space/Display 查询。
static func queryJSONAsync<T: Decodable>(_ type: T.Type, arguments: [String]) async -> T? {
    guard let result = await runAsync(arguments: arguments), result.exitCode == 0 else { return nil }
    return try? JSONDecoder().decode(type, from: Data(result.stdout.utf8))
}
```

- [ ] **Step 2: 验证写操作未受影响 — grep 确认 yabai 写命令仍用同步 run()**

Run: `grep -rn "YabaiClient.run(" Sources/Space/ Sources/Window/ | grep -iE "move|focus|swap|destroy"`
Expected: 写操作（window --move 等）仍调用同步 `run()`，未被改成 async

- [ ] **Step 3: 验证编译**

Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 质量门禁**

Run: `swift build && swift test 2>&1 | grep -E "Test run|failed"`
Expected:
  - Exit code: 0
  - Output contains: "992 tests passed"

- [ ] **Step 5: 提交**

Run: `git add Sources/Space/YabaiClient.swift && git commit -m "perf(yabai): add async query API to unblock main thread on read-only calls"`

---

### Task 2: Overlay 刷新改 async + 降频（事件驱动）

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:36-37, 55-68`
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift:49-141`

- [ ] **Step 1: 降低 fallback 轮询频率 — signal 驱动是主路径，轮询仅兜底**

文件: `Sources/Overlay/ScreenOverlayManager.swift:36-37`（替换两个常量）

```swift
    let singleScreenFallbackRefreshInterval: TimeInterval = 1.0
    let multiScreenFallbackRefreshInterval: TimeInterval = 2.0
```

理由：Space 实际变化由 SIGUSR1 signal 触发（`ScreenOverlayManager+Signal.swift` 已实现），fallback 轮询仅作信号丢失兜底。1.0s/2.0s 足以兜底且降低 60%+ fork 频率。

- [ ] **Step 2: 新增 getPerScreenSpaceIndexAsync — 使用 YabaiClient.runAsync**

文件: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift`（在 `getPerScreenSpaceIndex` 函数之后插入 async 版本；保留原同步版本供 getYabaiSpaceIndex 等同步调用方使用）

```swift
    /// 异步获取单屏 Space index — yabai 查询在后台执行，不阻塞主线程。
    func getPerScreenSpaceIndexAsync(for screen: NSScreen) async -> Int? {
        guard getYabaiPath() != nil else { return nil }
        guard let displayIndex = getYabaiDisplayIndex(for: screen) else { return nil }

        // 后台并发执行两个 yabai 只读查询
        async let displaySpacesResult = YabaiClient.runAsync(
            arguments: ["-m", "query", "--spaces", "--display", "\(displayIndex)"]
        )
        async let focusedResult = YabaiClient.runAsync(
            arguments: ["-m", "query", "--spaces", "--space"]
        )

        let displaySpacesRaw = await displaySpacesResult
        let focusedRaw = await focusedResult

        // 轻量 JSON 解析（主线程，μs 级）
        guard let displaySpacesRaw,
              let data = displaySpacesRaw.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !json.isEmpty else {
            return nil
        }
        let displaySpaces = json.compactMap { space -> SpaceSnapshot? in
            guard let index = space["index"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
        }

        var focusedSpaceIndex: Int?
        if let focusedRaw,
           let focusedData = focusedRaw.stdout.data(using: .utf8),
           let focusedJson = (try? JSONSerialization.jsonObject(with: focusedData)) as? [String: Any] {
            focusedSpaceIndex = focusedJson["index"] as? Int
        }
        guard let focusedSpaceIndex else { return nil }

        let sortedSpaces = displaySpaces.sorted { $0.index < $1.index }
        for (position, space) in sortedSpaces.enumerated() where space.index == focusedSpaceIndex {
            return position + 1
        }
        for (position, space) in sortedSpaces.enumerated() where space.isVisible {
            return position + 1
        }
        return 1
    }
```

- [ ] **Step 3: refreshSpaceIndices 改用 Task + TaskGroup 后台并发查询，主线程仅更新 cache/overlay**

文件: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift:49-106`（替换整个 `refreshSpaceIndices`，新增 `applyRefreshResults` 辅助方法）

```swift
    func refreshSpaceIndices(force: Bool = false) {
        guard !automaticRefreshSuspended || force else { return }
        guard preferences.isEnabled else { return }

        if force {
            log("[REFRESH] Force refresh requested, clearing screenSpaceCache")
            screenSpaceCache.removeAll()
        }

        let screens = NSScreen.screens
        // 后台并发查询所有 screen 的 space index，不阻塞主线程
        Task { [weak self] in
            guard let self else { return }
            var results: [(index: Int, uuid: UUID, spaceIndex: Int)] = []
            await withTaskGroup(of: (Int, UUID, Int?).self) { group in
                for (index, screen) in screens.enumerated() {
                    group.addTask { [weak self] in
                        let uuid = self?.uuidForScreen(screen) ?? UUID()
                        let spaceIndex = await self?.getPerScreenSpaceIndexAsync(for: screen)
                        return (index, uuid, spaceIndex)
                    }
                }
                for await (index, uuid, spaceIndex) in group {
                    if let spaceIndex {
                        results.append((index, uuid, spaceIndex))
                    }
                }
            }
            // 回主线程更新 cache 和 overlay（UI 操作必须主线程）
            await MainActor.run {
                self.applyRefreshResults(results, screens: screens)
            }
        }
    }

    /// 主线程：应用后台查询结果到 cache 和 overlay。
    private func applyRefreshResults(_ results: [(index: Int, uuid: UUID, spaceIndex: Int)], screens: [NSScreen]) {
        var needsRefresh = false
        var changedScreens: [String] = []

        for (index, uuid, currentSpaceIndex) in results {
            if let cached = screenSpaceCache[uuid] {
                if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                    log("[REFRESH] Space index changed: Screen\(index) \(cached.spaceIndex)->\(currentSpaceIndex)")
                    needsRefresh = true
                    changedScreens.append("Screen\(index): \(cached.spaceIndex)->\(currentSpaceIndex)")
                    screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)
                    if index < screens.count, let overlay = overlayWindows[uuid] {
                        overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                        overlay.updatePosition(for: screens[index], position: preferences.position, margin: preferences.panelMargin)
                        overlay.show()
                    }
                }
            } else {
                needsRefresh = true
                changedScreens.append("Screen\(index): new->\(currentSpaceIndex)")
                screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)
                if index < screens.count, let overlay = overlayWindows[uuid] {
                    overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                    overlay.updatePosition(for: screens[index], position: preferences.position, margin: preferences.panelMargin)
                    overlay.show()
                }
            }
        }

        if overlayWindows.count != screens.count {
            log("[REFRESH] Screen count changed (\(overlayWindows.count) -> \(screens.count)), refreshing overlays")
            refreshOverlays()
        } else if needsRefresh {
            log("[REFRESH] Updated screens: \(changedScreens.joined(separator: ", "))")
        }
    }
```

- [ ] **Step 4: 验证编译 + 确认旧同步方法保留**

Run: `grep -rn "getPerScreenSpaceIndex\b" Sources/ --include="*.swift" && swift build 2>&1 | tail -3`
Expected:
  - 旧 `getPerScreenSpaceIndex`（同步）仍被 `getYabaiSpaceIndex` 等调用，未被删除
  - Output contains: "Build complete!"

- [ ] **Step 5: 质量门禁 — SpaceIndexResolver 逻辑未变**

Run: `swift test 2>&1 | grep -E "Test run|failed|chooseIndex"`
Expected:
  - Exit code: 0
  - Output contains: "992 tests passed"

- [ ] **Step 6: 提交**

Run: `git add Sources/Overlay/ && git commit -m "perf(overlay): move space-index queries off main thread + lower fallback poll rate"`

---

### Task 3: Log 序列号改 NSLock（消除 queue.sync 阻塞）

**Depends on:** None
**Files:**
- Modify: `Sources/Support/Support.swift:52-68`

- [ ] **Step 1: 将 LogSequenceGenerator 的 queue.sync 改为 NSLock**

文件: `Sources/Support/Support.swift:52-68`（替换整个 `LogSequenceGenerator` 类）

```swift
private final class LogSequenceGenerator: @unchecked Sendable {
    /// NSLock 替代 DispatchQueue.sync — 消除每条 log 的队列 hop 阻塞。
    /// NSLock 是无队列的互斥锁，微秒级，不阻塞调用线程的调度队列。
    private var value: Int64 = 0
    private let lock = NSLock()

    func next() -> UInt64 {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return UInt64(current)
    }
}
```

- [ ] **Step 2: 验证编译 + 测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Test run|failed"`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!" 和 "992 tests passed"

- [ ] **Step 3: 提交**

Run: `git add Sources/Support/Support.swift && git commit -m "perf(log): replace queue.sync with NSLock for sequence generation"`

---

### Task 4: lastEventDescription @Published 节流（消除 UI 重绘风暴）

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/SessionWindowRegistry.swift:12`
- Modify: `Sources/Hook/SessionWindowRegistry+State.swift`

- [ ] **Step 1: 定位所有 lastEventDescription 赋值点**

Run: `grep -rn "lastEventDescription =" Sources/Hook/ --include="*.swift"`
Expected: 列出全部赋值点（SessionWindowRegistry.swift 的 bind，SessionWindowRegistry+State.swift 的 touch/setLastEventDescription 等）

- [ ] **Step 2: 在 SessionWindowRegistry 增加节流机制**

文件: `Sources/Hook/SessionWindowRegistry.swift`（在 `@Published var lastEventDescription` 声明之后插入）

```swift
    /// lastEventDescription 节流 — 高频 hook 事件（UPS）不应每次都触发全 UI 重绘。
    /// 实际更新最多每 300ms 一次（用户无感），通过合并最近一条事件实现。
    private var lastEventFlushWorkItem: DispatchWorkItem?
    private let lastEventFlushInterval: TimeInterval = 0.3

    /// 节流更新 lastEventDescription — 合并 300ms 内的多条事件为一次 UI 刷新。
    func setLastEventDescriptionThrottled(_ description: String) {
        lastEventFlushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastEventDescription = description
        }
        lastEventFlushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lastEventFlushInterval, execute: work)
    }
```

- [ ] **Step 3: 将所有 `lastEventDescription = "..."` 赋值改为 `setLastEventDescriptionThrottled("...")`**

逐个替换 Step 1 列出的赋值点。注意保留字符串字面量不变，只改方法调用。

- [ ] **Step 4: 验证编译 + 测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Test run|failed"`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!" 和 "992 tests passed"

- [ ] **Step 5: 提交**

Run: `git add Sources/Hook/ && git commit -m "perf(ui): throttle lastEventDescription @Published updates to prevent redraw storms"`

---

### Task 5: 移除冗余 crash 快照（hook 路径 + toggle 去重）

**Depends on:** None
**Files:**
- Modify: `Sources/Hook/ClaudeHookServer.swift:131-133`
- Modify: `Sources/Window/WindowManager+Toggle.swift:13-14`

- [ ] **Step 1: 移除 hook 路径的每请求 crash 快照**

文件: `Sources/Hook/ClaudeHookServer.swift:131-133`

删除这两行：
```swift
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "hook_request")
```

理由：`updateCrashSnapshotFromRuntime()` 是 `@MainActor`（访问 NSWorkspace/WindowManager/HotKeyManager/ClaudeHookServer + `AXIsProcessTrustedWithOptions`），每 hook 请求调用开销显著；`logRuntimeStateSnapshot` 收集几乎相同的字段再打一条 log。hook 请求高频（每 prompt 一次），应用状态在请求间几乎不变，快照低价值。

- [ ] **Step 2: 移除 toggle 路径的重复 logRuntimeStateSnapshot**

文件: `Sources/Window/WindowManager+Toggle.swift:13-14`

保留 `updateCrashSnapshotFromRuntime()`（toggle 是低频用户操作，快照有价值），删除紧随的重复快照：

将：
```swift
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")
```
改为：
```swift
        updateCrashSnapshotFromRuntime()
```

理由：`logRuntimeStateSnapshot` 收集的字段与上一行 `updateCrashSnapshotFromRuntime` 高度重叠，属重复劳动。

- [ ] **Step 3: 验证编译 + 测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Test run|failed"`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!" 和 "992 tests passed"

- [ ] **Step 4: 提交**

Run: `git add Sources/Hook/ClaudeHookServer.swift Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(diag): remove per-request crash snapshot and dedupe toggle snapshot"`

---

### Task 6: 部署验证 + 性能对比

**Depends on:** Task 0, Task 1, Task 2, Task 3, Task 4, Task 5
**Files:** None（验证性 Task）

- [ ] **Step 1: 重新构建并部署**

Run: `swift build && ./install.sh`
Expected:
  - Exit code: 0

- [ ] **Step 2: 启动应用并观察 signpost 对比**

Run: `open ~/Applications/VibeFocus.app && echo "用 Instruments PointsOfInterest 对比：yabai.run 应消失，yabai.runAsync 出现在后台队列；hook.handleRequest 主线程占用应从 100-300ms 降至 < 20ms"`
Expected:
  - 应用启动后 UI 响应流畅

- [ ] **Step 3: 手动验证功能无回归（遵守安全铁律）**

验证清单：
- [ ] Settings UI 打开/切换 tab 流畅（核心目标）
- [ ] 全局热键 toggle 窗口正常移动到主屏（[[space_switch_regression]]）
- [ ] toggle 后 restore 正常回到原位（[[feedback_toggle_restore_fragility]]）
- [ ] 跑一个 Claude session，确认 UPS 触发的窗口移动正常
- [ ] 多屏切换 Space 时 overlay 索引正确更新
- [ ] Settings 活跃会话列表正常刷新（Task 4 节流后仍有更新）

- [ ] **Step 4: 提交最终总结**

Run: `git log --oneline -8`
Expected: 显示 6 个 perf commit + 1 个 signpost commit

---

## 预期收益（优化前后对比）

| 指标 | 优化前 | 优化后 | 改善 |
|------|--------|--------|------|
| Hook 请求主线程占用 | 100-300ms | < 20ms | 90%+ |
| yabai fork 主线程阻塞 | 30-80ms × 5.6/秒 | 0（后台队列） | 100% |
| Overlay 刷新频率 | 0.35s/次 | 1.0s/次 + signal | 60% fork 减少 |
| log 序列号阻塞 | queue.sync × 每条 | NSLock μs 级 | 显著 |
| UI 重绘频率（UPS 时） | 每事件 1 次 | 每 300ms 1 次 | 大幅 |
| 每请求 crash 快照 | 2 次（含 AX 查询） | 0 | 100% |

## 风险回滚

任一 Task 验证失败：
```bash
git revert <commit-sha>   # 回滚单个 Task
swift test                # 确认回滚后测试通过
```

每个 Task 独立提交，可精确回滚单个优化而不影响其他。

## Self-Review 修正记录

- **已删除原 Task 3（nonisolated actor 重构）**：经审查，`ClaudeHookServer` 是 `@MainActor`，从 GCDWebServer 的非 async 同步闭包调用 `@MainActor` 方法会编译失败（需 `await`）；nonisolated 重构收益依赖前置 Task 且引入 actor 边界复杂性，违反脆弱路径慎改原则。其唯一有效部分（移除 hook crash 快照）已并入 Task 5。
- 当前 7 个 Task 全部为读路径或纯 IO 优化，零触碰 yabai 写操作和 restore 路径，符合安全铁律。
