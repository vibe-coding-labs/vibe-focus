# 覆盖率豁免台账（发布验收口径 · 正式清单）

> **口径裁决**（用户 2026-09-20 选定）：发布门槛 = **① CLI 可提缝面单测 100%** + **② 真机域每块 E2E 通道全绿** + **③ 物理不可达行在本台账逐项归因**。
> 字面意义的 llvm-cov 100.00% 不作验收要求（一小部分代码在单测通道内物理不可执行，见 C5）。
>
> 测量工具：`bash Scripts/coverage_test_runner.sh`（llvm-cov，插桩构建+全量 Runner）。
> Sources 纯净口径自算：`llvm-cov report … | grep '^Sources/'` 后按 Lines 列加权（全口径报告含 Tests 行数会虚高）。
> 刷新命令：跑完覆盖率脚本后对照本台账逐行核对；**每条豁免必须有替代验证通道，否则不得豁免**。
> ⚠️**门禁环境注记**（2026-09-20 B299 后补）：**显示器休眠会使 yabai v7.1.18 的全局聚合查询
> （`-m query --spaces` / `--displays`）确定性截断**（恒返 2 字节 `[` 且 exit 0；按 display 作用域
> 查询正常，唤醒即愈）→ Runner 的 spaceSwitch/spaceQY 两前置确定性红、另 11 个 yabai 依赖块
> 被跳过。**跑 VibeFocusTestRunner / 覆盖率管线前用 `caffeinate -d <命令>` 压住显示休眠**；
> 诊断顺序：`yabai -m query --spaces | wc -c` 等于 2 即中招，`caffeinate -u -t 2` 唤醒即恢复。
> 全绿实证：`caffeinate -d` 下 Runner **3596/3596 全绿**（f00da47）。

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


## B311 气泡模块冲刺新增豁免（2026-09-20，待签字）

> 背景：B311 将 Sources/Bubble 全模块从 64.5% 推至 **92.0% 行覆盖**（missed 457→104），
> Logic/Clipboard/ArrivalMover 三文件 100%。新增测试：RunnerBubbleSubmitPipelineTests（B310，
> 提交管线编排+观察缝）与 RunnerBubbleLifecyclePanelTests / RunnerBubbleCoverageSweepTests /
> RunnerBubbleCoverageTailTests / RunnerBubbleCoverageFinaleTests（B311，真面板生命周期+
> 历史面板全流程+视图渲染+AutoShow tick 编排，输入空闲门控）。以下为剩余 104 行的逐块归因：
>
> ⚠️ 环境注记：本轮测量的会话处于**登录屏**（loginwindow 持 SecureEventInput，跨进程 AX
> 恒 -25208、合成 HID 事件被丢弃）——AX 依赖路径按门控自动跳过，健康会话重跑覆盖率即
> 自动转绿（RunnerBubbleSubmitPipelineTests 的 axVerified/timeout 双场景，属门控非豁免）。

