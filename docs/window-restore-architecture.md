# 窗口恢复架构文档（2026-09-02 重写，与代码同步）

> 本文档描述**当前**实现。旧版机制（switchDisplayToSpace / CGEvent 方向键 /
> `window --space` / NativeSpaceBridge.moveWindow / WindowManager 内存变量恢复路径）
> 已于 2026-08-31~09-01 全部删除，任何按旧文档描述修代码的会话都会修错地方——
> 这正是历史上恢复功能反复回归的结构性原因之一。

## 功能是什么

用户在多显示器环境下工作。VibeFocus 的 toggle 功能把终端窗口从副屏搬到主屏（方便看），恢复功能把它搬回副屏原位——**恒为「切回原工作区」语义**：窗口回源屏 sourceSpace，用户视角不跟随（留在原 display）。

> 历史注：设置页曾有「恢复策略」（切回原工作区 / 拉到当前工作区）Picker，
> 其中「拉到当前工作区」从未被消费（纯死设置），已于 2658da5 下线。
> 恢复行为自始至终只有一种：切回原工作区。

```
1. 窗口在副屏 Display 2, Space 3, 位置 (3200, 200)
2. 用户按 Ctrl+Q → 窗口被搬到主屏最大化，原始位置存入 SQLite ToggleRecord
3. 用户按 Ctrl+Q（或 hook 触发）→ 恢复：窗口搬回 Display 2, Space 3, (3200, 200)
```

## 恢复的唯一执行入口

```
WindowManager.toggle()（入口：热键/菜单栏）
  → evaluateRestoreDecision()     决策：焦点窗口在主屏 + 有效 ToggleRecord → .restore
  → WindowManager.restore()       仅做窗口识别（windowID 由 toggle 入口传入），不做执行
  → ToggleEngine.restore()        唯一执行体（Sources/Toggle/ToggleEngine+Restore.swift）
```

hook（UserPromptSubmit 等）**不触发 restore**——hook 自动聚焦走的是
`moveWindowToMainScreen`（把窗口拉到主屏），方向与 restore 相反（0f0a3bc）。

## ToggleRecord 里恢复依赖的字段

toggle 搬运时由 `captureSpaceContext`（移动前！）捕获、`ToggleEngine.save` 写入 SQLite：

| 字段 | 含义 | 恢复时的用途 |
|------|------|--------------|
| `windowID` / `pid` | 窗口身份 | 按 windowID 直接定位（无 PID fallback 链） |
| `origFrame` | 源屏上的原始位置（Quartz 全局坐标） | frame 直写的目标 |
| `sourceSpace` | 窗口原来在哪个 Space（yabai 全局索引，0=无信息） | 源屏预切回的目标 space |
| `sourceYabaiDisp` | 窗口原来在哪块屏（yabai 1-based） | 查该屏当前可见 space |
| `targetFrame` | 主屏上的位置 | `isValid` 数据校验 |

## ToggleEngine.restore() 的步骤（与代码一一对应）

1. **load record**（按 windowID，无则 `.aborted`）
2. **AX 窗口存在性**（窗口已关则 `.aborted`）
3. **yabai 窗口查询**（一次 fork，后续 float 复用）→ **最小化快检**：最小化窗口上
   float/--move 全部静默无效，快速失败 `.moveFailedRetryable`（record 保留），
   避免白白切换源屏视角
4. **preMoveSpace 基准**：记录当前 focused space（供第 6 步视角守卫）
5. **源屏预切回（spaceExact 的关键）**：源屏当前可见 space ≠ sourceSpace 时，
   双层切回 sourceSpace（是否切/初始 spaceExact 由 `sourceSpacePreSwitch` 纯函数裁决）：
   ① `canControlSpaces` 为真先 `focusSpace`（SA 直切，**不依赖源 space 上有窗口**，
   源 space 已空也能精确切回）；② 直切失败/不可用降级 `refocusWindowOnSpace`
   （聚焦带动，偏好非最小化候选，不依赖 SA）。切回命令成功后用
   `ConditionPolling.waitUntil` **等到位**：轮询源屏可见 space 真切回（800ms 预算，
   `ignoreCache` 绕过查询缓存），早满足早返回，超时如实 `spaceExact=false`。
   两层全失败（SA 失效 + 源 space 空，物理极限）→ `spaceExact=false`，窗口将落在
   源屏可见 space（位置恢复但 space 不精确），结局如实上报，不静默。
   > SA 可用性由无副作用探针实测（`saProbeVerdict`）：对当前 space 发
   > `space --focus`，按 stderr 分类裁决——旧「query 含 display 字段」判据在 v7
   > 恒真（query 不依赖 SA），2026-09-02 E2E 实测揭穿后重写。
6. **float 脱管**：仅在真发生 `--toggle float` 时等 300ms 重摆落定
   （已 float 的窗口无重摆，不等待——restore 常见路径恰是已 float）
7. **frame 直写**：`yabai --move abs` + `--resize abs` 写 origFrame，写后读回验证
   （2 轮，每轮 400ms 落定）。macOS 窗口归属跟随物理位置自动回源 display。
   > 为什么不用 `window --space`：yabai v7 float 布局下静默失效
   > （exit 0 但窗口不动，Tests/AXMoveValidation.swift T3 实测）。
