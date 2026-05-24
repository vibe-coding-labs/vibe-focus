# Refactor: Toggle 目录文件拆分 + 冗余清理

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 拆分 ToggleEngine.swift（662 行）为更小的文件模块，清理 TerminalRestoreService 中重叠的匹配逻辑。

**Architecture:** 使用 Swift extension 拆分 — `ToggleEngine.swift` 保留 public API（save/load/clear），`ToggleEngine+Restore.swift` 承载 restore 全部逻辑。项目已有此模式（WindowManager+Toggle.swift 等）。

**Before/After:**
- Before: ToggleEngine.swift 662 行，restore() 385 行单方法
- After: ToggleEngine.swift ~280 行 + ToggleEngine+Restore.swift ~400 行，restore() 拆为 4 个子方法

**Safety Net:** `swift build` 编译验证
**Scope:** Small
**Risk:** Low

**Risks:**
- Extension 拆分时 `private` 属性/方法需要改为 `fileprivate` 或 `internal` → 缓解：performSpaceSwitch 和 displayCount 改为 internal

**Autonomy Level:** Full

---

### Task 1: Split ToggleEngine.swift — extract restore logic into ToggleEngine+Restore.swift

**Depends on:** None
**Files:**
- Create: `Sources/Toggle/ToggleEngine+Restore.swift`
- Modify: `Sources/Toggle/ToggleEngine.swift`（删除迁移出的 restore/switchToOriginalSpace/performSpaceSwitch）

- [ ] **Step 1: Create ToggleEngine+Restore.swift — 承载 restore 全部逻辑**

将 ToggleEngine.swift 中的以下方法迁移到新文件：
- `restore(windowID:fallbackPID:triggerSource:traceID:)` (line 115-494)
- `performSpaceSwitch(targetDisplay:targetSpace:traceID:intentionallySwitchedDisplays:)` (line 500-557)
- `switchToOriginalSpace(record:windowAX:effectiveWindowID:triggerSource:traceID:intentionallySwitchedDisplays:)` (line 563-661)

新文件结构：

```swift
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - Restore Logic

@MainActor
extension ToggleEngine {

    // restore() 方法 — 从 ToggleEngine.swift 迁移
    // performSpaceSwitch() — 从 ToggleEngine.swift 迁移
    // switchToOriginalSpace() — 从 ToggleEngine.swift 迁移
}
```

操作方式：创建新文件，写入完整的 extension，包含上述三个方法的完整代码（与原文件完全一致）。

- [ ] **Step 2: Update ToggleEngine.swift — 删除已迁移的方法，调整访问级别**

从 ToggleEngine.swift 删除：
- `restore()` 方法体（line 110-494）
- `performSpaceSwitch()` 方法体（line 496-557）
- `switchToOriginalSpace()` 方法体（line 559-662）

保留在 ToggleEngine.swift 中：
- `displayCount` 计算属性（需要改为 internal 以便 extension 访问）
- `store` 属性（已经是 fileprivate，extension 在同一模块内可访问 internal）
- `save()` / `load()` / `loadByPID()` / `clear()`

需要将 `displayCount` 从 `private` 改为 `internal`（去掉 `private`），以便 ToggleEngine+Restore.swift 访问。

- [ ] **Step 3: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift Sources/Toggle/ToggleEngine+Restore.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): split ToggleEngine.swift into base + Restore extension

ToggleEngine.swift (662 lines → ~280 lines) now contains only the
public API: save/load/clear.

ToggleEngine+Restore.swift (~400 lines) contains the restore logic,
space switch helper, and switchToOriginalSpace.

No behavior change — pure file reorganization.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`

---

### Task 2: Consolidate findExistingMatch and findBestMatch in TerminalRestoreService

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/TerminalRestoreService.swift:199-217`（删除 findExistingMatch）
- Modify: `Sources/Toggle/TerminalRestoreService.swift:286-325`（重命名为 matchWindow）

**问题：** `findExistingMatch` 和 `findBestMatch` 有重叠的位置匹配逻辑。`findExistingMatch` 用简单阈值，`findBestMatch` 用评分系统。可以合并为一个 `matchWindow` 方法，用评分系统统一处理去重和重定位匹配。

- [ ] **Step 1: Replace findExistingMatch call site with findBestMatch**

文件: `Sources/Toggle/TerminalRestoreService.swift:88`（restoreTerminalApp 中的 findExistingMatch 调用）

将 `findExistingMatch` 调用替换为 `findBestMatch`，添加最低分数阈值。如果 `findBestMatch` 返回的分数低于最低阈值（例如 30 分），视为无匹配：

替换 `restoreTerminalApp` 方法中 line 88 附近的去重逻辑：

```swift
// 原代码:
// if let _ = findExistingMatch(for: win, in: existingWindows) {
// 替换为:
if findBestMatch(snapshot: win, candidates: existingWindows, usedWindowIDs: [])?.1 ?? 0 >= 30 {
```

这需要将 `findBestMatch` 的返回类型从 `ExistingWindow?` 改为 `(ExistingWindow, Int)?` 以同时返回分数。

- [ ] **Step 2: Update findBestMatch to return score alongside match**

文件: `Sources/Toggle/TerminalRestoreService.swift:286-325`

修改 `findBestMatch` 的返回类型和签名，同时删除 `findExistingMatch` 方法：

```swift
    /// 匹配快照窗口到现有窗口 — 返回 (match, score) 或 nil
    private func matchWindow(
        snapshot: TerminalWindowSnapshot,
        candidates: [ExistingWindow],
        usedWindowIDs: Set<UInt32>
    ) -> (ExistingWindow, Int)? {
        var bestMatch: ExistingWindow?
        var bestScore = 0

        for candidate in candidates {
            guard !usedWindowIDs.contains(candidate.windowID) else { continue }

            var score = 0
            let snapshotFrame = snapshot.frame.cgRect

            let distX = abs(candidate.frame.origin.x - snapshotFrame.origin.x)
            let distY = abs(candidate.frame.origin.y - snapshotFrame.origin.y)
            if distX < 100 && distY < 100 { score += 50 }
            else if distX < 200 && distY < 200 { score += 20 }

            if let projectDir = snapshot.claudeProjectDir, !projectDir.isEmpty {
                let dirName = URL(fileURLWithPath: projectDir).lastPathComponent
                if candidate.title.contains(dirName) { score += 40 }
                if candidate.title.contains(projectDir) { score += 20 }
            }

            let sizeDiff = abs(candidate.frame.width - snapshotFrame.width) + abs(candidate.frame.height - snapshotFrame.height)
            if sizeDiff < 100 { score += 10 }

            if score > bestScore {
                bestScore = score
                bestMatch = candidate
            }
        }

        guard let match = bestMatch else { return nil }
        return (match, bestScore)
    }
```

然后更新所有调用点：
1. `restoreTerminalApp` 中的去重检查：`matchWindow(...).map { $0.1 } ?? 0 >= 30`
2. `repositionAndMoveToSpace` 中的匹配：直接用 `matchWindow(...)?.0`

- [ ] **Step 3: Delete findExistingMatch — 已被 matchWindow 取代**

文件: `Sources/Toggle/TerminalRestoreService.swift`（删除整个 `findExistingMatch` 方法，line 199-217）

- [ ] **Step 4: 验证编译**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Toggle/TerminalRestoreService.swift && git commit -m "$(cat <<'EOF'
refactor(toggle): consolidate duplicate window matching logic in TerminalRestoreService

Replace findExistingMatch + findBestMatch with single matchWindow method
that returns (match, score). Dedup check uses score threshold >= 30.

Same matching behavior, less code duplication.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
