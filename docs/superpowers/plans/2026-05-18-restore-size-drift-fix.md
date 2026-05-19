# Restore Size Drift Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 restore 后窗口宽度和高度与原始不一致的 bug。两个根因：(1) `readAccurateFrame` 在 moveWindowToMainScreen 中用过期 yabai 缓存覆盖正确的 AX frame，导致 origFrame 被错误存储；(2) AX apply 高度容差 100px 过大，即使 origFrame 正确也会实际偏差。

**Root Cause (Primary):** restore 把窗口设为 1146x707 → 用户 toggle 回主屏 → yabai 还没刷新 → `readAccurateFrame` 检测到 sizeDiff=517>30 → 用 yabai 的过期数据 1663x1079 覆盖 AX 的正确 1146x707 → SQLite 存了错误 origFrame → 下次 restore 用错误尺寸。

**Root Cause (Secondary):** `apply()` 的 tolerance fallback 允许高度偏差 100px（`abs(height差) <= 100`），导致 restore 即使 origFrame 正确也可能实际偏差近百像素。

**Architecture:** Task 1 修复 origFrame 捕获 — 在 moveWindowToMainScreen 中用 AX frame 替代 readAccurateFrame（焦点窗口必在可见 space，AX 准确）。Task 2 收紧 AX apply 容差 — 将 100px 高度容差降为 20px（与其他维度一致）。

**Tech Stack:** Swift 5.9, macOS 14+ AX API

**Risks:**
- moveWindowToMainScreen 的窗口理论上总是在可见 space（焦点窗口）— 如不在，AX 可能不准确 → 缓解：添加日志记录此情况
- 收紧容差可能让之前"恰好通过"的 restore 失败 → 缓解：20px 仍很宽裕，且 expose 了之前被掩盖的问题

---

### Task 1: Fix origFrame Capture — Use AX Frame Directly for Visible Windows

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:126`

- [ ] **Step 1: 替换 readAccurateFrame 为 frame(of:) — 焦点窗口必在可见 space，AX frame 准确**

文件: `Sources/Window/WindowManager+MoveWindow.swift:126`（替换 origFrame 捕获方式）

将：
```swift
        guard let origFrame = readAccurateFrame(windowID: identity.windowID, axElement: windowAX) else {
```

替换为：
```swift
        guard let origFrame = frame(of: windowAX) else {
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

- [ ] **Step 4: 重启 VibeFocus 并验证无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+MoveWindow.swift && git commit -m "fix(restore): use AX frame directly for origFrame capture — prevents stale yabai data corruption"`

---

### Task 2: Tighten AX Apply Height Tolerance from 100px to 20px

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:354-355`

- [ ] **Step 1: 收紧高度容差 — 与宽度容差一致（frameTolerance * 2 = 20px）**

文件: `Sources/Window/WindowManager+AXHelpers.swift:354-355`（替换 tolerance fallback 的尺寸检查）

将：
```swift
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= 100 // 允许高度有较大偏差（最小尺寸限制）
```

替换为：
```swift
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= frameTolerance * 2
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

- [ ] **Step 4: 重启 VibeFocus 并验证无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift && git commit -m "fix(restore): tighten AX apply height tolerance from 100px to 20px — prevents accepting wrong sizes"`
