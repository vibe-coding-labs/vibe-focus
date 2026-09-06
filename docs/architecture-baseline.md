# 架构耦合基线（2026-09-06，重构进度可度量记录）

> 目的：把「高内聚、低耦合」从口号变成可度量、可追踪的数字。每次结构性重构批次
> 合并后更新本文件。对照：`docs/quality-plan-2026-09.md`（并行立项的质量计划，
> 本文件聚焦窗口移动管线的内聚/耦合维度）。

## 纯函数内核（已提取，双锁覆盖）

窗口移动管线的「决策」与「执行」分离进度——决策层必须是无 IO、无 Actor 隔离的
纯函数，Execution 层（WindowManager）只做编排：

| 模块 | 职责 | 镜像测试 | 真身 Runner |
|---|---|---|---|
| `CoordinateKit` | 坐标换算/漂移和/收敛判定 | ✓ QuartzConversionTests 等 | ✓ |
| `WindowSettle` | 等待时长常量唯一事实源 | ✓ WindowSettleTimingTests | ✓ |
| `FrameConvergence.writeOrder` | 两段写序决策（收窄/放大/clamp/源屏先行） | ✓ FrameWriteOrderTests | ✓ |
| `FrameConvergence.convergeFrame/convergeFramePolling` | 收敛循环唯一骨架（停滞重发） | ✓ FrameConvergenceLoopTests | ✓ |
| `FrameConvergence.shortfalls` | 偏差维判定唯一事实源（Batch 2 新增） | ✓ FrameResendPlanTests | ✓（含与 CoordinateKit 交叉验证） |
| `FrameConvergence.resendSegments` | 补发段序列决策（Batch 2 新增） | ✓ FrameResendPlanTests | ✓ |

## Batch 3 度量（refactor/frame-write-executor）

- 新增 `Support/FrameWriteExecutor.swift`（150 行）：两段写入的阶段顺序、阶段等待、补发执行从 WindowManager 抽出为可注入编排值——deps 注入 read/move/resize 择优/resize 最稳四通道，决策全部委托 FrameConvergence，等待与预算常量取自 WindowSettle；
- `WindowManager+MoveWindow.swift`：547 → 491 行，`moveWindowToFrameViaYabai` 仅剩「解析 → 构造 deps → 执行 → 汇总日志」四段；内联 `waitForPhase` 与收敛轮询循环从编排层消失；
- **apply 调用序列断言**（此前不可测）：Runner 注入假 IO 驱动 5 场景 12 断言——满意路径两写序、size 单缺补发走择优通道、全缺计划走 robust yabai 按写序、停滞重发重复同一计划且计入 resend、不收敛如实上报 mismatched；
- 执行器不做 standalone 镜像（编排属执行域），其纯决策部分由 FrameConvergence 镜像锁定——测试按「决策镜像锁 + 执行真身锁」分层。

## Batch 2 度量（4b1834e）

- `WindowManager+MoveWindow.swift` 内联补发决策（4 分支 originOK/sizeOK 开关 +
  双处 wait/收敛判据）→ 收敛为 `FrameConvergence.shortfalls/resendSegments`
  两个纯函数，调用点 3 处等价替换（行为逐分支保持，含「全缺走裸 yabai」的
  历史细节）；
- 「缺哪维 → 补哪段 → 什么顺序」从 1 处不可单测的内联闭包变成 2 个可穷举单测的
  纯函数：新增 11 项镜像断言 + 12 项真身断言（含与 `CoordinateKit` 公式交叉验证，
  防两处公式单边漂移）；
- 内联漂移算式在 `WindowManager+MoveWindow.swift` 的出现次数：3 → 0（全部经
  `shortfalls` 走唯一出口）。

## Batch 4 度量（refactor/batch4-purity）

- 纯度约定统一第一步：`CoordinateKit` 的四个收敛判据函数（originDrift/sizeDrift/
  isSizeConverged/isFrameConverged）标 `nonisolated`（纯数学、无 AppKit 触碰），
  枚举级 @MainActor 保留给 NSScreen 读取类成员；
- `FrameConvergence.shortfalls` 删除 Batch 2 的漂移公式内联副本，改直连
  CoordinateKit——漂移公式回到全仓唯一事实源；Runner 与 CoordinateKit 的交叉
  验证保留，角色从「抓两处公式漂移」降级为「回归金丝雀」；
- 纯度约定成文：纯数学函数一律 nonisolated，AppKit 触碰函数留在 MainActor 域。

## Batch 8 度量（refactor/restore-sequence-lock）

