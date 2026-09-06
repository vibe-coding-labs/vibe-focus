# 代码质量审计与夜间批次清单（2026-09-07 凌晨）

> 目标：高内聚低耦合 + 大文件拆分 + 逻辑重构 + 单测补齐。
> 与 docs/quality-plan-2026-09.md（P0~P7）衔接；本文件是执行层工作清单，每批完成后更新状态。

## 覆盖率基线（scripts/coverage_test_runner.sh，2026-09-07 实测）

- 全库 TOTAL：行覆盖 10.6%（6422 函数中 5741 未覆盖）、区域 10.85%。
- **口径说明（重要）**：Runner 单测（无环境变量默认模式）只能覆盖纯函数/可注入逻辑；
  编排类文件（AX/yabai/AppleScript 编排）天然 0%，由真机 E2E（VIBEFOCUS_*_E2E）验收。
  三条测试通道：Runner 直测（真实实现单测）/ Standalone 镜像（自包含）/ 真机 E2E（行为）。
- 高覆盖样例：ToggleEngine+Restore 94.8%（分支 100%）、TerminalGridPlanner 88.9%（分支 100%）、
  TerminalAutoRestorePlan 92.9%（分支 100%）——「纯函数内核分支 100% + 编排 E2E」模式成立。

## 文件规模 Top（>300 行）

| 文件 | 行数 | 状态/计划 |
|---|---|---|
| TerminalGrid/TerminalGridController.swift | 1055 | **B1 已拆**：→ 6 文件（主编排 266 + SpaceDelivery 168 + Restore 268 + Capture 127 + TargetResolve 136 + Automation 121），提取纯函数 tty 解析/捕获排序/恢复帧规划（去重 restore 与 autoRestore 重复块）+ 12 条 Runner 断言 |
| Window/WindowManager+MoveWindow.swift | 554 | 重构会话域（Batch 6/7 MoveToMainPipeline 已推进），避让，观察其后续 |
| Settings/SettingsView+TerminalGridSection.swift | 536 | B3 候选：UI 文件，拆 Tab/子视图 + 表单校验逻辑提纯 |
| App/SoundManager.swift | 515 | B2 候选：音效域（有 ProjectSoundResolverTests 基础），拆播放引擎/音效选择/工程解析 |
| Toggle/ToggleEngine+Restore.swift | 444 | 覆盖已 94.8%，P1 已收敛，暂不动 |
| Space/SpaceController+Recovery.swift | 402 | B4 候选：SA 状态机域，改前先补镜像测试 |
| Hook/ClaudeHookModels.swift | 381 | 已有 HookModelsFullTests，查缺口再定 |
| App/AppDelegate+MenuAndInstance.swift | 362 | B5 候选：菜单/单实例小而独立 |
| Settings/DesignSystem.swift | 351 | 色板 token 文件，内聚良好，不拆 |
| App/VoiceAnnouncementManager.swift + RestoreOutcome | 317+28 | 覆盖 59-75%，B6 候选：补缺口测试 |

## 纪律

- 每批次：独立 worktree → 拆分/重构 → 提纯逻辑补穷尽单测 → 三门禁（构建零警告 +
  Runner 全绿 + run_all_tests）→ 合并推送 → 本清单更新。
- 并行避让：重构会话域 = Window 编排（FrameWriteExecutor/FloatSettle/MoveToMainPipeline/
  阶段状态机）；本清单不动这些文件，B 前先 fetch 查 origin/main 近期提交。
- E2E 同机互斥锁（P5）在岗；动窗口行为的批次加跑对应 E2E。

## 批次台账

| 批次 | 内容 | 状态 |
|---|---|---|
| B1 | TerminalGridController 1055→6 文件 + 纯函数提取（parseWindowTTYMap/sortedByReadingOrder/restoreTargetFrames 去重）+ 12 断言 | ✅ 2026-09-07 |
| B2 | SoundManager 域审计与拆分/补测 | 待开工 |
| B3 | SettingsView+TerminalGridSection 拆分 | 待开工 |
| B4 | SpaceController+Recovery 镜像测试补齐 | 待开工 |
| B5 | AppDelegate+MenuAndInstance / VoiceAnnouncementManager | 待开工 |
