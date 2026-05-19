# Bug Fix: Restore Captures Wrong Window Size

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 `readAccurateFrame` 在捕获窗口 frame 时只比较位置不比较尺寸，导致保存了错误的 origFrame 尺寸（主屏幕尺寸 1667x1079 泄漏到副屏窗口）。

**Root Cause:** 窗口从主屏 restore 回副屏后，AX API 对非可见 Space 上的窗口返回 stale 的 frame（位置正确但尺寸是主屏的 1667x1079 而非实际的 1146x707）。`readAccurateFrame` 只检查 `positionDiff`（位置差），当位置匹配时直接返回 AX frame，忽略了尺寸不一致。

**Architecture:** `readAccurateFrame` 增加 SIZE 比较逻辑：当 AX 和 yabai 的尺寸差异超过阈值时，优先使用 yabai 的 frame。同时添加日志记录 AX/yabai 的尺寸差异，帮助诊断 yabai auto-tiling 场景。

**Tech Stack:** Swift 5.9, macOS AXUIElement

**Risks:**
- yabai 本身也可能返回 tiled 后的尺寸（非用户原始尺寸） → 缓解：添加详细日志区分是 AX stale 还是 yabai tiled

---

### Task 1: Fix readAccurateFrame to Compare Size in Addition to Position

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:113-131`（readAccurateFrame 函数的 yabai 比较逻辑）

- [ ] **Step 1: 修改 readAccurateFrame — 增加 SIZE 比较和详细日志**

文件: `Sources/Window/WindowManager+AXHelpers.swift:113-131`（替换从 `// yabai 返回 Quartz 坐标` 到 `return axFrame` 的整个比较块）

```swift
        // yabai 返回 Quartz 坐标（Y-down, origin at top-left of primary）
        // 与 AX/apply 坐标系一致，不需要转换
        let yabaiRect = yabaiFrame.cgRect
        let positionDiff = hypot(yabaiRect.midX - axFrame.midX, yabaiRect.midY - axFrame.midY)
        let sizeDiff = max(abs(yabaiRect.width - axFrame.width), abs(yabaiRect.height - axFrame.height))

        // 位置 OR 尺寸任一偏差过大，都应使用 yabai 的数据
        // AX 对非可见 Space 窗口可能返回正确的位置但错误的尺寸（如残留主屏尺寸）
        if positionDiff > frameTolerance * 3 || sizeDiff > frameTolerance * 3 {
            log(
                "[WindowManager] readAccurateFrame: yabai override",
                level: .info,
                fields: [
                    "windowID": String(windowID),
                    "axFrame": "\(axFrame)",
                    "yabaiFrame": "\(yabaiRect)",
                    "positionDiff": String(format: "%.0f", positionDiff),
                    "sizeDiff": String(format: "%.0f", sizeDiff),
                    "reason": sizeDiff > frameTolerance * 3 ? "size_mismatch" : "position_mismatch"
                ]
            )
            return yabaiRect
        }
        return axFrame
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 4: 重启 VibeFocus 并验证无错误**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift && git commit -m "fix(restore): compare SIZE not just position in readAccurateFrame — prevents stale AX frame from corrupting origFrame"`