- restore 主体的全部决策核心此前已纯化并分支锁定（sourceSpacePreSwitch /
  switchSourceSpace / refocusPerspective / isMoveFailureRetryable / FloatSettle），
  唯余 `performRestore` 集成层的**阶段顺序**没有断言——preMoveSpace 必须先于
  4-pre 采集（漏采把切换后的 space 当基准、漏切回用户视角）等契约仍只活在注释。
  本批给四类假依赖接上共享 `RestoreSeqLog`，用 4 个全序断言把顺序钉死：
  - S1 happy + 4-pre 切回 + 守卫成功：16 步全序（load→lookup→query→current→
    visible→focus→visible→预取→float→清缓存→move→current→focus→清缓存→clear→审计）；
  - S2 最小化快检失败：query 后立即短路（视角/float/move/clear 零发起）；
  - S3 move 失败屏内 → retryable：失败路径同样守卫先行、record 保留；
  - S4 屏外 clamp 重试仍败 → permanent：审计后才 clear（record 生命周期终点）；
- **move/restore 对称性复查**（逐维核对，同源即同一函数/同一原语）：

| 策略维度 | move_to_main | restore | 同源 |
|---|---|---|---|
| float 脱管+等重摆 | FloatSettle（管线内） | FloatSettle（4a） | ✓ |
| 跨屏 frame 写+收敛 | moveWindowToFrameViaYabai（FrameWriteExecutor） | 同左 | ✓ |
| 补发计划 | shortfalls/resendSegments | 同左（同一函数实例化） | ✓ |
| 源上下文捕获时机 | captureSpaceContext 排首（管线断言） | record 于 toggle 入口捕获 | 语义对称 |
| 原始帧快照时机 | knownOrigFrame 先于 apply（管线断言） | record.origFrame（同源捕获点） | ✓ |
| 查询缓存失效 | FloatSettle 恒清 | FloatSettle 恒清 + 守卫成功清 | ✓ |
| 视角逐卫 | 无（frame 直写不改可见 space 归属） | 4-pre + 成功/失败共用 runPerspectiveGuard | 刻意不对称 |
| 序列断言 | Runner 场景 A~J（Batch 7） | Runner 场景 S1~S4（本批） | ✓ 对称完成 |

  唯一刻意不对称 = 视角逐卫：move_to_main 的直写不改任何屏的可见 space，restore
  必须精确落回 sourceSpace（SA 直切/聚焦带动双层）；已有 branch 穷尽锁定。

## Batch 9 度量（refactor/arch-conformance）

- 新增 `Tests/Standalone/ArchitectureConformanceTests.swift`（架构守护测试，
  8 检）：把 Batch 1~8 建立的**单出口不变量**变成 run_all_tests 的机械断言——
  静态扫描 Sources/ 全部代码行（注释行跳过），9 条规则 = 「禁止模式 + 合法
  消费文件白名单」：
  - R1/R2：waitForRelayout 调用与 floatRelayoutSettleMicros 消费只许
    FrameConvergence/WindowSettle/FloatSettle（Batch 6 单出口 + budgetMs 单位
    bug 的源头封堵）；
  - R3/R4/R7：setWindowFloat、原始 yabai float 切换、查询缓存失效的白名单
    （TerminalGrid 投递是文档化的刻意旁路）；
  - R5：AX frame 写（size/position 属性复合匹配，title/focus 写放行）只许
    写原语与 post-check 重写兜底；
  - R8/R9/R10：FloatSettle/MoveToMainPipeline/FrameWriteExecutor 的合法接线
    点清单——新增调用点必须显式改白名单，让「谁在绕过唯一出口」在 diff 里
    可见；
- 检测器自测锁定（命中白名单外/放行白名单内/放行 title 与 focus 写/R8 抓
  第三处手抄）——守门者自己被证明能抓违例；
- 现状 9 规则零违例 = Batch 1~8 的出口纪律当前无一处漂移，且此后任何新手抄
  会在 run_all_tests 当场爆掉，不再依赖注释自觉。

## 当前热点（后续批次目标，按优先级）

1. `WindowManager+MoveWindow.swift` 547 行——仍是编排+段执行+日志混合体；
   Batch 3 目标：把「两阶段写入 + 补发」抽成 `FrameWriteExecutor`（注入
   applyMove/applyResize 执行器与 read 闭包，决策全部走 FrameConvergence），
   编排层降到 <300 行；
2. `WindowManager` extension 族 22 文件共享隐式时序契约（float→写→收敛→
   post-check→save）——阶段化完成三刀：float 段 = `FloatSettle` 唯一序列原语
   （Batch 6）；两段写入 = `FrameWriteExecutor`（Batch 3）；move_to_main 主编排 =
   `MoveToMainPipeline` 阶段管线（Batch 7，见下）——顺序契约已从注释升级为
   Runner 假 IO 调用序列断言；