| 文件 / 函数 | 近似行数 | 原因（实证） | 替代验证 |
|---|---|---|---|
| InputBubbleController `summon` 焦点捕获链（focusedWindow/windowHandle/cgBounds/showPanel） | ~21 | AX 真实读取：登录屏 AX 全封锁；健康会话需真实终端前台+聚焦窗 | 真机 E2E（B129 闭环/B255 真面板通道）；日常使用 |
| InputBubbleController `summon` no-frontmost/ownApp 守卫臂 | ~8 | 前台 app 恒非 nil 不可造 nil；ownApp 需本 app 真前台（设置页试键场景） | 纯门 InputBubbleSummonGate 已穷尽直测；真机设置页试键人工验收 |
| InputBubbleController+Submission settle AX 验证主链（后台读+main 归决） | ~10 | 自有窗 AX 探针双场景（axVerified/timeout）已入 Runner，登录屏自动跳过=**门控非豁免**，健康会话重跑即绿 | RunnerBubbleSubmitPipelineTests |
| InputBubbleController+Submission autoRestore restore 分支（Task→ToggleEngine.restore 双结局臂） | ~24 | 需共享 SQLite windows 表实记录+实窗移动（C7 生产禁写归口） | ToggleEngine.restore 本体注入式穷尽直测（B157/B237 前批）；GRID_E2E 真机通道 |
| InputBubbleController+Submission `abortFrontmostMismatch` 臂 | 2 | 注释明示不可达（达此处时 frontmostMatches 恒 true） | 纯门 InputBubbleSubmitGate 已穷尽直测 |
| InputBubbleAutoShow tick summon 臂 + move-to-main arrival 编排（扫描/抑制/重定向） | ~55 | 需「活跃会话绑定窗真实跨屏迁移」+归因账本新鲜记录（写生产注册表=C7 归口；迁移=真机域） | 纯门 decideMoveToMainArrival / decideArrivalWhileBubbleOpen / decideArrivalWhileBubbleOpen 已穷尽直测；GRID_E2E/真机 B184 通道 |
| InputBubbleAutoShow `.cached` 臂 / bounds-nil 守卫 | ~6 | .cached 一级未命中下结构性不可达（注释明示）；本机 CG 窗恒带 bounds | 决策表 InputBubbleFrontIdentityPlan 已穷尽直测 |
| InputBubbleHistoryPanel `init?(coder:)` ×3 | 3 | XIB-less 手工视图死模板（保留以满足 NSCoding 契约） | —（物理死代码） |
| InputBubbleHistoryPanel `.settled` 臂 / 监视器 invisible 守卫 / fill nil-handler | ~8 | 真机 key-window 落定语义；fillHandler 在行存在期恒非 nil（防御） | 真机历史面板人工验收 |
| MarkdownLiveRenderPlan 零推进/regex 编译/字体回落防御臂 | ~7 | NSString lineRange 恒含换行（注释明示）；固定 pattern 编译恒成功；Menlo 恒在 | 渲染契约（串逐字一致+属性面）已穷尽直测 |
| DraftStore/HistoryStore JSONEncoder 失败守卫、Preferences `step≤0` 臂、Panel/Controller `screens.first ?? 0` 族 | ~8 | 纯 Codable 不可失败/常量域/显示器恒存在的防御臂 | —（物理不可达） |


## 真机 E2E 通道矩阵（口径②的覆盖面）

| 通道 | 环境变量 | 状态 |
|---|---|---|
| 跨屏移动尺寸保真 | `VIBEFOCUS_SIZE_E2E=1` | ✅ 既有，真机绿 |
| FloatSettle 序列 | `VIBEFOCUS_FLOATSETTLE_E2E=1` | ✅ 既有，真机绿 |
| 网格 Space 投递 | `VIBEFOCUS_GRID_SPACE_E2E=1` | ✅ 既有，真机绿 |
| 网格目标屏编排 | `VIBEFOCUS_GRID_TARGET_E2E=1` | ✅ 既有，真机绿 |
| 终端标题定向改名 | `VIBEFOCUS_TITLE_E2E=1` | ✅ 既有，真机绿 |
| HotKey 三件套（Carbon/tap/monitors） | `VIBEFOCUS_HOTKEY_E2E=1` | ✅ B244 通道，B255 独立复跑绿 |
| **气泡真面板域** | `VIBEFOCUS_BUBBLE_PANEL_E2E=1` | ✅ **B255 新建，真机绿**（summon/dismiss/锚定全链） |
| **SessionRestore 真恢复域** | `VIBEFOCUS_SESSION_RESTORE_E2E=1` | ✅ 既有七腿通道（捕获审计/双屏恢复/claude resume 注入/skipAlive），B257 登记入账 |
| **AXWrite 编排层** | `VIBEFOCUS_AXWRITE_E2E=1` | ✅ **B253 新建，真机绿**（B252 号被并行线占用） |
| **Overlay 家族真窗链** | `VIBEFOCUS_OVERLAY_E2E=1` | ✅ **B301 新建，真机绿**（3628/3628；OverlayWindow 5→1、+Display 100→22、base 87→76；残行=SIGUSR1 处理体 C5+空延迟表功能关死+查询失败分支 getYabaiPath 注入不可达归 C7） |
| SessionRestore 真恢复域 | 待建 | ⬜（restore 链已有真机人工闭环，待 env 门控自动化） |

## ⚠️ 收口运维纪律（B259 联跑实测教训，2026-09-20）

**发布前全量 E2E 必须逐通道单独跑（一次一个环境变量），严禁多通道联跑。**
联跑实测翻车：AXWrite 清场超时 + SessionRestore 前置建窗失败共 9 例红——窗口创建/关闭
竞速 + iTerm2 终止确认框堆积（跑着交互 shell 的窗，close 会挂起等确认）。逐通道跑
（各自 solo）同日全部绿。残留清理配方（确认框堆积时）：yabai 盘点定位 → AppleScript
枚举窗 tty → kill 会话前台进程 → System Events 点 sheet「OK」→ 循环至盘点归零。

