# 工作区切换实时显示更新优化计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将工作区切换时的屏幕序号-工作区序号显示更新延迟从2秒降低到1秒以内

**Architecture:** 使用 yabai 信号机制 + NSDistributedNotificationCenter 实现事件驱动的工作区切换检测，替代现有的2秒轮询机制。当 yabai 检测到空间切换时，通过信号触发 Swift 端的即时刷新。

**Tech Stack:** Swift, yabai signal system, NSDistributedNotificationCenter, Process

---

## 当前问题分析

- `ScreenOverlayManager` 使用 2 秒定时器轮询 (`refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0...)`)
- 最坏情况下，工作区切换后需要等待近2秒才会更新显示
- 轮询方式浪费CPU资源，且无法做到实时响应

## 解决方案

采用 **yabai 信号 + 分布式通知** 的事件驱动方案：

1. **yabai signal**: 配置 yabai 在空间切换时执行脚本
2. **信号脚本**: 发送 macOS 分布式通知
3. **Swift 监听**: 应用监听通知并即时刷新显示

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `Sources/ScreenOverlayManager.swift` | 添加 yabai 信号配置管理、通知监听 |
| `Resources/yabai-space-changed.sh` | yabai 信号触发时执行的脚本，发送分布式通知 |
| `Sources/ScreenOverlayManager.swift` | 修改：替换轮询为事件驱动，保留轮询作为fallback |

---

### Task 1: 创建 yabai 信号脚本

**Files:**
- Create: `Resources/yabai-space-changed.sh`
- Modify: `Package.swift` (添加资源文件)

- [ ] **Step 1: 创建信号触发脚本**

```bash
#!/bin/bash
# yabai-space-changed.sh
# 当 yabai 检测到空间切换时执行，发送分布式通知给 VibeFocus

/usr/bin/osascript -e 'tell application "VibeFocus" to activate' 2>/dev/null || true

# 发送分布式通知
/usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
    do shell script "echo 'space_changed' | nc -U /tmp/vibefocus.sock 2>/dev/null || true"
end tell
APPLESCRIPT
```

**替代方案（更简单的实现）：**
```bash
#!/bin/bash
# 使用 touch 文件触发，Swift 端监听文件变化
/usr/bin/touch /tmp/vibefocus_space_changed
/usr/bin/killall -USR1 VibeFocus 2>/dev/null || true
```

- [ ] **Step 2: 注册 yabai 信号**

在 `ScreenOverlayManager.swift` 中添加信号注册方法：

```swift
private func registerYabaiSignals() {
    guard let yabaiPath = getYabaiPath() else { return }
    
    // 检查是否已注册信号
    let checkTask = Process()
    checkTask.launchPath = yabaiPath
    checkTask.arguments = ["-m", "signal", "--list"]
    
    let pipe = Pipe()
    checkTask.standardOutput = pipe
    checkTask.launch()
    checkTask.waitUntilExit()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return }
    
    // 如果已经注册了 vibefocus 信号，跳过
    if output.contains("vibefocus-space-changed") {
        return
    }
    
    // 获取脚本路径
    guard let scriptPath = Bundle.main.path(forResource: "yabai-space-changed", ofType: "sh") else {
        log("Could not find yabai-space-changed.sh script")
        return
    }
    
    // 注册信号: 空间切换时触发
    let registerTask = Process()
    registerTask.launchPath = yabaiPath
    registerTask.arguments = [
        "-m", "signal", "--add",
        "event=space_changed",
        "action=\"\(scriptPath)\"",
        "label=vibefocus-space-changed"
    ]
    registerTask.launch()
    registerTask.waitUntilExit()
    
    log("Registered yabai signal for space changes")
}
```

- [ ] **Step 3: 验证脚本权限**

```bash
chmod +x Resources/yabai-space-changed.sh
```

---

### Task 2: 实现信号驱动的刷新机制

**Files:**
- Modify: `Sources/ScreenOverlayManager.swift`

- [ ] **Step 1: 添加信号处理支持**

