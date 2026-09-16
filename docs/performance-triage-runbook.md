# 性能排查手册：证据链五步法（B182 固化）

> 目标：任何性能问题复现时，**不靠猜测、不靠运气**，按固定流程拿到完整证据链，
> 直接定位瓶颈代码。本手册固化 2026-09-12 打字卡顿/页面卡顿事故（B178~B180）
> 中验证过的方法论与工具链。

## 证据链五步法

```
症状 → ①拉停顿时间线 → ②读归因行 → ③查量化分布 → ④定位代码 → ⑤修复前后同窗口对比
```

### ① 拉停顿时间线（有没有问题、多久一次）

```bash
grep '\[PERF\]\[STALL\]' ~/Library/Logs/VibeFocus/vibefocus.log | tail -20
```

- 每行 = 一次主线程停顿：WARN ≥250ms / ERROR ≥1s（阈值定义见
  `PerfMonitor.stallWarnSeconds/stallErrorSeconds`）。
- `deltaMs=` 字段 = 停顿时长；同一停顿每增长 ≥1s 续报一次（阶梯），
  **行数 ≠ 停顿次数**，看时间戳间距判断是否同一段阻塞。
- 主线程停顿 ≡ 用户可感知卡顿（气泡打字、页面操作全部冻结）——
  这是唯一需要盯的信号，无需猜测「是不是网络/后台」。

### ② 读归因行（卡在谁身上）

一条 STALL 行的结构：

```
[PERF][STALL] main thread blocked 2.31s
  sections=[hook.Stop session=abc12345(1.9s) > move.toMain(1.9s)]   ← 当时活跃的区间栈（父子链）
  top=[move.toMain×12 max=1.9s avg=0.8ms]                           ← 自启动累计计数器 Top3
  journal=[+[..]M ▶hook.Stop | +[..]M ▶move.toMain | ...]           ← 主线程最近的操作轨迹
```

| 字段 | 含义 | 用法 |
|---|---|---|
| `sections=[...]` | 停顿瞬间未结束的区间（主线程的排最前） | 直接指向卡住的代码路径 |
| `top=[...]` | 计数器 top（次数/max/avg） | 判断「每次都慢」还是「偶发尖刺」 |
| `journal=[...]` | 主线程最近轨迹（▶开始 ✓结束） | `sections=0` 时唯一的行为证据 |
| `main stack (...)` | ≥1s 停顿附带的主线程调用栈（独立一行） | 根因级证据：卡在哪个函数 |

区间名 → 代码位置对照（grep 区间名即可跳到埋点处）：

| 区间 | 代码 |
|---|---|
| `hook.request` / `hook.<event>` | `ClaudeHookServer+Request.swift`（hook 事件编排） |
| `move.toMain` | `WindowManager+MoveWindow.swift`（Stop 拉主屏） |
| `restore` | `ToggleEngine+Restore.swift`（UPS 归位） |
| `hook.bind` | `HookEventHandler+SessionStart.swift`（会话绑定） |
| `availability.refresh` | `SpaceController.swift`（20s 节流可用性探测） |
| `overlay.refreshIndices` | `ScreenOverlayManager+Refresh.swift`（角标刷新） |
| `space.switch` | `SpaceController+Switch.swift`（capsule/救援切空间） |
| `minimap.refresh` | `SettingsView+TerminalGridSection.swift`（编排页重建） |
| `spool.replay` / `.deferred` | `RemoteSpoolDrain.swift`（远程事件回灌） |
| `toggle` | `WindowManager+Toggle.swift`（⌃Q） |
| `grid.create` | `TerminalGridController.swift` |
| `registry.purge` | `SessionWindowRegistry+State.swift` |
| `bubble.summon/hide/submit` | `InputBubbleController*.swift` |
| `restore.lookup/queryWindow/preSwitch/move/guard/tail/failure` | `ToggleEngine+Restore*.swift`（B190 restore 子阶段） |
| `toggle.ctx` / `toggle.decision` | `WindowManager+Toggle.swift`（B190 三级焦点解析 / 决策子阶段） |
| `bubble.followTick` / `bubble.voiceYield` / `bubble.draftSave` | `InputBubbleController.swift`（B190 气泡 5Hz 跟随拍 / 1Hz 让位扫描 / 草稿同步段；journal 静默） |
| `shell.<bin>` / `shell.main.<bin>` | `ShellRunner.swift`（B190 每次 fork 常开计数；`.main.` 中段 = 主线程 fork） |
| `refreshGridMinimap` 等 | 见 `grep -rn beginSection Sources/` 全表 |

B190 起另有独立告警行（不必等 250ms 停顿看门狗兜底）：

```
[PERF][FORK-ON-MAIN] ... executable=/opt/homebrew/bin/yabai args=query ... durationMs=635
```

ShellRunner 在主线程 fork 且 ≥100ms 就打一行 WARN（逐次留痕），同一次 fork 同时计入
`shell.main.<bin>` 直方图。「主线程 fork 了没有、谁 fork 的、典型多久」直接 grep
这一行 + 看快照 `shell.*` 计数器。注意：legacy `P-INST-*` 日志（slow fork /
CGWindowList slow 等）在 `#if PERF_INSTRUMENT` 后面，**装机 release 构建不开**
（run.sh `swift build -c release` 无 `-DPERF_INSTRUMENT`）——生产证据链只认
PerfMonitor 常开埋点与这条 B190 告警行。

### ③ 查量化分布（典型 vs 最差）

