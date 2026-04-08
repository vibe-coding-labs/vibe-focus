# 修复 Ctrl+M 切换窗口阻塞问题 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复按下 Ctrl+M 后窗口切换无响应的问题

**Architecture:** `runProcess` 使用 `waitUntilExit()` 同步阻塞执行 yabai 命令，当 yabai 响应慢时会卡住主线程。需要添加超时机制和非阻塞执行。

**Tech Stack:** Swift, Process, yabai

---

## 问题分析

1. `toggle()` → `shouldRestoreCurrentWindow()` → `shouldRestoreAcrossSpaces()` → `refreshAvailabilityIfNeeded()`
2. `refreshAvailability()` 同步执行 `runYabai()` → `runProcess()` → `process.waitUntilExit()`
3. 如果 yabai 响应慢（>5秒），主线程被阻塞，快捷键无响应

---

### Task 1: 给 Process 执行添加超时机制

**Files:**
- Modify: `Sources/SpaceController.swift`

- [ ] **Step 1: 修改 runProcess 添加超时机制**

将同步 `waitUntilExit()` 改为带超时的轮询机制：

```swift
private func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 2.0) -> ShellResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        log("Failed to run \(executable): \(error.localizedDescription)")
        return nil
    }

    // 使用超时机制替代 waitUntilExit
    let startTime = Date()
    while process.isRunning {
        if Date().timeIntervalSince(startTime) > timeout {
            log("Process timed out: \(executable) \(arguments)")
            process.terminate()
            return nil
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    return ShellResult(
        stdout: String(data: output, encoding: .utf8) ?? "",
        stderr: String(data: errorData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
    )
}
```

- [ ] **Step 2: 修改 locateYabai 使用超时**

确保 locateYabai 中的 runProcess 调用也使用超时机制。

---

### Task 2: 让 refreshAvailability 异步执行

**Files:**
- Modify: `Sources/SpaceController.swift`

- [ ] **Step 1: 修改 refreshAvailability 为异步执行**

在后台线程执行 yabai 查询，避免阻塞主线程：

```swift
func refreshAvailability(force: Bool) {
    log("refreshAvailability called, force=\(force), lastCheckAt=\(String(describing: lastCheckAt))")

    if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
        log("Skipping refresh - within check interval")
        return
    }

    // 如果已经在检查中，跳过
    guard !isCheckingAvailability else {
        log("Skipping refresh - already checking")
        return
    }

    isCheckingAvailability = true
    lastCheckAt = Date()
    lastErrorMessage = nil

    // 异步执行 yabai 检查
    DispatchQueue.global(qos: .utility).async { [weak self] in
        guard let self else { return }

        log("Looking for yabai...")
        guard let yabaiPath = self.locateYabai() else {
            DispatchQueue.main.async {
                self.availability = .notInstalled
                self.updateEnabledState()
                self.isCheckingAvailability = false
            }
            return
        }

        log("Found yabai at: \(yabaiPath)")
        
        guard let result = self.runYabai(arguments: ["-m", "query", "--spaces"]) else {
            DispatchQueue.main.async {
                self.availability = .unavailable
                self.lastErrorMessage = "Unable to launch yabai"
                self.updateEnabledState()
                self.isCheckingAvailability = false
            }
            return
        }

        DispatchQueue.main.async {
            if result.exitCode == 0 {
                self.availability = .available
                self.lastErrorMessage = nil
            } else {
                self.availability = .unavailable
                self.lastErrorMessage = self.formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            }
            self.cachedYabaiPath = yabaiPath
            self.updateEnabledState()
            self.isCheckingAvailability = false
        }
    }
}
```

- [ ] **Step 2: 添加 isCheckingAvailability 标志**

```swift
private var isCheckingAvailability = false
```

---

### Task 3: 简化 shouldRestoreAcrossSpaces 避免频繁检查

**Files:**
- Modify: `Sources/WindowManager.swift`

- [ ] **Step 1: 简化 shouldRestoreAcrossSpaces**

如果 yabai 不可用，直接返回 false，不要触发检查：

```swift
func shouldRestoreAcrossSpaces() -> Bool {
    // 不要在这里调用 refreshAvailabilityIfNeeded()
    // 如果 yabai 未启用或不可用，直接返回 false
    guard spaceController.isEnabled else {
        return false
    }

    guard let currentSpace = spaceController.currentSpaceIndex(),
          let candidate = savedWindowStates.last,
          let sourceSpace = candidate.sourceSpaceIndex,
          sourceSpace != currentSpace else {
        return false
    }

    hydrateMemory(from: candidate, window: nil)
    log("Detected moved window state across spaces: source=\(sourceSpace) current=\(currentSpace)")
    return true
}
```

---

### Task 4: 验证修复

**Files:**
- Test: 手动测试

- [ ] **Step 1: 编译测试**

Run: `swift build`
Expected: 编译成功

- [ ] **Step 2: 测试 Ctrl+M 响应**

运行应用，多次按 Ctrl+M 测试响应速度
Expected: 切换窗口响应迅速

- [ ] **Step 3: 测试 yabai 功能**

如果 yabai 可用，测试跨空间窗口恢复功能
Expected: 功能正常

---

### Task 5: 提交修复

- [ ] **Step 1: 提交代码**

```bash
git add Sources/
git commit -m "fix: 修复 Ctrl+M 切换窗口阻塞问题

- 给 runProcess 添加 2 秒超时机制
- 将 refreshAvailability 改为异步执行
- 简化 shouldRestoreAcrossSpaces 避免触发检查
- 防止 yabai 响应慢时阻塞主线程"
```

- [ ] **Step 2: 推送到远程**

```bash
git push origin main
```

---

## 依赖关系

Task 1 → Task 2 → Task 3 → Task 4 → Task 5
