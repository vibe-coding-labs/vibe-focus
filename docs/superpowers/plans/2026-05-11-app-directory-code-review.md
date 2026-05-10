# Sources/App/ 代码质量修复

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 `Sources/App/` 目录下的 bug 和代码质量问题：重复路径、~547 行死代码、音频资源泄漏。

**Architecture:** 修复 `expectedAppBundlePaths()` 的重复路径条目 → 删除未使用的 `AppLauncher`/`AppLaunchView`/`AppLaunchStatus` → 修复 `SoundManager` 音频引用泄漏。所有修改限于 `Sources/App/` 目录。

**Tech Stack:** Swift 5.9, macOS 13+

**Risks:**
- 删除 AppLauncher/AppLaunchView 可能影响未来 Launch UI 计划 → 缓解：git 保留历史，可通过 `git checkout` 恢复
- 修改 expectedAppBundlePaths 可能影响安装位置检查逻辑 → 缓解：只是去重，不改变实际路径集合

---

### Task 1: 修复 expectedAppBundlePaths 重复路径 + 删除死代码

**Depends on:** None
**Files:**
- Modify: `Sources/App/AppDelegate.swift:184-191`（修复重复路径）
- Delete: `Sources/App/AppLauncher.swift`（228 行死代码）
- Delete: `Sources/App/AppLaunchView.swift`（242 行死代码）
- Delete: `Sources/App/AppLaunchStatus.swift`（77 行死代码）

- [ ] **Step 1: 修复 `expectedAppBundlePaths()` 重复路径条目**

文件: `Sources/App/AppDelegate.swift:184-191`（替换整个方法）

```swift
    func expectedAppBundlePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            (home as NSString).appendingPathComponent("Applications/VibeFocus.app"),
            "/Applications/VibeFocus.app"
        ]
    }
```

- [ ] **Step 2: 删除未使用的 AppLauncher.swift**

Run: `rm Sources/App/AppLauncher.swift`

- [ ] **Step 3: 删除未使用的 AppLaunchView.swift**

Run: `rm Sources/App/AppLaunchView.swift`

- [ ] **Step 4: 删除未使用的 AppLaunchStatus.swift**

Run: `rm Sources/App/AppLaunchStatus.swift`

- [ ] **Step 5: 验证构建**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**

Run: `git add -A && git commit -m "$(cat <<'EOF'
fix(app): remove dead code and fix duplicate paths

- Fix expectedAppBundlePaths() returning 4 entries with only 2 unique
  paths (home/Applications and /Applications were each duplicated)
- Remove AppLauncher.swift, AppLaunchView.swift, AppLaunchStatus.swift
  (~547 lines) — these launch screen components were never wired into
  the app lifecycle and duplicated logic from AppDelegate

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: 修复 SoundManager 音频引用泄漏

**Depends on:** Task 1
**Files:**
- Modify: `Sources/App/SoundManager.swift:71-92`

- [ ] **Step 1: 修改 `playCompletionSound()` — 播放后自动清理音频引用**

文件: `Sources/App/SoundManager.swift:71-92`（替换 `playCompletionSound()` 方法）

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

        sound.volume = preferences.volume
        sound.play()
        currentSound = sound

        log("[SoundManager] playing completion sound", fields: [
            "soundType": preferences.soundType.rawValue,
            "volume": String(preferences.volume)
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

- [ ] **Step 3: 构建部署验证**

Run: `bash scripts/dev-build.sh 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 4: 提交**

Run: `git add Sources/App/SoundManager.swift && git commit -m "$(cat <<'EOF'
fix(sound): clean up NSSound reference after playback

Release currentSound after 5 seconds to prevent indefinite memory
retention of completed audio instances.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks |
| 2 | Dependencies? | PASS | Task 2 depends on Task 1 |
| 3 | File paths? | PASS | 精确到文件和行号 |
| 4 | 3-8 Steps/Task? | PASS | Task 1: 6, Task 2: 4 |
| 5 | New file complete code? | N/A | 无新文件 |
| 6 | Modify complete function? | PASS | 提供完整替换方法 |
| 7 | Code block size? | PASS | 最大 ~25 行 |
| 8 | No dangling references? | PASS | grep 确认无外部引用 |
| 9 | Validation commands? | PASS | 每个 Task 有 swift build |
| 10 | Coverage complete? | PASS | 覆盖全部 3 个发现 |
| 11 | Independent verification? | PASS | 每个 Task 独立编译验证 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 所有 Step 有具体代码 |
| 14 | Cross-task consistency? | PASS | 文件路径一致 |
| 15 | Save location? | PASS | docs/superpowers/plans/ |

**Status:** ✅ ALL PASS

---

## Execution Selection

**Tasks:** 2
**Dependencies:** Task 2 depends on Task 1
**User Preference:** none
**Decision:** Inline
**Reasoning:** 2 个 Task 修改量小且顺序执行，inline 更快

**Auto-invoking:** 直接执行
