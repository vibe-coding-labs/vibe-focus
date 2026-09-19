# 覆盖率台账：已测面 / 豁免面（2026-09-19）

> 快照：main 63.13%→64.03% 行覆盖（Runner 3185/3185），llvm-cov（`bash scripts/coverage_test_runner.sh`）。
> 本文档是「可测面推满 + C 档豁免」口径下的发布决策依据：未覆盖行不是遗漏，而是逐一归因后的
> 豁免（CLI 测试通道不可安全直测）或并行覆盖率线在攻目标。

## 汇总

- 冲刺起点（2026-09-19 勘误基线）：行 28.67%、函数 37.42%（Runner 2063）
- 当前：行 **64.03%**、函数 67.10%（Runner 3185/3185 全绿 + Standalone 全过 + 构建零警告）
- 当日完成批次：B214/B217/B218/B228/B229/B235/B237/B238/B239/B241/B242/B243/B244（13 批，本会话 12 批）
- 已验证测试通道五件：①SwiftUI 构建表达式求值（body 顶层，TupleView/SubscriptionView/.env 对象除外）
  ②注入缝+隔离 DB/env ③无窗口 NSView 状态机（合成 NSEvent）④本地 NWListener mock server 网络闭环
  ⑤偏好快照-改写-恢复
- 铁律（实测事故固化）：thread_suspend 主线程自采样僵死；@EnvironmentObject 脱离渲染树 SIGTRAP；
  TupleView/SubscriptionView body 调 .body 必崩；/bin/false 不存在于 macOS；push 管道退出码误删 worktree

## 豁免面分类（未覆盖行的逐一归因）

### C1 生命周期与 App 胶水（AppDelegate.swift 267 / +Menu 218 / +Instance 136 / AppEntry）
NSApplicationDelegate 生命周期、NSApp 激活策略、菜单构建依赖运行中的 app 对象。
验证通道：装机后手动冒烟 + 日志（exits.jsonl/VIBEFOCUS_VERBOSE_LOGS）。

### C2 真实弹窗与模态（SettingsWindowController.open、InputBubbleController.summon/showPanel/submit、
InputBubbleHistoryPanel.open/buildHeader、editTitle 的 NSAlert.runModal、showAutomationPermissionAlert）
orderFront/makeKeyAndOrderFront 真显示窗口并抢焦点（违背测试窗清场纪律）；NSAlert runModal 在
无 runloop 的 CLI 进程挂死。已测到边界：controller.close() 幂等、行视图/按钮状态机全流程。
验证通道：真机 ⌘B 唤起→输入→⏎ 提交→历史面板开关（既有真机 E2E 记录）。

### C3 系统授权交互（TitleEditor captureCurrentSessionTTY/captureTerminalFrontTabTTY 的 NSAppleScript
真执行、AX 成功路径、LoginItemManager.refresh 的 SMAppService XPC+AppleScript、openLoginItemsSettings、
setEnabled 真注册）
无授权 CLI 进程触发 macOS Automation 授权弹窗（打扰用户）或 XPC 查询；已测到 not_settable/
unsupported/幽灵 pid 等全部失败分支。提纯产出：loginItemPresentation(for:) 四态纯函数全锁。
验证通道：装机后真机 ⌃T 改名（AppleScript+AX+TTY 三路写已真机验收）。

### C4 发声与音频设备（SoundManager.startPlayback/stopPlayback/previewSound/resolveSound 执行段、
VoiceAnnouncementManager.speak/playAudioFile/announceCompletion/preview、summarizeAndSpeak fallback 链）
NSSound.play/NSSpeechSynthesizer 真发声会打断用户工作流（活跃期禁合成注入铁律）。已测到边界：
全局 .none 早退、playFailureSound .none 静默、soundResolutionPlan 解析计划全表、stopAll 幂等、
LLM prompt 纯函数+requestLLMSummary 网络四路径（mock server）。
验证通道：设置页试听按钮（用户自助 10 秒验证）。

