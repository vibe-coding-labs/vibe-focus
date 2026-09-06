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

## Batch 2 度量（refactor/move-resend-plan）

- `WindowManager+MoveWindow.swift` 内联补发决策（4 分支 originOK/sizeOK 开关 +
  双处 wait/收敛判据）→ 收敛为 `FrameConvergence.shortfalls/resendSegments`
  两个纯函数，调用点 3 处等价替换（行为逐分支保持，含「全缺走裸 yabai」的
  历史细节）；
- 「缺哪维 → 补哪段 → 什么顺序」从 1 处不可单测的内联闭包变成 2 个可穷举单测的
  纯函数：新增 11 项镜像断言 + 12 项真身断言（含与 `CoordinateKit` 公式交叉验证，
  防两处公式单边漂移）；
- 内联漂移算式在 `WindowManager+MoveWindow.swift` 的出现次数：3 → 0（全部经
  `shortfalls` 走唯一出口）。

## 当前热点（后续批次目标，按优先级）

1. `WindowManager+MoveWindow.swift` 547 行——仍是编排+段执行+日志混合体；
   Batch 3 目标：把「两阶段写入 + 补发」抽成 `FrameWriteExecutor`（注入
   applyMove/applyResize 执行器与 read 闭包，决策全部走 FrameConvergence），
   编排层降到 <300 行；
2. `WindowManager` extension 族 22 文件共享隐式时序契约（float→写→收敛→
   post-check→save）——契约目前只存在于注释；Batch 4 目标：阶段化枚举状态机，
   每阶段入口/出口用 Runner 断言锁定；
3. 判定/工具函数的 @MainActor 隔离与纯函数化不一致（CoordinateKit MainActor、
   FrameConvergence 非隔离）——统一约定：纯数学函数一律非隔离；
4. 移动管线对 `cgWindowBounds`（全局函数）的直接依赖 7 处/文件——Batch 3 一并
   收敛到执行器注入。
