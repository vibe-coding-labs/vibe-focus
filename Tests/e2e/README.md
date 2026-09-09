# 真机 E2E 归口（窗口链路改动的验收入口）

> 立项：docs/quality-plan-2026-09.md P2。窗口移动/摆位逻辑的**真机行为**无法用
> Standalone 镜像测试覆盖（依赖双屏、yabai、AX、焦点），必须跑本目录登记的
> 真机 E2E。环境变量开关式设计，Runner 统一入口：`.build/debug/VibeFocusTestRunner`。

## 用例清单（动窗口逻辑必跑）

| 环境变量 | 覆盖 | 前置 |
|---|---|---|
| `VIBEFOCUS_SIZE_E2E=1` | 跨屏移动尺寸保真：放大序/缩小序跨屏直写（Δ=0）、完整 toggle 往返（主屏适配↔副屏原帧还原）、stuck 解堵尺寸保持、restore 屏外 origFrame 夹取还原、move_to_main 路由直呼 | 双屏环境、iTerm2、yabai |
| `VIBEFOCUS_FLOATSETTLE_E2E=1` | FloatSettle 唯一序列原语：真 toggle 有界落定 + isFloating 翻转 + frame 稳定；已 float 零浪费跳过（Batch 6，全链路无 AX 依赖） | yabai、iTerm2 |
| `VIBEFOCUS_GRID_SPACE_E2E=1` | 网格 Space 定向投递（跨屏往返送达目标 space） | 双屏 + 多 space、iTerm2、yabai |
| `VIBEFOCUS_GRID_TARGET_E2E=1` | 网格目标屏编排 | 双屏、iTerm2/Terminal |
| `VIBEFOCUS_GRID_E2E=1` | Terminal 网格全流程（真实建窗 + claude 会话） | 主屏有带存活 claude 会话的终端窗口 |
| `VIBEFOCUS_TITLE_E2E=1` | 终端标题定向改名（Ctrl+T 链路）：tty 寻址命中自建会话、写入生效、双端自关清理 | iTerm2、Terminal、yabai |

> B56 起 E2E 用例代码分布在 `Tests/Runner/Runner*E2E*.swift`（`RunnerHarness` 的
> extension，如 GRID_TARGET→RunnerGridTargetE2ETests.swift）；新增 E2E = 新建域
> 文件 + 在 `RunnerHarness.runAllTests()` 按序登记，main.swift 只放 harness。

## 标准跑法

```bash
swift build -c debug
VIBEFOCUS_SIZE_E2E=1 VIBEFOCUS_DB_PATH=/tmp/vibefocus-size-e2e.db \
  .build/debug/VibeFocusTestRunner
```

- **TCC 身份稳定（2026-09-10 实测教训）**：`swift build -c debug` 产物默认 ad-hoc
  签名且标识符内嵌构建哈希——每次新 .build = 新 TCC 身份，历史 Automation 授权
  全部失效，表现为建窗类用例恒 FAIL（ShellRunner 返回 nil →「无法启动 osascript」，
  实为 iTerm2 AppleEvent 未获授权/不响应）。跑 E2E 前先用本机证书重签一次：

  ```bash
  codesign --force --sign "VibeFocus Local Code Signing" .build/debug/VibeFocusTestRunner
  ```

  证书身份跨构建稳定，授权一次长期有效。
- **DB 隔离**：必须以 `VIBEFOCUS_DB_PATH=/tmp/…` 注入（启动时快照环境变量，进程内
  setenv 无效），避免与真机实例的快照库互扰。SIZE_E2E 会持久写 toggle record，
  跨次运行复用同一 DB 文件属于预期（record 按 windowID 隔离）。
- **清理语义**：测试窗口经 iTerm2 session `write text "exit"` 关闭，best-effort——
  iTerm2 对不可见 space 会话的退出有 10-30s 滞后，窗口最终自动关闭，不算失败。

## 红线与注意事项

1. **同机互斥（实测 + 机制化）**：两个会话同时跑 toggle 类 E2E 会互撞——yabai re-tile
   会把对方的 float 测试窗口弹回原位、焦点被对方抢走，表现为用例间歇 FAIL、重跑即绿。
   Runner 已内建互斥锁（P5）：任一 `*_E2E=1` 启动取 `/tmp/vibefocus-e2e.lock`（mkdir
   原子，>10min 陈锁自动回收），并发第二个直接拒跑（退出码 3）——收到该提示说明
   另一会话的 E2E 在跑，错峰即可；确认无 E2E 在跑可 `rm -rf` 该锁目录后重试。