本轮演练记录（2026-09-20）：六通道 solo 均绿（SIZE/FLOATSETTLE/AXWRITE/BUBBLE_PANEL/
HOTKEY/SESSION_RESTORE）；联跑 1 轮失败并已清理归零——正式收口按逐通道执行。

## 对照刷新记录（最新实测 vs 口径）

| 轮次 | 日期 | 全口径行 | Sources 纯净口径 | Runner 断言 | 备注 |
|---|---|---|---|---|---|
| B263 轮 | 2026-09-20 | 77.24%（66708 行） | 70.01%（36933 行，missed 11114） | 3410/3410 | 插桩构建 llvm-cov 实测 |
| **B270 终值轮** | 2026-09-20 | 78.15%（67144 行） | 71.61%（37066 行，missed 10523） | 3431/3431 | 全部 E2E 通道当日独立绿；多线并行清扫持续 |
| **B282 复核轮（最新）** | 2026-09-20 | **78.91%**（67746 行） | **72.75%**（37066 行，missed 10103） | 3506/3506 | A 态清单清账推进（B272~B281 六批），签署时点后净提升 +0.76pp 全口径/+1.14pp 纯净 |
| **B312 轮（最新）** | 2026-09-21 | —（本轮仅跑 Sources 口径） | **74.76%**（37971 行，missed 9585；批前 74.66%/9622） | 3839/3839 | A 态清单最后两具名残留清账（B312：SoundManager 残支 45→12 + ScreenIndex 迁移臂 66→60），并清 B311 遗留测试警告 9 条（零警告门禁复原）；全口径列本轮未测，口径以 Sources 纯净为准 |

**低覆盖文件归属核对**（B263 轮，missed≥100 行者全部归位）：

| 文件 | missed | 归属 |
|---|---|---|
| HotKeyManager+Monitors/CarbonHotKey/EventTap | 665 | ✅ 口径②：HotKey E2E 通道（B244 建，B255 复跑绿） |
| SettingsView+LayoutSection / SessionLists | 618 | ⬜ C6 渲染树绑定 + 生产 DB 禁写（台账 C6/C7） |
| WindowManager+AXWrite/MoveWindow/PostMove/Restore/Toggle+Routes/Layout/Toggle | ~1100 | ✅ 口径②：AXWrite E2E（B253）+ SIZE E2E 既有通道 |
| AppDelegate.swift / +Menu | ~300 | ⬜ C1 生命周期胶水 + 菜单构建已测（B249，+Menu 59%） |
| TerminalGridController(+Automation/SpaceDelivery) | ~540 | ✅ 口径②：GRID_SPACE/GRID_TARGET/GRID E2E 通道 |
| InputBubbleController(+Submission) | ~450 | ✅ 口径②：气泡面板 E2E（B255）+ 空态守卫已测（B258 并行） |
| HookEventHandler(+WindowMove/Execute) | ~390 | ⬜ C7 生产状态禁写（B242 裁决留白；守卫分支已测） |
| SpaceController+SARecoveryAdmin/Recovery | ~265 | ⬜ C3 系统授权（提权弹框）+ 状态机已测（B225/B254） |
| TitleEditorService(+Channels) | ~290 | ⬜ C2 真实模态（NSAlert/NSAppleScript）+ TTY/AX 已测（B218/B243） |
| SettingsWindowController | ~107 | ⬜ C2 show() 真窗排序留白 |
| WindowManager.swift 残量 | ~60 | ⬜ C3（notifyAccessibility beep+开系统设置）/部分已测 |
| CrashSignalHandler/ContextRecorder 残量 | ~90 | ⬜ C5 物理不可达（handler raise 即退出）/双缓冲已测（B251） |

> 上表 missed 行数为 B263 轮 llvm-cov 实测近似值；每行归属对应本台账 C1~C7 之一或口径② E2E 通道。新增豁免必须逐条入账。

## 三态清账（B271 轮全量盘点，2026-09-20）

> 轮次实测：全口径 78.41%（67187 行）/ Sources 纯净口径 missed 10523（163 个文件有 missed）。
> 三态定义：**A 可提缝未清**（尚未提缝直测，后续批次认领）/ **B E2E 通道覆盖**（口径②通道真机绿）/ **C 豁免**（C1~C7，见上表）。