3. 判定/工具函数的 @MainActor 隔离与纯函数化不一致（CoordinateKit MainActor、
   FrameConvergence 非隔离）——统一约定：纯数学函数一律非隔离（Batch 4 完成）；
4. 移动管线对 `cgWindowBounds`（全局函数）的直接依赖 7 处/文件——Batch 3 已
   收敛到执行器注入，残余在 FloatSettle 接线闭包（单点）。

## Batch 7 度量（refactor/move-to-main-pipeline）

- 新增 `Support/MoveToMainPipeline.swift`（279 行）：move_to_main 六段混排
  （capture→解析→origFrame 快照→skip 检查→settable→apply→post-check→save）
  从 `moveWindowToMainScreen` 抽为全依赖注入的阶段管线——阶段顺序、提前返回、
  双路径（P2 yabai 预 float / AX apply 前 float）各只 float 一次的契约由
  Runner 假 IO 调用序列断言锁定（场景 A~J + skip 纯决策 K，30 检）；
- 历史事故的时序契约变成可断言不变量：a049a86（origFrame 必须先于 apply 快照，
  P2 路径 `readAXFrame` 禁止被调用）、2026-09-01 尺寸错乱（float 先于 apply）、
  sourceSpace 必须先于一切写捕获（capture 排首）——各由专门断言锁定；
- `WindowManager+MoveWindow.swift`：470 → 306 行，`moveWindowToMainScreen`
  剩「started 日志 → 通道接线 → 结局分发 + 汇总日志」三段；全部日志文本逐字
  保留（stage 锚点与失败日志一一对应）；
- 诊断字段小修：finished 日志 `floatMs` 在 AX 路径从写死 300（Batch 6 等稳定化
  后已失真）改为 FloatSettle 实测耗时；P2 路径语义不变（=p2SpaceMoveMs）；
- skip 纯决策 `isAlreadyMaximizedOnMain` 镜像锁定（8 检，含短路求值保真：
  mainScreen 只在 display==1 时才查询，与拆分前惰性一致）；
- 顺带修复：`ToggleEngine+Restore.swift` Batch 6 潜伏的未使用结果警告（全新
  缓存整编译才暴露），零警告门禁恢复严格。

## Batch 6 度量（refactor/float-settle）

- 新增 `Support/FloatSettle.swift`：「float 脱管 → 等重摆落定 → 查询缓存失效」
  唯一序列原语。此前 5 处手抄（Layout.floatAndWriteFrame、move_to_main P2、
  move_to_main AX、stuck 解堵、restore 4a）语义已漂移成三类：等待策略两档
  （4 处 waitForRelayout 轮询 vs restore 固定 usleep 300ms）、缓存失效三档
  （仅 toggle 清 / 恒清 / 从不清）——「改一处漏四处」的活体样本，本批次起
  五处调用点收敛为一行原语调用，契约由测试锁定而非注释；
- **顺带逮出并修复一个真实生产 bug**：`waitForRelayout` 的 `budgetMs` 形参以
  毫秒计，五处手抄均直传微秒值 `floatRelayoutSettleMicros`（300_000）——
  「300ms 预算」实为 300 秒，frame 永不稳定的病理路径下轮询 30 万拍 ≈ 100
  分钟挂死热键。镜像测试 C 场景（永不稳定走满预算）比对断言时暴露，修复为
  `budgetMs: 300`（其文档契约），Runner 增加回归金丝雀断言锁死换算；
- 统一语义裁决（记录在案）：缓存失效取「恒清」档（内存字典清空零成本，漏清
  的代价是下游 queryWindow 吃到 float 前旧值）；restore 等待从固定 300ms 升级
  为 waitForRelayout（下限 120ms 防静默假稳定 + 两读稳定早返回 + 300ms 预算
  兜底），全仓 float 等待策略回到一档；
- 测试：新增镜像 `FloatSettleSequenceTests`（17 断言：序列顺序/零浪费跳过/
  预算兜底/容差接线/读失败不终止）+ Runner 真身 8 断言 + 真机 E2E
  （`VIBEFOCUS_FLOATSETTLE_E2E=1`，真实 iTerm2 测试窗：真 toggle 157~164ms
  有界落定 + isFloating 翻转 + 等待后两读稳定；已 float 零耗时跳过）；
- **FloatSettle 全链路无 AX 依赖**（yabai fork + CGWindowList + 内存缓存）——
  真机闭环不再被辅助功能授权状态卡死（2026-09-06 AX 授权反复被并行构建毒化
  期间的质量门底座）；
- 手抄 float→settle 序列在 WindowManager/ToggleEngine 族的出现次数：5 → 0；
  `WindowManager+MoveWindow.swift` 491 → 470 行。
