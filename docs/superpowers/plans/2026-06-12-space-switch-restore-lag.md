# Optimization: 主屏退回副屏（restore）卡顿消除

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 消除"主屏退回副屏"切换时的卡顿，将 restore 后的主线程 yabai 阻塞从 ~900ms（SIGUSR1 风暴）降到 ~300ms（单次 refresh），用户感知卡顿从 ~1.5s 降到 ~800ms。

**Architecture:**
- 数据流：用户按热键 → `toggle()` → `restore()` 执行 yabai `window --space` → yabai 触发 `space_changed` signal → shell 脚本发 SIGUSR1 → `ScreenOverlayManager` 收到 → `triggerForceRefresh` → 3 次 force refresh（每次对所有 screen fork 2 个 yabai）。
- 关键组件：修改 `WindowManager+Toggle.swift`（toggle 入口加 suspend/defer-resume）、`ScreenOverlayManager.swift`（降低 follow-up 次数 + 定时器频率）。
- 设计理由：restore 路径本身受 [[feedback_toggle_restore_fragility]] / [[space_switch_regression]] / [[project_space_restore_bug]] 记忆铁律约束**不能动**；卡顿的主要感知来自 restore 期间及之后 SIGUSR1 触发的 overlay 刷新风暴（机制 B），这是纯显示层、可安全优化的部分。复用已有的 `suspendAutomaticRefreshes` / `resumeAutomaticRefreshes` / `triggerForceRefresh` 机制，零新逻辑。

**Current Baseline:** restore 路径 toggle 总耗时 ~600ms - 2500ms（波动，受 SIGUSR1 插队影响），其中 restore 本体 ~500ms + SIGUSR1 风暴 ~900ms + 多屏定时器叠加。
**Target:** restore 本体 ~500ms（不变）+ 单次 force refresh ~300ms（替代风暴），总计 ~800ms，且消除 2s+ 异常 spike。
**Gap:** SIGUSR1 后主线程阻塞从 ~900ms → ~300ms（-67%），消除 2s+ spike。
**Bottleneck:** `ScreenOverlayManager+Signal.swift:36-52`（`scheduleSignalFollowUpRefreshes` 3× refresh）+ `ScreenOverlayManager.swift:31,37`（常量）。

**Tech Stack:** Swift 5（SwiftPM），macOS AppKit，yabai，@MainActor 隔离，swift-testing（992 测试）。

**Scope:** Small
**Risk:** Medium（触及 toggle 入口和 overlay 刷新，但完全不碰 restore/Space 移动执行路径）

**Autonomy Level:** Full

**Risks:**
- Task 1 修改 `toggle()` 入口，若 suspend 后未 resume 会导致 overlay 永久停止刷新 → 缓解：用 `defer` 保证 resume 必执行。
- Task 2/3 降低刷新频率可能导致 overlay 显示短暂滞后（space 切换后 overlay 数字更新慢）→ 缓解：保留 SIGUSR1 立即 refresh + 单次延后 follow-up，覆盖空间切换；定时器仅作兜底，SIGUSR1 是主驱动。
- restore 内部的 yabai `window --space` 会触发 SIGUSR1，suspend 期间该信号被 `triggerForceRefresh` 的 `guard !automaticRefreshSuspended` 拦截（line 55-58）→ resume 后由 Task 1 的 `triggerForceRefresh` 补一次，确保 overlay 最终正确。

**安全铁律（不可违反）：**
1. **禁止修改** `ToggleEngine.restore()` 及其调用链（`SpaceController.moveWindow` / `focusWindow` / `setWindowFloat` / `queryWindow` / `currentSpaceIndex` / `checkScriptingAdditionLoaded`）的执行逻辑。
2. **禁止** 在 restore 路径添加坐标验证 guard（[[feedback_toggle_restore_fragility]]）。
3. **禁止** 跳过 Space 移动（[[space_switch_regression]]）。
4. **只优化** overlay 显示层（`ScreenOverlayManager`）和 toggle 入口的 suspend/resume 编排。

---

