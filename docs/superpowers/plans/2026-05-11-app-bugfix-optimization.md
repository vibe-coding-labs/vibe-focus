# App Sources Bug Fixes & Optimizations

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Review 发现的 3 个 Bug 和 1 个优化：SoundManager 引用错乱、主线程阻塞、多余 asyncAfter、AppleScript 同步执行。

**Architecture:** 直接修改现有文件中的函数实现，不引入新文件。每个 Task 修改 1 个文件中的 1-2 个函数，保持行为语义不变。

**Tech Stack:** Swift 5.9+, AppKit, macOS 13+

**Risks:**
- Task 1: Sound cleanup 逻辑变更，快速连续播放时行为会改变（修复后的预期行为）→ 缓解：验证编译通过
- Task 2: 移除 Thread.sleep 改为异步轮询，需确保旧进程终止检测可靠 → 缓解：增加 isTerminated 轮询，超时兜底
- Task 3: 低风险，只是去掉多余的 asyncAfter 包装
- Task 4: AppleScript 改为异步执行，需确保状态更新不被竞态 → 缓解：didCleanupStaleItems 标记仍保留

---

### Task 1: 修复 SoundManager 延迟清理引用错误的 sound 对象

**Depends on:** None
**Files:**
- Modify: `Sources/App/SoundManager.swift:71-121`（playCompletionSound + previewSound 函数）

- [ ] **Step 1: 修改 playCompletionSound — 捕获当前 sound 引用而非读取 self.currentSound**

文件: `Sources/App/SoundManager.swift:71-98`（替换整个 playCompletionSound 函数）

```swift
    func playCompletionSound() {
        guard preferences.soundType != .none else {
            log("[SoundManager] sound type is none, skipping")
            return
        }

        let sound = resolveSound()
        guard let sound else {
            log("[SoundManager] failed to resolve sound", level: .warn, fields: [
                "soundType": preferences.soundType.rawValue
            ])
            return
        }

        // 停止上一个正在播放的声音
        currentSound?.stop()

        sound.volume = preferences.volume
        sound.play()
        currentSound = sound

        log("[SoundManager] playing completion sound", fields: [
            "soundType": preferences.soundType.rawValue,
            "volume": String(preferences.volume)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            // 直接停止捕获的 sound，而非 self.currentSound
            if Self.isPlayingSameSound(lhs: self?.currentSound, rhs: sound) {
                self?.currentSound?.stop()
                self?.currentSound = nil
            }
        }
    }

    private static func isPlayingSameSound(lhs: NSSound?, rhs: NSSound?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs === rhs
    }
```

- [ ] **Step 2: 修改 previewSound — 使用相同的引用安全 cleanup 模式**

文件: `Sources/App/SoundManager.swift:100-121`（替换整个 previewSound 函数）

```swift
    func previewSound(_ soundType: CompletionSoundType, customPath: String? = nil, volume: Float) {
        // 停止上一个正在播放的声音
        currentSound?.stop()

        let sound = resolveSound(soundType: soundType, customPath: customPath)
        guard let sound else {
            log("[SoundManager] preview failed to resolve sound", level: .warn, fields: [
                "soundType": soundType.rawValue
            ])
            return
        }
        sound.volume = volume
        sound.play()
        currentSound = sound

        log("[SoundManager] preview sound", fields: [
            "soundType": soundType.rawValue,
            "volume": String(volume)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if Self.isPlayingSameSound(lhs: self?.currentSound, rhs: sound) {
                self?.currentSound?.stop()
                self?.currentSound = nil
            }
        }
    }
```

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 4: 提交**
Run: `git add Sources/App/SoundManager.swift && git commit -m "fix(sound): capture sound reference in cleanup block to avoid stopping wrong sound"`

---

### Task 2: 移除 applicationDidFinishLaunching 中的主线程 Thread.sleep

**Depends on:** None
**Files:**
- Modify: `Sources/App/AppDelegate.swift:39-76`（单实例处理区块）

- [ ] **Step 1: 修改单实例处理逻辑 — 用异步轮询替代 Thread.sleep**

文件: `Sources/App/AppDelegate.swift:39-76`（替换从 `// 单实例处理` 到 `}` 的整个区块，即 39-63 行的 if-let 块和 66-76 行的锁获取块）

```swift
        // 单实例处理：同版本复用现有进程，不强制重启。
        if let existing = findExistingInstance() {
            let currentVersion = currentAppVersion()
            let existingVersion = existing.version ?? "unknown"
            log("Found existing instance pid=\(existing.app.processIdentifier) version=\(existingVersion) path=\(existing.path ?? "nil")")
            CrashContextRecorder.shared.record("existing_instance_detected pid=\(existing.app.processIdentifier) version=\(existingVersion)")

            if existing.version == nil || existing.version == currentVersion {
                log("Reusing existing same-version instance; activating and opening settings")
                CrashContextRecorder.shared.record("reuse_existing_instance pid=\(existing.app.processIdentifier)")
                requestExistingInstanceOpenSettings()
                existing.app.activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }

            log("Existing instance version differs (current=\(currentVersion), existing=\(existingVersion)); terminating old instance")
            CrashContextRecorder.shared.record("terminate_old_instance pid=\(existing.app.processIdentifier)")
            existing.app.terminate()

            // 异步轮询等待旧进程退出，不阻塞主线程
            waitForTermination(of: existing.app, maxAttempts: 8) { [weak self] terminated in
                guard let self else { return }
                if !terminated {
                    log("Old instance did not terminate gracefully, sending SIGKILL")
                    CrashContextRecorder.shared.record("force_kill_old_instance")
                    kill(existing.app.processIdentifier, SIGKILL)
                }
                self.proceedWithLockAcquisitionAndLaunch()
            }
            return
        }

        proceedWithLockAcquisitionAndLaunch()
```