### 大块（missed≥50，合计 ≈6900 行）

| 归属 | 文件（missed） |
|---|---|
| B E2E：AXWrite/SIZE 通道（移动域） | WindowManager+Restore(107)/+MoveWindow+PostMove(134)/+Toggle+Routes(184)/+Layout(165)/+Toggle(222)/+MoveWindow(250)/+AXWrite(105)/+TerminalContext(137)；WindowManager.swift(81) |
| B E2E：HotKey 通道 | HotKeyManager+EventTap(239)/+CarbonHotKey(242)/+Monitors(266)/base(182) |
| B E2E：GRID 通道 | TerminalGridController(289)/+Automation(192)/+SpaceDelivery(127)/+TargetResolve(残) |
| B E2E：气泡面板通道 | InputBubbleController(443)/+Submission(188)/InputBubbleHistoryPanel(398 残)/InputBubbleAutoShow(110 残) |
| B E2E：SessionRestore 通道 | SessionRestoreExecutor(164 残)/HookEventHandler+SessionStart(100 残) |
| C1 胶水 | AppDelegate.swift(267) |
| C2 模态 | TitleEditorService(150 残)/+Channels(120 残)/SettingsWindowController(104 残)/AppDelegate+Instance(91 残) |
| C3 授权 | SpaceController+SARecoveryAdmin(100)/+Recovery(129 残)/AppDelegate+Menu(89 残)/+Instance(91 残) |
| C5 物理不可达 | CrashSignalHandler(166 残) |
| C6 渲染树 | SettingsView+LayoutSection(276)/+VoiceAnnouncementSection(315 残)/+SessionLists(120 残)/+CodexSection(175 残)/+ClaudeHookSection(214 残)/SettingsUI(108 残)/ScreenMinimapView(78 残)/+WorkspaceSection(103 残)/+SoundProjectRules(147 残)/+TerminalGridSection(106 残)/+TerminalGridActions(128 残)/+InputBubbleSection(64 残)/+PermissionsSection(71 残)/LANSettingsView(89 残)/+HookTest(76 残)/+Installations(78 残) |
| C7 生产禁写 | HookEventHandler(157)/+WindowMove(154)/+WindowMove+Execute(62)/+WindowResolution(78)/PerfMonitor(74 残)/Overlay ScreenOverlayManager(92 残/+Signal 55 残/+Display 100 残)/SpaceController+Switch(63 残)/+Query(64 残)/+Yabai(70 残)/WindowQuery(55 残)/WindowResolution(31 残) |

### 可提缝未清（A 态清单）

- 小块（missed<50）100 个文件：合计 ≈3600 行，**B271 已逐一归类**，分三组落账如下。

#### A 态·可提缝未清具名清单（下一批起按序认领，≈450 行）