8. **结局裁决（诚实结局，2026-09-02）**：
   - frame 收敛 → 清 record + 审计 `restore_success`（含 `spaceExact` 字段）→ `.restored`
   - frame 未收敛且 origFrame 仍在某块现有屏 → **保留 record** +
     审计 `restore_move_failed`(reason=frame_not_converged, recordKept=true)
     → `.moveFailedRetryable`（用户再触发一次即重试）
   - frame 未收敛且 origFrame 已不在任何屏（断显/分辨率变更）→ **清 record** +
     审计 `restore_move_failed`(reason=orig_frame_offscreen, recordKept=false)
     → `.moveFailedPermanent`（下次 toggle 走 stuck 解堵兜底，避免热键空转）
9. **视角守卫**（成功与失败路径共用 `runPerspectiveGuard`）：focused space 被拖走时
   切回 preMoveSpace——先试 `yabai space --focus`（依赖 SA），失败则
   `refocusWindowOnSpace(preMoveSpace)`（排除被恢复窗口自身）
10. **结局播报（P1-1，WindowManager.restore 委托返回后）**：`RestoreAnnouncementPlan`
    把四类结局映射为固定文案 + 成败音效通道——语音走 VoiceAnnouncementManager 有界队列
    （不吃会话完成模板），失败音效固定 Basso；语音/音效两开关任一关闭即该通道静默；
    `.aborted` 无审计事件，不播报。历史上失败一片静默是「感觉有 bug 但日志全 success」
    的体感根源之一。

## 结局枚举（RestoreOutcome，唯一事实源）

| 结局 | record | 审计事件 | 用户可见行为 |
|------|--------|----------|--------------|
| `.restored(spaceExact)` | 清除 | `restore_success` | 窗口回源位；spaceExact=false 时日志 WARN |
| `.aborted(reason)` | 不动 | 无 | 无事发生（无记录/窗口已关） |
| `.moveFailedRetryable` | **保留** | `restore_move_failed`(recordKept=true) | 窗口留在主屏，再按一次即重试 |
| `.moveFailedPermanent` | 清除 | `restore_move_failed`(recordKept=false) | 窗口留在主屏，下次 toggle 走 stuck 解堵 |

**重试策略留档（P2-2）**：维持「单次不自动重试」——record 保留 + 用户再按即重试 +
结局播报告知。不引入自动重试循环：旧 RestoreWatchdog 自动重试风暴是历史事故根因
（110350a/59bfdb4 线索）。

## 已知能力边界（不是 bug，是 SA 失效环境下的物理极限）

1. **源 space 已空且 SA 失效**：聚焦带动通道（`refocusWindowOnSpace`）无窗口可聚焦、
   SA 直切又不可用，源屏无法切回 sourceSpace，窗口落在源屏当前可见 space。
   结局 `spaceExact=false` 如实上报。SA 可用时该场景已由 4-pre 第一层直切根治（P0-1）。
2. **SA 失效时 `space --focus` 不可用**：视角守卫与源屏预切回的第一层自动失效，
   降级「聚焦窗口带动」通道。检查 SA：`yabai --load-sa`（需 admin）。
3. **显示器热拔/分辨率变更**后 origFrame 可能落在屏外 → `.moveFailedPermanent`，
   record 清除属预期行为（stuck 解堵接管）。

## 回归防护

见 `docs/space-switch-regression-guard.md`（已同步重写为当前机制）。
纯决策逻辑由测试锁定（分支穷尽）：
- `Tests/XCTest/RestoreRefocusCandidateTests.swift`（Swift Testing）：selectRefocusCandidate /
  isMoveFailureRetryable / sourceSpacePreSwitch / RestoreOutcome 结局标签
- `Tests/Standalone/RestoreRefocusCandidateTests.swift`（过渡期门禁，`run_all_tests.sh` 消费，镜像同套逻辑）
- `Tests/Runner/main.swift`（`swift run VibeFocusTestRunner`，@testable 直测真实实现：
  双层切回编排 `RestoreSwitchOrchestration` 假通道注入分支穷尽 + 各纯决策；CLT-only
  环境无 Swift Testing 运行时的执行通道，覆盖率经 `scripts/coverage_test_runner.sh`
  产出 llvm-cov 真实数字——编排层/ConditionPolling 实测 100%）
- `Tests/AXMoveValidation.swift`（机制断言脚本，改移动机制前必跑）

## 涉及的文件清单（当前）

| 文件 | 职责 |
|------|------|
| `Sources/Window/WindowManager+Toggle.swift` | toggle 入口编排、三路分发 |
| `Sources/Window/WindowManager+Toggle+Decision.swift` | restore 决策（decideRestore 纯函数） |
| `Sources/Window/WindowManager+Restore.swift` | restore 前置识别 + 委托 + 结局映射 |
| `Sources/Toggle/ToggleEngine+Restore.swift` | **唯一执行体** + RestoreOutcome |
| `Sources/Toggle/ToggleEngine.swift` | record save/load/clear |
| `Sources/Toggle/RestoreSwitchOrchestration.swift` | 双层切回编排（通道 protocol 化可注入，llvm-cov 100%） |
| `Sources/App/VoiceAnnouncementManager+RestoreOutcome.swift` | 结局播报（RestoreAnnouncementPlan 纯决策 + 发声接线） |
| `Sources/Window/WindowManager+MoveWindow.swift` | toggle 搬运 + moveWindowToFrameViaYabai |
| `Sources/Window/WindowManager+MoveWindow+PostMove.swift` | post-move 校验 + record 保存 |
| `Sources/Space/SpaceController+Switch.swift` | refocusWindowOnSpace + 候选选择纯函数 |
| `Sources/Space/SpaceController+Move.swift` | setWindowFloat（FloatToggleOutcome） |
| `Sources/Support/WindowSettle.swift` | 落定等待时长唯一事实源 |
| `Sources/Support/FrameConvergence.swift` | 帧写入收敛循环唯一骨架 |