2. **测试窗口只碰自建的**：E2E 以 yabai 窗口表差集追踪本run创建的窗口，清理只对
   差集操作——严禁按 id 范围/名称猜删（会误删用户窗口）。
3. **真机验收要求**：动窗口行为的变更，单测/构建全绿不算验收，E2E + 真机操作
   闭环才算（见用户验收要求 memory/AGENTS 约定）。
4. **GRID_E2E 额外要求静默机器**：其前置是「主屏存活 claude 会话的终端窗口」，
   会重排**真实**终端窗口——用户正在工作时不跑（会动用户会话的窗口）。
5. **GRID_TARGET_E2E 容差是环境敏感的**（2026-09-07 回归扫实测，拆分前后同样
   失败）：Terminal.app 窗口 frame 按字符行高量化，规划像素格与实际落点的
   ≤4px 收敛在当前 Terminal profile 下不保证——失败先对照本条，换行高无关
   的 profile 或放宽量化感知容差属网格域决策。

## 何时必须跑

- 改 `WindowManager+MoveWindow/AXWrite/Toggle+Routes/Toggle+Decision` 等移动写帧路径 → SIZE_E2E
- 改 `ToggleEngine+Restore / RestoreSwitchOrchestration` → SIZE_E2E（重点 clamp/toggle 往返）
- 改 `TerminalGridController / Grid*` → GRID_SPACE_E2E（+ GRID_TARGET_E2E 若动编排目标）
- 改 `SpaceController` space 通道 → GRID_SPACE_E2E + SIZE_E2E 双跑

## 布局变更回归记录（2026-09-08，双 1920×1080 副屏在主屏上方三屏布局）

显示器索引几何精确匹配（Batch 34）落地后的首次全量真机回归：

- **SIZE_E2E 885/885**、**GRID_SPACE_E2E 873/873**、**FLOATSETTLE_E2E 879/879** 全绿；
  SIZE/GRID_SPACE 同批修复了三处 P40UG 时代硬编码坐标与 GRID_SPACE setup 的
  猜序残留（用例改从当前副屏可视区动态推导，后续换布局不应再坏）。
- **TITLE_E2E 875/876**：iTerm2 建窗 AppleEvent 持续超时（-1712，手工 90s 长超时
  同样超时；iTerm2 当时 41+ 窗口高负载）——环境受限，非代码回归（创建步在
  被测写入逻辑之前，iTerm2 模板由镜像+Runner 锁定）。Terminal case 全绿。
  **E2E 跑 TITLE 前先确认 iTerm2 可响应建窗 AE**（`tell app "iTerm2" to count
  windows` 快，建窗慢/超时即环境不就绪）。


## 回归记录（2026-09-10 凌晨，本周修复批后：UPS 回原位语义/决策表记录门/LAN 重绑定/信号广播/minimap 标签）

- **SIZE_E2E 1114/1114 全绿**：restore 引擎、toggle 往返、跨屏直写在全部本周改动后健康。
- **GRID_SPACE_E2E 1099/1102（3 FAIL）→ 根因已定位，1166/1166 全绿**：失败点=建窗
  第一步 osascript 挂起 20-120s 后超时。**真凶（2026-09-10 实测闭环）= iTerm2 的
  「A session ended very soon after starting」告警框**：E2E 清理语义（`write text
  "exit"`）的快速退出会话恰好触发该告警框，而它开着时 iTerm2 对一切**建窗**
  AppleEvent 不响应（查询类秒回，建窗挂起 2 分钟+超时）——与代码无关。处置：
  关掉告警框后重跑，1166/1166 一次全绿（含本周全部改动）。跑前检查：屏幕上是否
  有该告警框；`osascript -e 'tell application id "com.googlecode.iterm2" to create
  window with default profile'` 秒回=环境就绪，挂起=先关框。
- **FLOATSETTLE_E2E 1139/1139 全绿（2026-09-10 补跑，证书签名 runner）**。
- **GRID_TARGET_E2E 1139/1143（4 FAIL，环境敏感先例复现）**：失败全部落在像素级
  收敛断言（落规划区内/≤4px 收敛/顶行保留区 ≤2px/二次直中），结构性断言全过
  （创建/双窗/displayID/共边 ≤2px/贴缘/定向非主屏/二次创建）——与下方 2026-09-07
  注记同因：Terminal.app frame 按字符行高量化，≤4px 收敛不保证；放宽容差属网格域决策。
- **基建发现**：debug runner ad-hoc 签名导致 TCC 身份随构建哈希漂移——已改证书签名
  （见「标准跑法」TCC 身份稳定节），授权一次长期有效。
