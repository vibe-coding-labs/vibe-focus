# VibeFocus 健壮性增量加固路线图

背景：2026-09-06「副→主水波」回归复盘。修复本身早已真机验证，但用户按 ⌃Q 时
装机二进制已被并行会话用不含修复的旧基线覆盖；随后并行会话的安装实验又两度毒化
TCC 授权行（checkbox=1 但运行时拒绝），`move_to_main` 静默失效数小时才被感知。
这两类问题都不是"某个函数写错了"，而是**缺环境守卫与缺不变量锁**。

## 原则（为何不整体重写）

「每次优化总是出新 bug」的根因不是代码太烂需要推倒，而是每次改动只验证了改动的
happy path，没有锁住"别的东西不许变"。所以加固方式是：

1. **不动核心编排逻辑**——moveWindowToFrameViaYabai / FrameConvergence / toggle
   决策这些已真机验证的路径，只加观测和测试锁，不做行为等价的重写（重写本身就是
   最大风险源）；
2. **每次加固留下三类产物**：不变量测试锁（镜像 + Runner 真身双锁）、运行时信号
   （日志/诊断可读）、环境守卫（让部署/授权 drift 在 1 分钟内暴露而非数小时）;
3. **每批全门禁 + 真机闭环后才合 main**（swift build 零警告 / run_all_tests /
   VibeFocusTestRunner / ⌃Q 双向真机断言）。

## Batch 1（已落地，robustness/hardening-batch1）

- **构建能力标记自检**（BuildCapabilities.swift）：六个关键修复各对应一个二进制
  标记串，启动 logDiagnostics 恒开一行 `Build capabilities: ...`，`--diagnose`
  新增报告段。装机被旧构建覆盖时启动即知，不再靠 grep 考古。
  *新增关键修复落地时必须同步登记标记，否则 drift 不自检可见。*
- **AX 授权运行期翻转监控**（WindowManager.hasAccessibilityPermission）：
  授权状态翻转立即 WARN + UserDefaults 落账，`--diagnose` 报告「运行期翻转 N 次」。
  鉴别坑：shell 裸跑的 `--diagnose` 因 TCC 归属不可信，授权真值看运行实例的
  `axResizeUnreliable` / flip 日志。

## Batch 2（下一批：outcome 契约统一）

- `moveWindowToFrameViaYabai` 返回 false 时各调用方的处置审计：restore 路径
  frameOK=false 后 record 是否保留（重试机会）还是消费（数据丢失）——当前行为
  用 Runner 断言锁定；
- `verifyAndCorrectPostMoveSize` 与 `moveWindowToFrameViaYabai` 的容差常量统一
  出口审计（防止两处 tolerance 漂移 reintroduce 量化不收敛 bug）；
- `axResizeUnreliable` 首轮即 unreliable 时跳过 AX 直走 yabai（省一次无效
  waitForPhase，~100ms/次）。

## Batch 3（部署守卫自动化）

- keepalive-wrapper 启动时对比 sidecar 记录与二进制标记集，MISSING 即系统通知
  （不只日志——今天的教训是没人看日志）；
- run.sh 安装后自检：安装产物标记集 == 构建前源码期望集，不等则报错不装。

## Batch 4（环境互踩守卫）

- 并行会话部署互斥：安装路径 flock（`/Applications/VibeFocus.app.install-lock`），
  第二个 run.sh 等锁或明确报错，杜绝 pkill 大战；
- TCC 行守护：检测到自身被 tccutil reset（AX true→false 翻转）时，通知栏提示
  用户按指纹，而不是等下一次 ⌃Q 失败。

## Batch 5（决策表全分支锁定）

- Toggle mode 路由（move_to_main / restore / move_to_secondary_stuck / fallback）
  的决策输入→输出表：镜像测试穷举 + Runner 真身抽查，任何新分支必须先加表行
  再写代码。