| 文件 (missed) | 提缝方向 |
|---|---|
| ~~WindowManager+Finding (49)~~ | ✅ B299 已清主体：matchedWindowIdentity 尾段提纯（行为逐行等价）后注入候选表，策略 1/2 两日志分支+身份构造编排直测；残 15 行=captureFocusedWindowIdentity 三守卫（无前台 app/无焦点窗/无 handle，14 行）+ findClaudeCodeWindow 真实命中转发 return（1 行）→ 前台环境态留白归 B 态 AXRead 通道 |
| ~~SoundManager (45→12)~~ | ✅ B273 清钳制/往返；✅ B312 清残支：节流臂/免打扰臂（mock 播放口+基线相对计数，对套件先验播放态免疫）/resolve 失败双臂（Runner 无 Sounds 资源实锤）/5s 兜底身份校验（6.5s RunLoop 泵锁「旧闭包不掐新播放」竞态契约）/loadPreferences 缺数据+坏数据双臂（B248 仅可见性提缝 internal+阳性对照防假绿）；残 12 行归因：AppSoundPlayer.play 体=C4 真实发声、NSSound(named:)/Basso 系统音恒在+Bundle Sounds 资源仅装机有=装机态、savePreferences encode catch=Codable 不可失败防御臂 |
| ~~ScreenIndexPreferences (40→66→60)~~ | ✅ B273 已清（savesLegacyUpgrade=false 注入）；⚠️0.0.81 沙箱修复新增 66 行致注记失效（B301 点名待重审）；✅ **B312 复审终局**：enforce 全局→分屏迁移臂 6 行清零（save 恒走沙箱零生产触碰，G1~G3）；残 60 行=load()/save() 生产三源链（SQLite 主源+CFPreferences+UserDefaults）——**0.0.81 沙箱守卫本体**，isProductionAppProcess 在 Runner 恒 false=按设计不可达，强提缝须翻真实 plist/生产库违反 C7 红线 → 归 C7-装机态；替代验证=装机日常+设置页角标人工验收+2026-09-20「屏幕序号无法渲染」生产事故闭环 |
| ~~ClaudeHookServer (25)~~ | ✅ B274 已清（端口守卫低/高双分支直测） |
| ~~WindowManager+Toggle+Decision (28)~~ | ✅ B274 已清（evaluateRestoreDecision 输入收集段注入直测） |
| ~~VoiceAnnouncementManager+RestoreOutcome (27)~~ | ✅ B276 复核改判：plan 纯映射已测（B229），残量=announce 发声接线 → C4 出声豁免 |
| ~~YabaiClient (28)~~ | ✅ B276 复核改判：fallback 链已测（B271），残支=cache/candidates 段执行顺序依赖（先到测试先填充静态缓存，无法稳定认领）→ C7 顺序依赖豁免 |
| ~~SpaceController (27)~~ | ✅ B279 部分清账（refresh 节流窗分支+updateEnabledState 迁移）；余量=后台 fork 应用段归 C7 |
| ~~WindowStateStore+Database (26)~~ | ✅ B299 已清：env 注入缝（VIBEFOCUS_DB_PATH 父目录自动创建）+ 垃圾文件库 WAL/schema/prepare 连锁败 + 第二连接 BEGIN EXCLUSIVE 写锁 BUSY step 失败 + PK 迁移三态（成功含 OR IGNORE 去重/建表失败 windows_v2 被占/拷贝失败回滚 DROP）；残 1 行=home 分支 .vibefocus 建目录（需 HOME 无 .vibefocus，跨测试污染风险不提缝） |
| ~~TargetResolve (23)~~ | ✅ B277 复核改判：selectionPreview 静态缝已测（B106/HookWalk），残支=AX/E2E 域 | TTYWriter (23)✅B278 已清(open 失败分支) / SessionActivityTracker (23)✅B278 已清(prune 年龄容量淘汰+parse 坏条目跳过) / ~~Toggle+Restore+Stages (20)~~ ✅ B299 已清（preMoveSpace=nil 预取跳过 + clamp 重试成功路 restore_clamped 闭环，exactNSScreen 环境门控防假红） / ~~Support+Diagnostics (20)~~ ✅ B299 复核改判：全部为装机态分支 → 豁免台账 C7-装机态（见下） |

#### A 态复核改判·装机态锁死（B299）

| 文件 (missed) | 归因 | 不可达证明 |
|---|---|---|
| Support+Diagnostics (20) | ①BuildCapabilities MISSING 分支：Runner 二进制经同一构建链编译，caps 恒在（missingCaps.isEmpty）→「装机漂移」分支语义上不可达；②execPath "nil"/unreadable 分支：CLI Bundle.main.executableURL 恒非 nil；③codesign/security unable-to-run 分支：/usr/bin 固定路径进程恒存在；④codesign stdout 非空分支：codesign -dv 输出恒走 stderr；⑤findAppBundlePaths mdfind 失败分支：mdfind 恒存在且 exit 0；⑥security stderr 非空分支：需删除 VibeFocus 签名证书（破坏用户钥匙串） | 全部为「装机环境异常」告警分支，触发条件=破坏性改变本机装机状态；替代验证=生产 --diagnose 报告冒烟（B292 logAvailability 先例） |

#### B 态·E2E 通道覆盖（≈900 行，25 文件）

**B300（2026-09-20）B 态清账首批 5 项**：TerminalUsageTracker 22→0（**100%**，合成 NSWorkspace 激活通知直投 workspace 通知中心+RunLoop 泵，零真实激活）、SessionRestorePlanner 6→1、ShellRunner 9→1（幽灵可执行两入口/超时 terminate 两变体/孙进程占管道 grace 两入口）、ToggleEngine 6→2、ClaudeSessionLocator 6→2（五入口缺省 runner 参数路径幽灵输入打穿）；Runner 3585→3614 全绿、全口径 72.50%→73.18%。B 态余量=真机域（按键注入/AX 写/真实面板），归既有 E2E 通道。

