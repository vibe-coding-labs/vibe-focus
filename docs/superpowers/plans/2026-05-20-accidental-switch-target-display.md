# Bug Fix: "accidentally switched" detector undoes intentional target display space switch

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复 ToggleEngine.restore() 的 "accidentally switched" 检测逻辑，使其跳过被故意切换的目标 display，避免撤销 restore 操作本身做的 space 切换。

**Architecture:** ToggleEngine.restore() 在跨 display restore 时先切换目标 display 到 sourceSpace（第 260-261 行），然后在第 430-446 行检测所有 display 是否有"意外切换"。问题：这个检测不区分目标 display 和非目标 display，导致把刚做的故意切换当作"意外"撤销。

**Tech Stack:** Swift 5.9

**Scope:** Tiny
**Risk:** Low — 只在 for 循环中添加一个 skip 条件

**Risks:**
- 需确认 `record.sourceYabaiDisp` 在所有路径上都是被切换的 display → 已确认：第 248 行 `targetDisplay = record.sourceYabaiDisp` 是唯一被 switchDisplayToSpace 切换的 display

**Autonomy Level:** Full

---

### Task 1: 在 accidentally switched 检测中跳过目标 display

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine.swift:431`

**Symptom:** 窗口 restore 到副显示器后，display 的 space 被切回 restore 前的状态，窗口出现在错误的 space 上或不可见。

**Root Cause:** `ToggleEngine.swift:430-446` 的 for 循环遍历所有 display 检查 space 变化，但没有跳过目标 display（`record.sourceYabaiDisp`）。当 restore 故意把 display 2 从 space 2 切到 space 3 时，检测器发现变化并"修复"（切回 space 2），撤销了 restore 操作本身。

- [ ] **Step 1: 在 accidentally switched 检测中添加目标 display 跳过条件**

文件: `Sources/Toggle/ToggleEngine.swift:430-446`（替换整个 if 块）

找到这段代码：
```swift
        if restored, !preRestoreDisplaySpaces.isEmpty {
            for (disp, preVis) in preRestoreDisplaySpaces {
                let currentVis = spaceController.displayVisibleSpace(displayIndex: disp)
                if let cur = currentVis, cur != preVis {
```

在 `for` 循环体内的 `let currentVis` 之前插入跳过条件：
```swift
        if restored, !preRestoreDisplaySpaces.isEmpty {
            let intentionallySwitchedDisplay = record.sourceYabaiDisp
            for (disp, preVis) in preRestoreDisplaySpaces {
                if disp == intentionallySwitchedDisplay { continue }
                let currentVis = spaceController.displayVisibleSpace(displayIndex: disp)
                if let cur = currentVis, cur != preVis {
```

- [ ] **Step 2: 验证编译通过**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Toggle/ToggleEngine.swift && git commit -m "$(cat <<'EOF'
fix(restore): skip target display in accidentally-switched detector

ToggleEngine.restore() detects "accidentally switched" displays after
space switching and undoes the change. But it was also checking the
TARGET display that was intentionally switched during restore, causing
it to undo its own work.

Example: restore to display 2 space 3 → code switches display 2 from
space 2 to space 3 → detector sees "display 2 changed from 2 to 3" →
switches it back to space 2 → window is now on invisible space.

Now skips the target display (record.sourceYabaiDisp) in the detector,
only checking non-target displays for accidental CGEvent side effects.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"`
