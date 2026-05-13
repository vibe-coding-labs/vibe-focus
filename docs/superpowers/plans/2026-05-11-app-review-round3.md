# Sources/App/ 第三轮代码审查修复

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 Sources/App/ 第三轮审查发现的 3 个问题：脆弱的进程查找、重复的 AppleScript 执行、previewSound 音频引用泄漏。

**Architecture:** 将 `findExistingInstance()` 从 `/bin/ps` 子进程改为直接使用 NSWorkspace API；给 `cleanupStaleLoginItems()` 添加一次性标志位；给 `previewSound()` 添加与 `playCompletionSound()` 相同的音频引用清理逻辑。

**Tech Stack:** Swift 5.9, macOS 13+

**Risks:**
- 移除 `/bin/ps` 方法可能导致无法检测到无 bundle ID 的进程 → 缓解：VibeFocus 始终以 .app bundle 运行，bundle ID 必定存在
- cleanupStaleLoginItems 只运行一次可能遗漏后续出现的 stale items → 缓解：stale items 只会在升级后出现，app 重启时 init 会再次执行

---

### Task 1: 简化 findExistingInstance() 使用 NSWorkspace API

**Depends on:** None
**Files:**
- Modify: `Sources/App/AppDelegate+MenuAndInstance.swift:173-240`

- [ ] **Step 1: 替换 `findExistingInstance()` 方法 — 移除 `/bin/ps` 依赖，直接使用 NSWorkspace**

文件: `Sources/App/AppDelegate+MenuAndInstance.swift:173-240`（替换整个方法）

```swift
    func findExistingInstance() -> ExistingInstanceInfo? {
        log("AppDelegate.findExistingInstance entry", level: .debug)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier

        // 直接通过 NSWorkspace 按 bundle ID 查找
        if let bundleID {
            let runningApps = NSWorkspace.shared.runningApplications
            for app in runningApps {
                if app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
                    log("AppDelegate.findExistingInstance found via bundle ID", level: .debug, fields: ["pid": String(app.processIdentifier)])
                    return ExistingInstanceInfo(
                        app: app,
                        version: installedVersion(for: app),
                        path: app.bundleURL?.path
                    )
                }
            }
        }

        return nil
    }
```

- [ ] **Step 2: 移除不再需要的 `import Darwin` — `flock` 使用已通过其他文件引入**

检查 `AppDelegate+MenuAndInstance.swift` 中是否还有其他 Darwin 符号使用。如果 `flock`/`open`/`close` 调用在 `acquireExclusiveLock()` 中，则保留 `import Darwin`。

实际上 `acquireExclusiveLock()` 在第 149-170 行使用了 `open()`、`flock()`、`close()`，所以 `import Darwin` 必须保留。无需修改。

- [ ] **Step 3: 验证构建**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**

Run: `git add Sources/App/AppDelegate+MenuAndInstance.swift && git commit -m "$(cat <<'EOF'
refactor(app): replace /bin/ps subprocess with NSWorkspace API for instance detection

The /bin/ps approach was fragile (name-based matching, external process
spawn). NSWorkspace.runningApplications with bundle ID matching is faster,
more reliable, and the standard macOS API for this purpose.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 限制 cleanupStaleLoginItems 只运行一次

**Depends on:** None
**Files:**
- Modify: `Sources/App/LoginItemManager.swift:14-16, 51, 56-97`

- [ ] **Step 1: 添加一次性标志位并修改 init 和 refresh**

文件: `Sources/App/LoginItemManager.swift`

在 `private init()` 之前添加属性：
```swift
    private var didCleanupStaleItems = false
```

修改 `refresh()` 中的 `cleanupStaleLoginItems()` 调用（第 51 行），改为：
```swift
        if !didCleanupStaleItems {
            cleanupStaleLoginItems()
            didCleanupStaleItems = true
        }
```

- [ ] **Step 2: 验证构建**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**

Run: `git add Sources/App/LoginItemManager.swift && git commit -m "$(cat <<'EOF'
perf(login): run stale login item cleanup only once per session

AppleScript execution on every refresh() was unnecessarily expensive.
Now gated by a flag so it only runs during initial load.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 3: 修复 previewSound() 音频引用未清理

**Depends on:** None
**Files:**
- Modify: `Sources/App/SoundManager.swift:100-116`

- [ ] **Step 1: 修改 `previewSound()` — 添加音频引用清理**

文件: `Sources/App/SoundManager.swift:100-116`（替换整个方法）

```swift
    func previewSound(_ soundType: CompletionSoundType, customPath: String? = nil, volume: Float) {
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
            self?.currentSound?.stop()
            self?.currentSound = nil
        }
    }
```

- [ ] **Step 2: 验证构建**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**

Run: `git add Sources/App/SoundManager.swift && git commit -m "$(cat <<'EOF'
fix(sound): clean up NSSound reference after preview playback

Release currentSound after 5 seconds in previewSound(), matching
the cleanup already present in playCompletionSound().

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks |
| 2 | Dependencies? | PASS | 3 个独立 Task，无依赖 |
| 3 | File paths? | PASS | 精确到文件和行号 |
| 4 | 3-8 Steps/Task? | PASS | Task 1: 4, Task 2: 3, Task 3: 3 |
| 5 | New file complete code? | N/A | 无新文件 |
| 6 | Modify complete function? | PASS | 提供完整替换方法 |
| 7 | Code block size? | PASS | 最大 ~20 行 |
| 8 | No dangling references? | PASS | 所有引用已存在 |
| 9 | Validation commands? | PASS | 每个 Task 有 swift build |
| 10 | Coverage complete? | PASS | 覆盖全部 3 个发现 |
| 11 | Independent verification? | PASS | 每个 Task 独立编译 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 所有 Step 有具体代码 |
| 14 | Cross-task consistency? | PASS | 无跨 Task 引用 |
| 15 | Save location? | PASS | docs/superpowers/plans/ |

**Status:** ALL PASS

---

## Execution Selection

**Tasks:** 3
**Dependencies:** None (all independent)
**User Preference:** none
**Decision:** Inline
**Reasoning:** 3 个独立 Task 修改量小，inline 最快

**Auto-invoking:** 直接执行
