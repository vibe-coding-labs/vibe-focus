# Bug Fix: isNearTarget 残留检查阻止从主屏恢复到副屏

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Symptom:** 从主屏幕按快捷键无法恢复窗口到副屏幕原始位置，窗口被错误地居中到副屏
**Root Cause:** `shouldRestoreCurrentWindow()` 第 415-423 行的 `isNearTarget` 检查（200px 容差）在窗口漂移后阻止 restore 路径，导致 toggle 走入 `moveStuckWindowToSecondaryScreen()` 分支
**Impact:** 所有在主屏上漂移超过 200px 的窗口都无法正确 restore — 窗口被居中到副屏而非恢复到原始位置
**Scope:** Tiny
**Risk:** Low
**Risks:** 移除检查后，toggle 会正确走 restore 路径 — ToggleEngine.restore() 内部已有充分的验证（origFrame 屏幕校验、AX apply 结果验证）

---

### Task 1: 移除 shouldRestoreCurrentWindow 中的 isNearTarget 检查

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:415-423`

- [ ] **Step 1: 替换 isNearTarget 阻塞逻辑为日志记录 — 与 ToggleEngine.restore() 的修复保持一致**

文件: `Sources/Window/WindowManager+Toggle.swift:415-423`

替换前（阻塞 restore）:
```swift
        // AX-safe: focused window is always visible
        if let currentFrame = self.frame(of: focusedWindow),
           !record.isNearTarget(currentFrame: currentFrame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: window not at target position",
                level: .warn,
                fields: ["windowID": String(currentWindowID)]
            )
            return false
        }
```

替换后（记录漂移但不阻止）:
```swift
        // 记录窗口漂移信息（仅日志，不阻止 restore）
        // 窗口在主屏停留期间 yabai/macOS/用户都可能调整位置，这是正常行为
        // ToggleEngine.restore() 内部已有完整的验证链（坐标校验、屏幕验证、AX apply 验证）
        if let currentFrame = self.frame(of: focusedWindow),
           !record.isNearTarget(currentFrame: currentFrame) {
            log(
                "[WindowManager] shouldRestoreCurrentWindow: window drifted from target, proceeding to restore",
                level: .info,
                fields: [
                    "windowID": String(currentWindowID),
                    "currentFrame": "\(Int(currentFrame.origin.x)),\(Int(currentFrame.origin.y)) \(Int(currentFrame.size.width))x\(Int(currentFrame.size.height))",
                    "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.size.width))x\(Int(record.targetFrame.size.height))"
                ]
            )
        }
```

- [ ] **Step 2: 验证修复**

Run: `xcodebuild -scheme vibe-focus -configuration Debug build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "BUILD SUCCEEDED"

- [ ] **Step 3: 质量门禁检查**

**手工检查（AI 自行验证）：**
- [ ] 无遗留 debug 语句
- [ ] 无 TODO/FIXME
- [ ] 修改不改变函数签名
- [ ] 日志级别从 `.warn` 改为 `.info`（漂移是正常行为，不应产生警告）

- [ ] **Step 4: 提交**

Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "fix(restore): remove isNearTarget guard in shouldRestoreCurrentWindow — allows restore when window drifted on main screen"`
