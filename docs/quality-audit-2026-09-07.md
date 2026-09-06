# 代码质量审计与夜间批次清单（2026-09-07 凌晨）

> 目标：高内聚低耦合 + 大文件拆分 + 逻辑重构 + 单测补齐。
> 与 docs/quality-plan-2026-09.md（P0~P7）衔接；本文件是执行层工作清单，每批完成后更新状态。

## 覆盖率基线（scripts/coverage_test_runner.sh，2026-09-07 实测）

- 全库 TOTAL：行覆盖 10.6%（6422 函数中 5741 未覆盖）、区域 10.85%。
- **2026-09-07 早晨复测：行覆盖 17.14%、区域 16.49%**（重构会话 Batch 11~17
  真身直测收口 + 夜间 B 系列后；剩余未覆盖为编排胶水/GCD/NSView 层，按三通道
  模型归真机 E2E 验收域）。
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

## 冲刺收官（2026-09-07 08:00）

- **覆盖率**：全库行覆盖 10.60% → **15.84%**（+49% 相对提升）；函数覆盖 6433 中新增 1000+ 可测函数入覆盖。
  B13~B18 六轮镜像转直测后，WindowMove+Decision 80.9%、ClaudeHookModels 80.8%（区域）、
  TerminalContext+Helpers 75%——提取单元函数级≈100%，编排路径由真机 E2E 家族验收。
- **Runner 直测断言**：278 → 534/534 全绿（+256 条，全部真实实现直测、零镜像漂移）。
- **结构**：1055 行巨石 → 六模块；编排页/提示音段拆分；恢复帧规划去重；模型与编排分层。
- **真 bug**：volume 必填解码静默重置用户偏好（单测先行实锤修复）。
- **死测试清理**：FocusStepsCalculationTests（镜像函数已从源码删除）。

## 批次台账

| 批次 | 内容 | 状态 |
|---|---|---|
| B1 | TerminalGridController 1055→6 文件 + 纯函数提取（parseWindowTTYMap/sortedByReadingOrder/restoreTargetFrames 去重）+ 12 断言 | ✅ 2026-09-07 |
| B2 | SoundManager 模型块拆出 SoundPreferencesModels（515→393）+ **实锤并修复 volume 必填解码潜伏 bug**（旧 JSON 静默重置用户偏好）+ 真实实现兼容解码 15 断言 | ✅ 2026-09-07 |
| B3 | SettingsView+TerminalGridSection 拆四文件（536→137/214/87/99）+ summaryText/selectionDetailText/steppedGap 提纯 + 13 断言 | ✅ 2026-09-07 |
| B4 | SA 恢复状态机真实实现测试补齐（recoveryVerdict 6 + autoRecoveryAllowed 冷静期矩阵 6 + saProbeVerdict 4 = 16 断言，Runner 直测优于镜像）| ✅ 2026-09-07 |
| B5 | VoiceAnnouncement 模板插值/队列策略转 Runner 直测（消镜像漂移，8 断言）；AppDelegate+MenuAndInstance 审计结论=纯菜单粘合无需拆分 | ✅ 2026-09-07 |
| B6 | ClaudeHookModels 数据契约真实实现 23 断言（payload 双事件键别名/session 别名+trim+空拒绝/嵌套 ctx snake_case；TerminalContext 五因子绑定判据+isRemote；Response snake_case 编码）| ✅ 2026-09-07 |
| B7 | Hook 窗移决策树 Runner 直测 20 断言（守护顺序逐条+边界：超龄阈值/pidMatches nil 容错；httpResponse 映射表 8+1）——路由唯一事实源消镜像漂移 | ✅ 2026-09-07 |
| B8 | Space 投递七分支决策表 Runner 直测 9 断言（含 nil 查询失败容错两分支）——+SpaceDelivery 文件从 0% 抬升 | ✅ 2026-09-07 |
| B9 | SettingsView+SoundSection 318→3 文件（85/119/110）+ SoundSectionText/规则兜底音效提纯 6 断言 | ✅ 2026-09-07 |
| B10 | SessionWindowRegistry 查找级联隔离库直测 6 断言（直命中/pid 有效者优先/别名通道/DB 兜底层实证/markCompleted 联动）——新 env 门控 VIBEFOCUS_REGISTRY_E2E=1（须配隔离 DB）| ✅ 2026-09-07 |
| B11 | 终端上下文匹配族（tty 归一/命令-标题匹配/ps basename/iTerm UUID/注入防御 allowlist）+ Claude 窗口定位两级策略，Runner 直测 18 断言 | ✅ 2026-09-07 |
| B12 | GridTargetCode.parse 全形态/非法输入 + TerminalSelectionResolver.resolve（手动优先/auto 频次/空回落）Runner 直测 9 断言 | ✅ 2026-09-07 |
| B13 | float 脱管决策（含惰性不触查询不变量）/refocus 候选选择/outcomeLabel 四分支/retryable/源屏预切三态，Runner 直测 18 断言 | ✅ 2026-09-07 |
| B14 | restore 结局→播报计划总映射 Runner 直测 10 断言（spaceExact 三态/文案 nil 语义/成败音效通道）| ✅ 2026-09-07 |
| B15 | Quartz/Cocoa y 互转 + MoveCooldownRegistry 冷却纯决策/剩余秒数取整 Runner 直测 7 断言（无记录→0 语义对齐实现）| ✅ 2026-09-07 |
| B16 | walkToTerminalPID 谓词注入行走直测 9 断言（起始即终端/上溯/深度上限/ppid≤1 断链/自环/深度防御 + 注册表静态集合）| ✅ 2026-09-07 |
| B16.5 | soundType 兜底接线修正——规则未选音效时 Picker/试听共用 effectiveSoundType 单一事实源 | ✅ 2026-09-07 |
| B17 | Hook 脚本生成器不变量直测 9 断言（hooks JSON 合法性+恒注册事件/远程安装脚本 host 插值与 machine_label 归一/helper 端口与上下文采集）| ✅ 2026-09-07 |
| B18 | YabaiErrorClassifier 直测 8 断言（六类别/大小写不敏感/多类命中优先级）| ✅ 2026-09-07 |
| B19 | 镜像存活审计：70 个 Standalone 逐符号核对，**删除 1 个死镜像**（FocusStepsCalculationTests 镜像的 calculateFocusSteps 已从源码删除，测试在测自己的副本）；其余存活 | ✅ 2026-09-07 |
| B20 | SettingsUI.swift（244 行 34 个 @State 状态枢纽）审计结论=拆分属高风险 SwiftUI 状态重构且无单测面，缓办并记录；AppDelegate+MenuAndInstance=纯菜单粘合无需拆分 | 审计完成 2026-09-07 |
| B21 | SettingsView+ClaudeHookSection 334→265+89（Codex 区段独立）+ CodexInstallPresentation 展示映射提纯 5 断言 | ✅ 2026-09-07 |
| B22 | LAN 远程绑定持久化 Runner 直测（env 门控）3 断言：set nil 丢弃/active 过滤/独立 defaults 域；旧字典迁移路径留镜像覆盖（同进程 UserDefaults 缓存语义不适合进程内断言）| ✅ 2026-09-07 |
| 备注 | Tests/XCTest/ 套件在 CLT 环境从未可执行（playbook 2.10），属死重——删除需用户裁决，暂留并记录 | 记录于 2026-09-07 |
