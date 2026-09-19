# 覆盖率豁免台账（发布验收口径 · 正式清单）

> **口径裁决**（用户 2026-09-20 选定）：发布门槛 = **① CLI 可提缝面单测 100%** + **② 真机域每块 E2E 通道全绿** + **③ 物理不可达行在本台账逐项归因**。
> 字面意义的 llvm-cov 100.00% 不作验收要求（一小部分代码在单测通道内物理不可执行，见 C5）。
>
> 测量工具：`bash Scripts/coverage_test_runner.sh`（llvm-cov，插桩构建+全量 Runner）。
> Sources 纯净口径自算：`llvm-cov report … | grep '^Sources/'` 后按 Lines 列加权（全口径报告含 Tests 行数会虚高）。
> 刷新命令：跑完覆盖率脚本后对照本台账逐行核对；**每条豁免必须有替代验证通道，否则不得豁免**。

## C1 生命周期胶水（启动编排，单进程内不可重入）

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| AppDelegate.swift `applicationDidFinishLaunching` 全链 | ~200 | 重入即重复启动 hook server/keepalive/定时器，进程内无法隔离 | 生产日常启动即验证；`--diagnose` 报告冒烟 |
| AppDelegate+Instance `findExistingInstance` 双实例分支 | ~10 | 需第二个同 bundleID 运行实例 | 单实例锁 flock 语义已单测（B245 注入三态） |

## C2 真实模态弹窗（CLI runModal 挂死）

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| AppDelegate+Instance `showWrongLocationAlert` | ~20 | NSAlert.runModal 阻塞 CLI | 错误位置判定分支已单测；弹窗文案真机人工核对 |
| AppDelegate+Menu `presentGridResultIfNeeded` | ~8 | 同上（失败告警框） | 网格成功路径已有真机 E2E（GRID_SPACE/TARGET） |

## C3 系统授权交互（会拉起系统 UI / 提权）

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| WindowManager+Menu? `notifyAccessibilityPermissionRequired`（beep+打开系统设置） | ~15 | NSSound.beep + NSWorkspace.open 拉起系统设置真窗 | AX 授权翻转记账/自愈决策表已单测；真机授权流人工验收 |
| SpaceController+Recovery `requestScriptingAdditionLoad`（admin 提权弹框） | ~24 | adminWaitsForUser 同步等提权框 | SA 状态机纯函数+load/record 全族已单测（B225） |
| SpaceController+SARecoveryAdmin 提权 osascript 路径 | ~90 | osascript with administrator privileges 真提权 | 状态机闸门已单测；SIP 死路生产实证（永久 blockedBySIP） |
| AXSelfHeal detached 看护自拉起路径 | 部分 | spawn 独立看护进程 | relaunchScript 生成物已单测；真机掉授权自愈闭环已人工验收（2026-09-07） |

## C4 发声 / 音频播放

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| SoundManager `startPlayback` 家族 | ~40 | 真实出声打扰用户 | resolveSound 加载链已单测（B248 并行批）；静默门已单测 |
| VoiceAnnouncementManager `preview`/TTS 播报出声路径 | ~60 | 同上（AVSpeech/NSSpeechSynthesizer 真发声） | announceCompletion 门 0/队列/模板纯函数已单测；真机人工试听 |
| VoiceAnnouncementManager+LLMSummary 网络编排出声段 | 部分 | 依赖真实 LLM 请求 + 出声 | prompt 构造纯函数已单测（B216） |

## C5 物理不可达（单测通道内无法执行，永久豁免）

| 文件 / 函数 | 近似行数 | 原因（实证） | 替代验证 |
|---|---|---|---|
| CrashSignalHandler `crashSignalHandler` 真身 | ~70 | 末尾 `signal(SIG_DFL)+raise` 一执行即杀进程；async-signal-safe 约束使内部逻辑无法拆桩 | 双缓冲写/读缝已单测（B251）；FATAL 行格式由归档文件真机对账 |
| CrashSignalHandler `installAtExitHandler` 回调体 | 部分 | 仅进程退出时执行，Runner 退出即终止测量 | 注册动作本身幂等不崩已烟测 |
| BacktraceSampler `sampleMainThread` / `captureMainThreadPortOnLaunch` | ~40 | thread_suspend 主线程自采样在测试套件内僵死（跨批次全局态互踩，B230 事故） | 符号化纯函数已单测；生产崩溃归档实测可用 |
| GCD DispatchSourceSignal 投递路径（SpaceController 信号链） | ~30 | CLI 进程结构性不投递（B234 探针实证，解释/编译二进制、主/全局队列均不 fire） | 信号 → 状态迁移逻辑以直调等价函数锁定；生产 SIGUSR1 机制真机验证（B162） |