- [ ] **Step 2: 添加 waitForTermination 辅助方法 — 异步轮询进程退出状态**

文件: `Sources/App/AppDelegate.swift`（在 `currentAppVersion()` 函数之后，约 162 行后插入）

```swift
    private func waitForTermination(
        of app: NSRunningApplication,
        maxAttempts: Int,
        interval: TimeInterval = 0.1,
        completion: @escaping (Bool) -> Void
    ) {
        var attempts = 0
        func check() {
            if app.isTerminated {
                completion(true)
                return
            }
            attempts += 1
            if attempts >= maxAttempts {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: check)
        }
        check()
    }

    private func proceedWithLockAcquisitionAndLaunch() {
        // 获取锁（不同版本替换场景下应能成功）
        if !acquireExclusiveLock() {
            log("Failed to acquire lock, retrying...")
            CrashContextRecorder.shared.record("lock_retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if !self.acquireExclusiveLock() {
                    log("Still cannot acquire lock, terminating self")
                    CrashContextRecorder.shared.record("lock_failed_terminate")
                    NSApp.terminate(nil)
                    return
                }
                self.continueLaunching()
            }
        } else {
            continueLaunching()
        }
    }

    private func continueLaunching() {
        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        PreferencesSync.persistToDisk()
        ClaudeHookServer.shared.applyPreferences()
        ScreenOverlayManager.shared.refreshOverlays()
        ShutdownSnapshotManager.shared.start()
        TerminalRestoreService.shared.checkAndRestore()
        promptAccessibilityIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                SessionWindowRegistry.shared.purgeClosedWindows()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsRequest(_:)),
            name: openSettingsDistributedNotification,
            object: nil
        )
        showSettingsWindowOnLaunch()
    }
```

- [ ] **Step 3: 清理 applicationDidFinishLaunching — 移除已迁移到 continueLaunching 的启动代码**

文件: `Sources/App/AppDelegate.swift:78-113`（删除 `guard enforceExpectedInstallLocation()` 到 `showSettingsWindowOnLaunch()` 的整个区块，这些代码已移入 `continueLaunching()`）

将以下行全部删除：

```swift
        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        PreferencesSync.persistToDisk()
        ClaudeHookServer.shared.applyPreferences()
        ScreenOverlayManager.shared.refreshOverlays()
        ShutdownSnapshotManager.shared.start()
        TerminalRestoreService.shared.checkAndRestore()
        promptAccessibilityIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                SessionWindowRegistry.shared.purgeClosedWindows()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsRequest(_:)),
            name: openSettingsDistributedNotification,
            object: nil
        )
        showSettingsWindowOnLaunch()
```

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 5: 提交**
Run: `git add Sources/App/AppDelegate.swift && git commit -m "refactor(app): replace Thread.sleep with async polling in single-instance handling"`

---

### Task 3: 移除 enforceExpectedInstallLocation 中多余的 asyncAfter

**Depends on:** None
**Files:**
- Modify: `Sources/App/AppDelegate+MenuAndInstance.swift:236-241`

- [ ] **Step 1: 修改 enforceExpectedInstallLocation — 直接调用 terminate**

文件: `Sources/App/AppDelegate+MenuAndInstance.swift:236-241`（替换 showWrongLocationAlert 调用及后续 3 行）

```swift
        showWrongLocationAlert(actual: actual, expectedPaths: expectedPaths)
        NSApp.terminate(nil)
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/App/AppDelegate+MenuAndInstance.swift && git commit -m "refactor(app): remove unnecessary asyncAfter in enforceExpectedInstallLocation"`

---

### Task 4: 将 LoginItemManager 的 AppleScript 清理改为异步执行

**Depends on:** Task 2（确保编译环境正常）
**Files:**
- Modify: `Sources/App/LoginItemManager.swift:52-56`（cleanupStaleLoginItems 调用）

- [ ] **Step 1: 修改 refresh() — 将 cleanupStaleLoginItems 改为异步调用**

文件: `Sources/App/LoginItemManager.swift:52-56`（替换 cleanupStaleLoginItems 调用区块）

```swift
        // 清理指向 .build/ 目录的旧裸二进制 login items（只执行一次）
        if !didCleanupStaleItems {
            didCleanupStaleItems = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.cleanupStaleLoginItems()
            }
        }
```

注意：`cleanupStaleLoginItems()` 本身不需要 `@MainActor`，但类标记了 `@MainActor`，所以需要在函数上添加 `nonisolated`：

文件: `Sources/App/LoginItemManager.swift:61`（在 `private func cleanupStaleLoginItems()` 前添加 `nonisolated`）

```swift
    nonisolated private func cleanupStaleLoginItems() {
```

- [ ] **Step 2: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"
  - Output does NOT contain: "error:"

- [ ] **Step 3: 提交**
Run: `git add Sources/App/LoginItemManager.swift && git commit -m "perf(login): run stale login item cleanup asynchronously to avoid blocking main thread"`