**B301（2026-09-20）Overlay 家族 E2E 通道开建**：`VIBEFOCUS_OVERLAY_E2E=1`（Tests/e2e/README 已登记）——真窗链全家+抑制开关+熔断守卫+force refresh 双分支+后台 Task 真实 yabai 落账；默认门禁恒跑离屏生命周期节（不 orderFront）。家族 missed 352→188（E2E 模式实测），TOTAL 全口径 73.18%→73.48%。⚠️复核提示：ScreenIndexPreferences 66 missed 为并行线「进程级持久化沙箱修复」（0.0.81）新增代码，B273 清账注记对该文件失效待重审；+SpaceQuery 残 18 行=yabai 级失败注入经 preferences.yabaiPath 不可达（getYabaiPath 仅消费于 getPerScreenSpaceIndexAsync 单点）归 C7；+Signal 残 55 行=SIGUSR1 处理体（C5，B234 DispatchSourceSignal CLI 不投递）+signalFollowUpRefreshDelays 空表功能关死体。
**B302（2026-09-20）气泡拖拽调宽驱动入通道**：builtPanel 后直驱 beginResizeDrag/applyResizeDrag/finishResizeDrag/applyPanelSize 全链（左上角固定几何对账 InputBubbleLayout 纯函数、未 begin 守卫、量化落账+偏好同步、滑杆联动通道，偏好快照-还原 B84 家法）；零合成鼠标零文本注入。⚠️环境受阻：yabai 新坏法——**id→window 解析全灭**（聚合列表在而 scoped-by-id 全灭，重启 daemon/唤醒均不愈，需注销/重启），锚点建立不可→通道防泄漏前置探针（对既有窗 scoped 探测，不通则建窗前跳过，零泄漏）。InputBubbleController+Panel 维持 B 态待环境愈后重测。
**B312（2026-09-21）A 态清单收官批**：SoundManager 残支 45→12 + ScreenIndexPreferences 复审清迁移臂（详见 A 清单两行）；连带修复 B311 批遗留的 9 条测试警告（Finale 6+Tail 3，零警告门禁复原）；新文件 RunnerSoundScreenPrefsResidueTests.swift 14 断言。门禁：build 零警告 + Runner 3839/3839（普通+插桩双轮）+ Standalone 全过；Sources 纯净 74.66%→74.76%（missed 9622→9585，两靶点 -37 行精确对账）。**A 态具名清单自此清零**：余量全部归 B（E2E 通道）或 C（C1~C7 豁免），后续新代码按「新缺口逐条入账」纪律执行。

InputBubbleController+Panel(34, 拖拽调宽=气泡通道) · SessionRestoreController(18)/Planner(6)/Store(2)/PaneClassifier(1)/RemoteSessionProbe(1)/SSHCommandParser(2, 真恢复通道) · OverlayWindow(5)/+Refresh(18)/+SpaceQuery(18)/SpaceSnapshot(3, overlay 真窗域) · WindowManager+AXRead(8)/+ScreenPosition(4)/+TerminalContext+Helpers(4)/+Toggle+FocusFallback(19, pickFallback 已测+AX 边支) · Space/CoordinateKit+Screen(7)/+Context(21)/+Move(32, toggled=AXWrite/SIZE 通道)/NativeSpaceBridge(18) · Toggle/ToggleEngine(6) · Hook/HookEventHandler+Remote(1)/+Notification(1)/SessionWindowRegistry 三件(21)/SessionPanelLogic(2) · TerminalGrid/ClaudeSessionLocator(6)/ScreenLayoutMapper(1)/TerminalAutomationScript(1)/Store(3)/SelectionResolver(1)/UsageTracker(6) · SettingsView+TitleEditorSection(2)/+HotKeySection(6) · App/TranscriptTail(4)/VoiceManager+Persistence(3)/+Queue(4) · Support/AuditLogger(3)/AXSelfHeal(2)/CGWindowEntry(2)/ExitJournal(4)/FrameConvergence(4)/FrameWriteExecutor(2)/MoveToMainPipeline(5)/ShellRunner(9)/TerminalRegistry(2)/YabaiEnvironmentProbe(2)/Doctor+InstallInventory(7)/BuildCapabilities(1)/CrashRuntimeSnapshot(1) · Layout/LayoutHotKeyTable(2)/WindowLayoutManagerProbe(1) · Hook/HookScriptGenerator(4)/RemoteInstallDeploy(2)/RemoteInstallScriptBuilder(1)/LANHookPreferences(1)

