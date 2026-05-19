# Dock Badge Notification — iTerm2 任务完成时在程序坞显示徽标通知

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Claude Code 任务完成（Stop hook 触发）时，在 VibeFocus 的 Dock 图标上显示数字徽标，同时让 iTerm2 的 Dock 图标弹跳吸引注意力。用户点击后自动清除徽标。

**Architecture:**

```
Stop hook 触发
  → HookEventHandler+WindowMove.swift:192 (moved=true 分支)
  → DockBadgeManager.shared.showBadge()
      1. NSApplication.shared.dockTile.badgeLabel = "1"（VibeFocus 图标）
      2. NSRunningApplication(iTerm2).activate()（触发 iTerm2 Dock bounce）
  → AppDelegate 监听 NSApplication.didBecomeActive
      → DockBadgeManager.shared.clearBadge()
```

数据流：Hook Stop 事件 → 窗口移动成功 → 触发 badge + bounce → 用户看到通知 → 点击 VibeFocus/iTerm2 → badge 自动清除

关键组件：
- `DockBadgeManager`（新文件）— 管理 Dock badge 显示/清除，监听 app 激活事件自动清除
- `HookEventHandler+WindowMove.swift:192-212` — 在 moved=true 分支添加 badge 触发

设计理由：macOS 进程无法直接控制其他进程的 Dock badge，所以用"VibeFocus 显示 badge + iTerm2 bounce 弹跳"组合实现等效效果。

**Tech Stack:** Swift 5.9, AppKit NSApplication.dockTile, NSRunningApplication

**Risks:**
- iTerm2 可能没有运行 → activate 会静默失败，不影响 badge 显示
- 多个 Stop 事件并发 → badge 显示完成计数（1/2/3...），不是简单的 1

**Autonomy Level:** Full

---

## Type Detection

**Plan Type:** Feature
**Scope:** Small
**Risk:** Low
**Detection Reason:** 新增 Dock badge 通知功能，涉及 1 个新文件 + 2 个修改点

---

## Pre-Planning Analysis

**Feature:** Dock Badge Notification
**Scope:** 单一子系统（通知层）
**Files Create:**
- `Sources/App/DockBadgeManager.swift`

**Files Modify:**
- `Sources/Hook/HookEventHandler+WindowMove.swift:192-212`（moved=true 分支，添加 badge 触发）
- `Sources/App/AppDelegate.swift`（添加 didBecomeActive 监听，自动清除 badge）

**Tasks:** 2 tasks
**Order:** Task 1（创建 DockBadgeManager）→ Task 2（集成到 hook + AppDelegate）
**Risks:** 低风险，新代码不影响现有逻辑

---

### Task 1: 创建 DockBadgeManager — Dock 徽标通知管理器

**Depends on:** None
**Files:**
- Create: `Sources/App/DockBadgeManager.swift`

- [ ] **Step 1: 创建 DockBadgeManager.swift — 管理 Dock badge 显示、计数和自动清除**

```swift
import AppKit
import Foundation

/// Dock 徽标通知管理器
/// 任务完成时在 VibeFocus Dock 图标显示数字徽标
/// 同时让目标终端应用的 Dock 图标弹跳
/// 用户激活应用后自动清除
@MainActor
final class DockBadgeManager {
    static let shared = DockBadgeManager()

    private var pendingCount = 0

    private static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92"
    ]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 显示 badge 并弹跳目标终端应用
    func showBadge(targetBundleID: String? = nil, targetAppName: String? = nil) {
        pendingCount += 1
        NSApp.dockTile.badgeLabel = String(pendingCount)

        log("[DockBadgeManager] badge shown", fields: [
            "count": String(pendingCount)
        ])

        bounceTerminalApp(bundleID: targetBundleID, appName: targetAppName)
    }

    /// 清除 badge
    func clearBadge() {
        guard pendingCount > 0 else { return }
        log("[DockBadgeManager] badge cleared", fields: [
            "previousCount": String(pendingCount)
        ])
        pendingCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    /// 用户激活应用时自动清除 badge
    @objc private func appDidBecomeActive() {
        clearBadge()
    }

    /// 让终端应用在 Dock 上弹跳
    private func bounceTerminalApp(bundleID: String?, appName: String?) {
        // 优先通过 bundleID 查找
        if let bid = bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate(options: .activateIgnoringOtherApps)
            log("[DockBadgeManager] bounced terminal app via bundleID", fields: [
                "bundleID": bid
            ])
            return
        }

        // 降级：通过 app name 查找
        if let name = appName {
            let matching = NSWorkspace.shared.runningApplications.first { app in
                app.localizedName?.contains(name) == true
            }
            if let app = matching {
                app.activate(options: .activateIgnoringOtherApps)
                log("[DockBadgeManager] bounced terminal app via name", fields: [
                    "appName": name
                ])
                return
            }
        }

        log("[DockBadgeManager] could not find terminal app to bounce", level: .warn, fields: [
            "bundleID": bundleID ?? "nil",
            "appName": appName ?? "nil"
        ])
    }
}
```

- [ ] **Step 2: 验证编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

---

### Task 2: 集成 DockBadgeManager 到 hook 和 AppDelegate

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:200-204`（SoundManager 旁边添加 badge）
- Modify: `Sources/App/AppDelegate.swift`（如果需要，确保 didBecomeActive 已处理）

- [ ] **Step 1: 在 Stop hook 成功后触发 Dock badge**

文件: `Sources/Hook/HookEventHandler+WindowMove.swift:200-204`

当前代码：
```swift
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
            }
```

替换为：
```swift
            Task { @MainActor in
                SoundManager.shared.playCompletionSound()
                DockBadgeManager.shared.showBadge(
                    targetBundleID: binding.bundleIdentifier,
                    targetAppName: binding.appName
                )
            }
```

- [ ] **Step 2: 验证编译 + 构建部署**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && bash scripts/dev-build.sh 2>&1 | tail -5`
Expected:
  - Build succeeds
  - App signed and installed

- [ ] **Step 3: 提交**

Run: `git add Sources/App/DockBadgeManager.swift Sources/Hook/HookEventHandler+WindowMove.swift && git commit -m "feat(notifications): add dock badge notification when Claude task completes"`