在 `ScreenOverlayManager` 中添加：

```swift
import Darwin  // for signal.h

// 添加静态变量用于信号处理
private static var signalSource: DispatchSourceSignal?

private func setupSignalHandler() {
    // 设置 SIGUSR1 信号处理
    signal(SIGUSR1, SIG_IGN)  // 忽略默认处理
    
    let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    source.setEventHandler { [weak self] in
        self?.log("Received SIGUSR1, refreshing space indices")
        self?.refreshSpaceIndices()
    }
    source.resume()
    
    ScreenOverlayManager.signalSource = source
    log("Signal handler setup complete")
}
```

- [ ] **Step 2: 修改初始化流程**

```swift
private init() {
    self.preferences = ScreenIndexPreferences.load()
    setupScreenNotifications()
    setupSignalHandler()  // 新增
    registerYabaiSignals()  // 新增
    startRefreshTimer()
}
```

- [ ] **Step 3: 修改定时器为低频fallback**

将轮询间隔从2秒改为10秒，仅作为fallback：

```swift
private func startRefreshTimer() {
    // 降低轮询频率到10秒，作为fallback机制
    // 主要更新由 yabai 信号驱动
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
        Task { @MainActor in
            self?.refreshSpaceIndices()
        }
    }
}
```

---

### Task 3: 优化 yabai 查询性能

**Files:**
- Modify: `Sources/ScreenOverlayManager.swift`

- [ ] **Step 1: 添加查询结果缓存**

```swift
private var lastQueryTime: Date?
private var cachedSpaceIndices: [UUID: Int] = [:]
private let queryDebounceInterval: TimeInterval = 0.1  // 100ms内不重复查询

private func getSpaceIndex(for screen: NSScreen) -> Int? {
    let uuid = uuidForScreen(screen)
    
    // 检查缓存
    if let lastQuery = lastQueryTime,
       Date().timeIntervalSince(lastQuery) < queryDebounceInterval,
       let cached = cachedSpaceIndices[uuid] {
        return cached
    }
    
    // 执行查询
    let result: Int?
    if let yabaiIndex = getYabaiSpaceIndex(for: screen) {
        result = yabaiIndex
    } else if let cgIndex = getCGSpaceIndex(for: screen) {
        result = cgIndex
    } else {
        result = nil
    }
    
    // 更新缓存
    lastQueryTime = Date()
    cachedSpaceIndices[uuid] = result
    
    return result
}
```

- [ ] **Step 2: 优化批量查询**

修改 `refreshSpaceIndices` 减少重复查询：

```swift
private func refreshSpaceIndices() {
    guard preferences.isEnabled else { return }
    
    // 批量获取所有空间信息（单次 yabai 调用）
    guard let allSpaces = getAllYabaiSpaces() else {
        // fallback: 逐个查询
        refreshSpaceIndicesIndividual()
        return
    }
    
    let screens = NSScreen.screens
    var needsRefresh = false
    
    for (index, screen) in screens.enumerated() {
        let uuid = uuidForScreen(screen)
        let currentSpaceIndex = getSpaceIndexFromBatch(allSpaces, for: screen) ?? 0
        
        if let cached = screenSpaceCache[uuid] {
            if cached.screenIndex != index || cached.spaceIndex != currentSpaceIndex {
                needsRefresh = true
                screenSpaceCache[uuid] = (screenIndex: index, spaceIndex: currentSpaceIndex)
                
                if let overlay = overlayWindows[uuid] {
                    overlay.update(screenIndex: index, spaceIndex: currentSpaceIndex, preferences: preferences)
                    overlay.updatePosition(for: screen, position: preferences.position)
                }
            }
        } else {
            needsRefresh = true
        }
    }
    
    if needsRefresh || overlayWindows.count != screens.count {
        refreshOverlays()
    }
}

private func getAllYabaiSpaces() -> [[String: Any]]? {
    guard let yabaiPath = getYabaiPath() else { return nil }
    
    let task = Process()
    task.launchPath = yabaiPath
    task.arguments = ["-m", "query", "--spaces"]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    } catch {
        log("Failed to get all yabai spaces: \(error)")
        return nil
    }
}
```