### C5 生产状态写入（CrashContextRecorder.record/bootstrap/markCleanExit、WindowStateStore 生产 DB 写、
installCrashSignalHandlers/installAtExitHandler 的信号注册+fatal 文件、BacktraceSampler 采样器）
写生产崩溃状态文件会污染下次启动的崩溃恢复语义；thread_suspend 主线程自采样实测僵死（kill -9 收场）；
信号 handler 安装改变测试进程行为。已测到边界：parseIPS/captureTail/环形窗口/HostStatus/注册表注入缝/
drain 生命周期/PerfMonitorLogic 纯函数全表。
验证通道：崩溃取证手册（--diagnose 一键报告+exits.jsonl）。

### C6 渲染期机制（SwiftUIForEach/GridViewBuilder 闭包、嵌套 View body、Canvas 闭包、
ButtonStyleConfiguration.makeBody、GeometryReader content、SettingsTabBar.tabButton、
ScreenMinimapView 内层、SettingsView 各 section 渲染期段、InputBubbleHistoryPanel 行内容）
渲染期才执行的构建闭包，脱离渲染树不可达； TupleView/SubscriptionView body 调 .body 必崩
（B229 三铁律）。已测到边界：全部顶层构建表达式（B229 十一段+各组件 body）。
验证通道：装机后设置窗逐页目检（UI 回归走真机）。

### C7 真实会话操作（SessionRestoreController.restoreLayout/captureCurrentLayout、
TerminalGridController.createGrid、WindowManager+MoveWindow/Toggle/Layout 全家、
HookEventHandler+WindowMove+Execute、RemoteSpoolDrain startDrain/finishDrain、InputBubbleController+Submission）
真开窗/真移动/真键击注入/真 ssh 外呼——多会话生产环境必互扰（B125 乱蹦事故、合成注入误伤实测）。
决策表/门控/解析已提纯直测（ToggleEngine/ToggleDecision/GridTarget/SessionRestoreStore/SpoolDrain/
SubmitGate/AutoShow.decide 族），本段为薄编排层。
验证通道：真机 E2E（SIZE/FLOATSETTLE/GRID_SPACE/GRID_TARGET/HookWalk 历史全绿记录）+ 真实会话冒烟。

### 并行覆盖率线在攻（不重复开工）
Window/WindowManager+TerminalContext/Finding（B226 已入）、Hook 安装器（B221）、存储记账（B220）、
Toggle/restore 决策（B219）等——多线合流持续推高全景。

## 发布信心构成

1. 可测面：纯函数内核 + 决策表 + 注入缝编排全部直测（Runner 3185 断言 + Standalone 全过）；
2. C 档豁免面：每项有明确「为什么不能在 CLI 测」+ 对应真机验证通道；
3. 已知债务：并发 Runner 跨进程 UserDefaults 污染（remoteInstall/hookDispatch/screenPos 偶发红，
   复跑即绿）——建议冲刺收敛后统一补全 domain/defaults 注入隔离。

## 可测面清零确认（B246，2026-09-19）

对全部 Sources 做「0 覆盖函数」扫描（llvm-cov show 行级 func 过滤，排除 C1~C7 已归因文件）后确认：
剩余 0% 函数全部属于以下三类，不存在「可直测但未测」的漏网函数——
1. 真实窗口/会话操作（SpaceController+Move/Focus、WindowManager+Restore、SessionRestoreExecutor.deliver、
   TerminalGridController+Automation、InputBubbleController 弹窗依赖方法）→ C7，真机 E2E 通道；
2. 系统交互（YabaiClient fork 系、SpaceController+Recovery/SARecoveryAdmin 的 osascript/admin、
   Overlay 显示、WindowManager+AXRead/notifyAccessibilityPermissionRequired）→ C3/C5；
3. private 渲染辅助（SessionLists.refreshGeo/rowView/statusTint 等）→ C6。
SettingsView 各 section 的 func 级已清零（refreshSelectionInfo/runGridTask 归 C7/C2）。
可测面推满达成。后续增量策略：新增代码按五通道同步补测；并行线 window/bubble 主攻段并入后按本清单归因。
