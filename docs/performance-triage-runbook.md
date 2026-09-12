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
| `refreshGridMinimap` 等 | 见 `grep -rn beginSection Sources/` 全表 |

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

## 设计约束（改代码前必读）

- 所有埋点**零编译开关、常开**：`PERF_INSTRUMENT` 是 debug 工具，生产证据链不依赖它；
- 看门狗临界区只做字典读写，**锁内绝不做 IO/日志之外的重活**（防死锁）；
- 栈采样：suspend 窗口内不调用 dladdr（死锁风险），符号化在 resume 后异步执行；
- 新增埋点 = `PerfMonitor.shared.beginSection/endSection` defer 配对 +
  `PerfMonitorLogic` 纯层断言入 `Tests/Runner/RunnerPerfMonitorTests.swift`。