---

### Task 4: 测试和验证

**Files:**
- Test: 手动测试

- [ ] **Step 1: 构建并运行应用**

```bash
./scripts/dev-build.sh
```

- [ ] **Step 2: 手动测试工作区切换**

1. 打开应用，启用屏幕索引显示
2. 使用快捷键切换工作区（如 `Ctrl+1`, `Ctrl+2`）
3. 观察屏幕角落的索引显示是否在1秒内更新
4. 检查日志确认信号触发: `tail -f ~/Library/Logs/VibeFocus/*.log | grep -E "signal|refresh"`

- [ ] **Step 3: 验证 yabai 信号注册**

```bash
yabai -m signal --list | grep vibefocus
```

应看到类似输出：
```
vibefocus-space-changed  space_changed  /Applications/VibeFocus.app/Contents/Resources/yabai-space-changed.sh
```

- [ ] **Step 4: 测试无 yabai 时的 fallback**

1. 临时重命名 yabai: `mv /opt/homebrew/bin/yabai /opt/homebrew/bin/yabai.bak`
2. 重启应用
3. 确认显示仍然通过轮询更新（10秒间隔）
4. 恢复 yabai: `mv /opt/homebrew/bin/yabai.bak /opt/homebrew/bin/yabai`

---

### Task 5: 清理和优化

**Files:**
- Modify: `Sources/ScreenOverlayManager.swift`

- [ ] **Step 1: 添加信号注销（应用退出时）**

```swift
deinit {
    refreshTimer?.invalidate()
    ScreenOverlayManager.signalSource?.cancel()
    unregisterYabaiSignals()
}

private func unregisterYabaiSignals() {
    guard let yabaiPath = getYabaiPath() else { return }
    
    let task = Process()
    task.launchPath = yabaiPath
    task.arguments = ["-m", "signal", "--remove", "vibefocus-space-changed"]
    task.launch()
    task.waitUntilExit()
    
    log("Unregistered yabai signals")
}
```

- [ ] **Step 2: 提交更改**

```bash
git add Sources/ScreenOverlayManager.swift Resources/yabai-space-changed.sh
git commit -m "feat: optimize workspace switch display update latency

- Replace 2s polling with yabai signal-driven updates
- Add SIGUSR1 signal handler for instant refresh
- Reduce fallback polling to 10s interval
- Add query result caching to reduce yabai calls
- Achieve <1s update latency for workspace switches"
```

---

## 备选方案（如果 yabai 信号不可用）

如果用户环境无法使用 yabai 信号，实施以下降级方案：

### 方案 B: 减少轮询间隔 + 工作区切换快捷键监听

1. 将轮询间隔从2秒减少到0.5秒
2. 监听应用自身的快捷键事件，在检测到工作区切换快捷键时立即刷新

```swift
// 在快捷键处理中添加即时刷新
private func handleWorkspaceSwitch(_ spaceIndex: Int) {
    // 立即刷新显示
    refreshSpaceIndices()
    
    // 延迟再次刷新确保yabai已完成切换
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.refreshSpaceIndices()
    }
}
```

---

## 预期效果

| 指标 | 当前 | 优化后 |
|------|------|--------|
| 平均更新延迟 | 1秒（2秒轮询的中位数） | <0.5秒（事件驱动） |
| 最坏情况延迟 | 2秒 | <1秒 |
| CPU 使用 | 高（频繁轮询） | 低（事件驱动） |
| yabai 查询次数 | 每2秒一次 | 仅在切换时 |

---

## 风险评估

| 风险 | 可能性 | 缓解措施 |
|------|--------|----------|
| yabai 信号注册失败 | 中 | 保持轮询作为fallback |
| 信号脚本权限问题 | 低 | 确保脚本有执行权限 |
| 多用户冲突 | 低 | 使用唯一信号标签 |
| macOS 信号限制 | 低 | 使用 SIGUSR1（用户自定义信号） |