```bash
cat ~/Library/Logs/VibeFocus/perf-snapshot.json | python3 -m json.tool
# 或一条命令出报告（含直方图/停顿历史/主线程轨迹）：
~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys --diagnose
```

每个区间计数器带直方图桶 `<10 / 10-50 / 50-200 / 200-1k / ≥1k ms`：

- `max=2s` 但 200+ 桶只占 2/40 → 偶发尖刺，查尖刺时刻的环境（yabai 忙？风暴？）；
- 200+ 桶占比 >50% → 系统性慢，查代码路径本身。

### ④ 定位代码（顺藤摸瓜）

1. 拿到区间名/栈符号 → grep 区间名进埋点处 → 沿调用链读代码；
2. `main stack` 行的符号可用 `atos -o VibeFocus.app.dSYM/Contents/Resources/DWARF/VibeFocusHotkeys -l <load地址> <栈地址>` 精确到行（栈行已给 `二进制+0x偏移`，load 地址取相邻日志或 `vmmap`）；
3. 若 `sections=0` 且 journal 也无异常 → 主线程卡在无埋点系统调用——此时
   调用栈采样是唯一证据，直接读栈。

### ⑤ 修复前后同窗口对比（闭环）

修复前记录「N 分钟内 STALL 计数 + 涉事区间分布」，修复装机后跑同样的观察窗：

> 实例（B179→B180）：修前 2 分钟 15 次 STALL（availability.refresh 1.4~2.4s×N +
> hook 移动 807ms+）；修后 25 分钟 0 次，真实 Stop 移动 807ms / UPS 归位 496ms
> 全程零 STALL。两次观察窗同为自然流量，对比成立。

## 自测工具（验证监控活着）

```bash
# 人为让主线程阻塞 1.5s（装机 app 内触发）→ 应立刻看到：
#   [PERF][STALL] main thread blocked ~1.5s ... journal=[...]
#   [PERF][STALL] main stack (N frames): <符号化调用栈>
echo 'import Foundation
DistributedNotificationCenter.default().post(name: Notification.Name("com.vibefocus.app.perf-stall-test"), object: nil)' | swift -
```

## 历史案例（方法论实证）

1. **每 20s 卡 1~3s（B179 发现）**：STALL 归因 `availability.refresh` →
   代码定位 refreshAvailability 主线程同步双 yabai fork → B180 后台化 → STALL 归零。
2. **打字卡死（B179 量化）**：历史日志 durationMs 分布 → UPS 归位 34/35 次 >200ms、
   与提交节奏重合 → B180 移动链下放 WindowWorkExecutor 串行队列 → 零 STALL。
3. **sections=0 之谜（B179 装机初期）**：STALL 无区间归因 → 当时机型无 journal/栈采样
   （B182 补齐）→ 若复现，journal + main stack 直接给出主线程行为。
4. **「仍然偶发卡顿」（2026-09-15，B190 取证）**：装机日志 34 条 STALL + 快照直方图
   → `toggle`（⌃Q）41 次里 40 次落 200ms~1s 桶（max 1.77s）、`restore`（气泡提交
   autoRestore）31 次里 29 次同桶（max 3.19s）；两条 ≥1s 的 `main stack` 采样都指向
   `ShellRunner.run → dispatch_semaphore_wait`——**手动 toggle 与气泡提交 autoRestore
   仍按 B180 设计决策同步跑在主线程**（B180 只下放了 hook 路径），每次 yabai fork
   200~700ms、restore 全链 3~7 次 fork 叠加出 0.3~2.3s 主线程冻结。取证同时发现
   两个监控自身缺陷：journal 环被 0.5~5Hz 周期区间 13 秒刷满（▶ 轨迹全是
   refreshIndices/followTick，停顿前真迹丢失）+ legacy P-INST 慢 fork 日志编译开关
   未开（生产全瞎）。B190 处置：journal 静默名单 + ShellRunner 常开 fork 计数 +
   FORK-ON-MAIN 告警行 + restore/toggle 子阶段区间。**B191 修复（2026-09-16）**：
   手动 toggle（async 化，重核心 performToggleCore 下放 WindowWorkExecutor，
   主线程只留 overlay 挂起/恢复 + 前台/崩溃快照读取）与气泡提交 autoRestore
   （Task + executor，B180 hook UPS 同款）双双下放后台串行队列；toggle 族五个
   extension 摘除 @MainActor、MoveCooldownRegistry 加锁（B180/B191 后读写不再
   天然串行）、语音播报单点跳主线程。验收=合成 ⌃Q 往返 + 零 STALL/FORK-ON-MAIN。

## 设计约束（改代码前必读）

- 所有埋点**零编译开关、常开**：`PERF_INSTRUMENT` 是 debug 工具，生产证据链不依赖它；
- 看门狗临界区只做字典读写，**锁内绝不做 IO/日志之外的重活**（防死锁）；
- 栈采样：suspend 窗口内不调用 dladdr（死锁风险），符号化在 resume 后异步执行；
- 新增埋点 = `PerfMonitor.shared.beginSection/endSection` defer 配对 +
  `PerfMonitorLogic` 纯层断言入 `Tests/Runner/RunnerPerfMonitorTests.swift`；
- 高频周期区间（≥0.5Hz）必须进 `PerfMonitorLogic.journalQuietSections` 静默名单，
  否则 64 条 journal 环十几秒被刷满、停顿归因丢失真迹（B190 教训）。