### Task 1: toggle 期间 suspend overlay refresh，结束 defer resume + 单次 refresh

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:10-14`（toggle 开头，clearQueryCache 之后加 suspend + defer）
- Modify: `Sources/Window/WindowManager+Toggle.swift:149-151`（toggle 结尾，clearQueryCache 保留，defer 自动处理 resume）

这是核心修复，最高收益：restore/move 期间所有 SIGUSR1 触发的 force refresh 被 suspend 拦截（省去 18 fork 风暴），结束由 defer 保证 resume 并补一次单次 refresh（6 fork，正确更新 overlay）。

- [ ] **Step 1: 在 toggle 开头 suspend overlay 自动刷新 + 注册 defer resume**

文件: `Sources/Window/WindowManager+Toggle.swift:10-14`

在 `SpaceController.shared.clearQueryCache()` 之后、`let frontBefore = ...` 之前插入 suspend + defer。替换后的完整区块：

```swift
        let op = operationID ?? makeOperationID(prefix: "toggle")
        let startedAt = Date()
        // 清除查询缓存，确保本次 toggle 获取最新状态
        SpaceController.shared.clearQueryCache()
        // 暂停 overlay 自动刷新：restore/move 内部的 yabai `window --space` 会触发
        // space_changed signal → SIGUSR1 → force refresh 风暴（多屏 3 次 × 每 screen 2 fork
        // = 大量主线程阻塞，是"主屏退回副屏"卡顿的主因）。toggle 期间抑制，结束后补一次。
        ScreenOverlayManager.shared.suspendAutomaticRefreshes(reason: "toggle_in_progress op=\(op)")
        // defer 保证：无论 toggle 如何退出（含提前 return / 异常），overlay 刷新都会恢复。
        defer {
            ScreenOverlayManager.shared.resumeAutomaticRefreshes(reason: "toggle_complete op=\(op)")
            // 补一次 force refresh，替代被抑制的 SIGUSR1 风暴 —— 单次 refresh 覆盖最终 space 状态。
            ScreenOverlayManager.shared.triggerForceRefresh(reason: "toggle_complete op=\(op)")
        }
        let frontBefore = frontmostAppDescriptor()
        updateCrashSnapshotFromRuntime()
        logRuntimeStateSnapshot(context: "toggle_start")
```

- [ ] **Step 2: 确认 toggle 结尾的 clearQueryCache 与 defer 共存（无需改动，仅验证）**

文件: `Sources/Window/WindowManager+Toggle.swift:149-151`

当前代码（保持不变）：
```swift
        // toggle 结束后清除缓存
        SpaceController.shared.clearQueryCache()
    }
```

执行顺序验证：`clearQueryCache()`（line 150）执行 → 函数返回 → `defer` 块执行（resume + triggerForceRefresh）。顺序正确，clearQueryCache 先于 resume，无冲突。

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 质量门禁 — 编译 + 全量回归 + 整洁检查**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - swift build: "Build complete!"
  - swift test: 无 FAIL，测试数 ≥ 992（与基线一致）
  - `grep -n "suspendAutomaticRefreshes\|resumeAutomaticRefreshes" Sources/Window/WindowManager+Toggle.swift` 返回 2 行（suspend + defer 内 resume）

**手工检查（AI 自行验证）：**
- [ ] defer 块成对存在（suspend 之后立即 defer resume）
- [ ] 未修改 restore/moveWindow/Space 移动相关任何代码（安全铁律 1-3）
- [ ] 无遗留 debug 语句

- [ ] **Step 5: 提交**

Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(toggle): suspend overlay refresh during toggle to eliminate SIGUSR1 fork storm

restore/move 内部的 yabai window --space 触发 space_changed signal → SIGUSR1
→ 3× force refresh 风暴（多屏 18 fork ~900ms 主线程阻塞），是主屏退回副屏
卡顿的主因。toggle 期间 suspend，结束 defer resume + 单次 refresh 替代风暴。

完全不触及 restore/Space 移动执行路径。"`

---

### Task 2: SIGUSR1 follow-up refresh 从 3 次降到 2 次

**Depends on:** Task 1（Task 1 已覆盖 restore 路径的 SIGUSR1；此 Task 优化 toggle 外的手动 space 切换场景，如用户手动切 space / 焦点变化）
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:31`（`signalFollowUpRefreshDelays` 常量）

`triggerForceRefresh` 会立即做一次 force refresh，再按 `signalFollowUpRefreshDelays = [0.03, 0.1]` 调度 2 次 follow-up，共 3 次。3 次是过度补偿 —— space 切换后 yabai 状态在 ~150ms 内稳定，单次延后到 180ms 的 follow-up 足够覆盖。

- [ ] **Step 1: 修改 signalFollowUpRefreshDelays 为单次延后 refresh**

文件: `Sources/Overlay/ScreenOverlayManager.swift:31`

```swift
    // 单次延后 follow-up：space 切换后 yabai 状态需 ~150ms 稳定，180ms 后补一次即可。
    // 原值 [0.03, 0.1] = 3 次 refresh（立即 + 30ms + 100ms），过度补偿导致主线程 fork 风暴。
    let signalFollowUpRefreshDelays: [TimeInterval] = [0.18]
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 质量门禁 — 编译 + 回归 + 整洁**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - swift test: 无 FAIL
  - `grep -n "signalFollowUpRefreshDelays" Sources/Overlay/ScreenOverlayManager.swift` 返回 1 行，值为 `[0.18]`