## C6 渲染树绑定（脱离 SwiftUI 渲染树求值必崩，SIGTRAP 实证）

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| SettingsView+TerminalGridSection `terminalGridSection` 本体 | ~40 | gridMinimapHeartbeat（TimerPublisher/SubscriptionView）body() 必崩（B229） | 同文件 gridMinimapPanel/refreshGridMinimap/gridTargetSummary 已单测（B249）；真机设置页人工验收 |
| LANSettingsView body 各段（drainer @ObservedObject） | ~51 | SubscriptionView body() 同类崩溃 | spoolDrain 纯逻辑/drainNow 语义由 RunnerSpoolDrain* 锁定；真机设置页人工验收 |
| SettingsView hotKeySection / inputBubbleSection（@EnvironmentObject） | ~30 | 脱离渲染树访问 EnvironmentObject 崩溃（B229） | 热键显示/匹配逻辑已单测；真机人工验收 |
| SettingsView+SessionLists 深层列表段 | 部分 | sessionRegistry → 生产 DB 打开（生产三源库禁写纪律） | Registry 临时库全通道已单测（B230）；真机人工验收 |

## C7 生产状态禁写（写了会污染运行中生产实例）

| 文件 / 函数 | 近似行数 | 原因 | 替代验证 |
|---|---|---|---|
| PerfMonitor `startHeartbeatOnMain` / watchdog 线程 / 心跳循环 | ~60 | while-true 线程 + RunLoop timer 污染测试进程（家法禁令） | measure/record/begin-end/纯函数族已单测；[PERF][STALL] 生产日志真机实证 |
| RemoteSpoolDrain 网络排水路径（drainNow/tick 真发） | ~80 | 需翻 claudeHook 真实 defaults——生产 app 实时读取同一 standard 域（B247 并发污染根因） | spool 落盘/重放预算/生命周期已单测；远程双机转发 E2E 已人工闭环（B123/B124） |
| HookEventHandler handleStop/handleUserPromptSubmit 执行段 | ~110 | 委托真实建窗/移动热路径（B242 裁决：收益 ~100 行 vs 热路径写入侧风险，不值） | 门 0/守卫分支已单测；restore 链真机 E2E 已绿 |

## 真机 E2E 通道矩阵（口径②的覆盖面）

| 通道 | 环境变量 | 状态 |
|---|---|---|
| 跨屏移动尺寸保真 | `VIBEFOCUS_SIZE_E2E=1` | ✅ 既有，真机绿 |
| FloatSettle 序列 | `VIBEFOCUS_FLOATSETTLE_E2E=1` | ✅ 既有，真机绿 |
| 网格 Space 投递 | `VIBEFOCUS_GRID_SPACE_E2E=1` | ✅ 既有，真机绿 |
| 网格目标屏编排 | `VIBEFOCUS_GRID_TARGET_E2E=1` | ✅ 既有，真机绿 |
| 终端标题定向改名 | `VIBEFOCUS_TITLE_E2E=1` | ✅ 既有，真机绿 |
| HotKey 三件套（Carbon/tap/monitors） | `VIBEFOCUS_HOTKEY_E2E=1` | ✅ B244 通道就位 |
| **AXWrite 编排层** | `VIBEFOCUS_AXWRITE_E2E=1` | ✅ **B253 新建，真机绿**（B252 号被并行线占用） |
| 气泡真面板域 | 待建 | ⬜（ summon/提交管线，需真面板自动化） |
| SessionRestore 真恢复域 | 待建 | ⬜（restore 链已有真机人工闭环，待 env 门控自动化） |

## 签字

- [ ] 口径②剩余通道建成（气泡面板 / SessionRestore）
- [ ] 豁免条目复核（逐条确认替代验证通道有效）
- [ ] 发布前全量 E2E 一轮 + 门禁三绿 + 本台账对照刷新

（签署区：用户 / 负责会话，发布前填写）