#### C 态·豁免（≈2250 行，36 文件）

| 类 | 文件 (missed) |
|---|---|
| C2 模态 | SettingsView+SoundSection(46)/+TerminalGridSnapshots(48 残) |
| C4 通知 | UserNotificationPoster(34, UN 授权域) |
| C5 物理不可达 | BacktraceSampler(15)/AppDelegate+Sigterm(14, 信号体触发即退) |
| C6 渲染树 | SettingsComponents(18)/+Audio(35)/+Navigation(15)/+Shortcuts(14)/DesignSystem(1)/GridSnapshotWidgets(8)/SettingsView+OverlaySection(32)/+SoundAntiDisturb(23) |
| C7 生产禁写/信号 | ScreenIndexPreferences(40)/HookInstaller(14)/CodexHookInstaller(13)/ClaudeHookPreferences(4)/ClaudeHookServer+Request(6)/SpaceController.swift(27, refresh 内部 fork 编排) |

> 注：SpaceController.swift(27) 原判 A，B271 复核其残支=refreshAvailability 后台 fork 编排内部行（无单测可达入口），改判 C7；SoundManager 残支已由 B312 终局清账（45→12，残量=C4 发声+装机态+防御臂，见 A 清单行）。

## 签字

- [x] 口径②E2E 通道全部建成（AXWrite/气泡面板/HotKey/SessionRestore 真恢复均已登记并真机验证）
- [ ] 豁免条目复核（逐条确认替代验证通道有效）
- [x] 发布前全量 E2E 一轮 + 门禁三绿 + 本台账对照刷新 —— **正式轮已完成（2026-09-20，B265，逐通道 solo）**：
  SIZE 3424/3424 ✅ · FLOATSETTLE 3419/3419 ✅ · AXWRITE 3419/3419 ✅ · BUBBLE_PANEL 3415/3415 ✅ · HOTKEY 3421/3421 ✅ · SESSION_RESTORE 3447/3447 ✅；
  每通道跑后 iTerm2 窗口数回到 42（清场归零）。对照刷新=B263 轮实测（全口径 77.24%/Sources 纯净 70.01%）+ 逐文件归属核对表。

（签署区：用户 / 负责会话，发布前填写）

### 待补签（B299+B300+B301 提请，2026-09-20）

- [ ] B299 豁免增改补签：①Support+Diagnostics 残 20 行改判 C7-装机态（触发=破坏装机：无 caps 二进制/缺 codesign/删证书/mdfind 失效；替代验证=--diagnose 冒烟）；②Finding 残 15 行（前台环境态）/StateStore+Database 残 2 行（HOME 污染风险）留白注记；③门禁环境注记（显示器休眠致 yabai 聚合查询截断，Runner 须 `caffeinate -d`；全绿实证 3596/3596）。②B300（main 8341f62）：B 态五项清账（Tracker 100%/ShellRunner 9→1/Planner 6→1/Locator 6→2/ToggleEngine 6→2，均为单测可达行而非新豁免；B 态余量真机域归既有 E2E 通道）；③门禁环境纪律补全：先 `caffeinate -u` 唤醒再 `-d` 压住（-d 不唤醒已睡屏幕）。Runner 3614/3614 全绿。④B301（main 4848a28）：Overlay 家族 E2E 通道（`VIBEFOCUS_OVERLAY_E2E=1`），家族 352→188 missed；SIGUSR1 处理体归 C5、空延迟表功能关死体、SpaceQuery 注入不可达归 C7；⑤ScreenIndexPreferences 66 行=并行线 0.0.81 沙箱修复新代码，待其责任线重审。Runner 默认门禁 3619/3619+E2E 模式 3628/3628 全绿。**已三次向用户提请（AskUserQuestion 均未应答），待确认后勾选**。
- [ ] B312 补签提请（2026-09-21）：①ScreenIndexPreferences 残 60 行改判 C7-装机态（0.0.81 沙箱守卫本体，强提缝=写真实 plist 违反生产禁写）；②SoundManager 残 12 行归因 C4/装机态/防御臂；③B311 豁免清单（上节）一并提请。Runner 3839/3839，Sources 纯净 74.76%。
- [x] 用户签字：已确认签署（用户于 2026-09-20 验收对话中裁决「可测面 100% + E2E + 豁免台账」口径并确认签署） 日期：2026-09-20