- [ ] **Step 4: 提交**

Run: `git add Sources/Overlay/ScreenOverlayManager.swift && git commit -m "perf(overlay): reduce SIGUSR1 follow-up refreshes from 3 to 2

原 [0.03, 0.1] 触发 3 次 force refresh（立即 + 30ms + 100ms），多屏每次 6 fork
共 18 fork 风暴。改为 [0.18] 单次延后 refresh，space 切换稳定后补一次足够。"`

---

### Task 3: 多屏兜底定时器从 0.8s 降到 2.0s + 最终 benchmark 对比

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:37`（`multiScreenFallbackRefreshInterval` 常量）

SIGUSR1（Task 1/2 优化后）已是 workspace switch 的主驱动；`multiScreenFallbackRefreshInterval` 定时器仅作兜底（检测 signal 遗漏）。0.8s 过于激进，空闲时持续 fork yabai 挤占主线程。2.0s 足够覆盖 signal 遗漏场景。

- [ ] **Step 1: 修改多屏兜底定时器间隔**

文件: `Sources/Overlay/ScreenOverlayManager.swift:37`

```swift
    // 多屏兜底定时器：SIGUSR1 是 workspace switch 主驱动，定时器仅兜底 signal 遗漏。
    // 0.8s 过激进（空闲时持续 fork yabai），2.0s 足够覆盖遗漏场景。
    let multiScreenFallbackRefreshInterval: TimeInterval = 2.0
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 质量门禁 — 编译 + 全量回归 + benchmark 对比**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - swift test: 无 FAIL，测试数 ≥ 992

**Benchmark 前后对比（从 `~/Library/Logs/VibeFocus/vibefocus.log` 提取）：**

| 指标 | 优化前（基线） | 优化后（目标） |
|------|--------------|--------------|
| restore toggle durationMs（正常） | ~600ms | ~500-600ms |
| restore toggle durationMs（含 SIGUSR1 插队 spike） | ~2500ms | ~600-800ms（消除 spike） |
| restore 后 100ms 内主线程 yabai fork 数 | ~18（3× force × 6） | ~6（单次 force × 6） |
| restore 后主线程阻塞 | ~900ms | ~300ms（-67%） |

部署后手动验证（用户侧）：
- 在主屏按热键 restore 回副屏 → 观察是否仍有明显卡顿
- 检查日志 `toggle finished durationMs` 应 < 800ms（原 WARN 阈值 650ms，新基线应稳定低于）

- [ ] **Step 4: 部署 + 验证（完整 app bundle + code signing）**

Run: `bash scripts/install.sh 2>&1 | tail -5 && open /Applications/VibeFocus.app`
Expected:
  - install 成功（[[vibefocus_deploy_workflow]]：禁止 swift build + cp 热部署）
  - open 启动应用（[[vibefocus_deploy_restart]]：不要让应用处于关闭状态）
  - 应用启动后 `tail -n 20 ~/Library/Logs/VibeFocus/vibefocus.log` 包含 "ScreenOverlayManager initialized"

- [ ] **Step 5: 提交**

Run: `git add Sources/Overlay/ScreenOverlayManager.swift && git commit -m "perf(overlay): slow multi-screen fallback timer from 0.8s to 2.0s

SIGUSR1 是 workspace switch 主驱动，兜底定时器仅需覆盖 signal 遗漏。
0.8s 在空闲时持续 fork yabai 挤占主线程，2.0s 足够且减少空闲时主线程阻塞。"`

---

## 部署后验证清单（用户手动确认）

完成 Task 1-3 后，请用户验证：
1. **核心场景**：窗口在主屏，按热键 restore 回副屏 → 应明显比之前流畅（消除 2s spike）
2. **overlay 正确性**：切 space 后 overlay 显示的 space 数字是否正确更新（验证 Task 1 的 defer refresh + Task 2 的 follow-up 没有漏更新）
3. **空闲稳定性**：长时间不操作，overlay 不闪烁、不丢失（验证 Task 3 的 2.0s 定时器兜底有效）
4. **日志检查**：`grep "toggle finished" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10` → durationMs 应稳定 < 800ms

如 overlay 出现滞后或丢失（极小概率），回滚 Task 2/3（恢复 `[0.03, 0.1]` 和 `0.8`），Task 1 可保留（suspend/resume 是纯增益）。
