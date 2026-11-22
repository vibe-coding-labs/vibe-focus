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

---

## 2026-11-03 CI 逐域覆盖率冲刺（分支 `test/coverage-sprint`）

> **背景**：本会话在 Linux 主机（无 Swift 工具链、工程依赖 AppKit/碳素），AGENTS.md 门禁
> （`swift build` 零警告 + Standalone + Runner）只能在 macOS 执行。为把「可提缝面 100%」
> 的度量真正跑起来，新增 GitHub macOS 通道 `.github/workflows/coverage-verify.yml`：
> 构建零警告 → Standalone → **逐域隔离 + llvm-cov 全量覆盖率**（artifact：
> `coverage-report.txt` / `coverage.lcov`）。

### 采集机制（本轮新增，均为测量通道改动，不改生产语义）

| 机制 | 目的 | 位置 |
|---|---|---|
| `VIBEFOCUS_PER_DOMAIN_RUN=1` 逐域独立进程 | 单域挂起/崩溃只损失该域 profraw，不再整轮归零 | `scripts/coverage_test_runner.sh` |
| 域清单从 `runDomain("…")` 注册表提取、按注册顺序去重 | 新域免维护第二份清单 | 同上 |
| `VIBEFOCUS_PER_DOMAIN_TIMEOUT`（默认 120s，CI 180s）+ `…_TIMEOUT_OVERRIDES` | 合法慢域（真实 curl 打环 300s）单独放宽，其余按时兜底 | 同上 + workflow |
| UI 域子进程结束后回收 `/tmp/vibefocus-e2e.lock` | SIGKILL 超时域不会让后续 UI 域连锁 exit 3（实测 7 域连锁归零） | 同上 |
| 逐域进程启动 `_ = NSApplication.shared` | 隔离进程里 NSApp 为 nil，摸 AppKit 的域会隐式解包崩溃 | `Tests/Runner/main.swift` |
| 互斥锁释放/看门狗预算 | 全局 80 分钟预算耗尽即停后续域，已采 profraw 照常出报告 | workflow |

### 测试手法修正（2026-11-03 实测取证）

- **AX 自读死锁**：主线程对**自身进程** `AXUIElementCreateApplication(ownPID)` +
  `CopyAttributeValue` 会自阻塞（AX 应答需要主线程 run loop，而线程正卡在调用里）——
  `BubbleSubmitPipeline` 整域 120s 超时零 profraw 的根因。修法：后台线程探测 + 主线程
  有界等待并泵 RunLoop；需要「AX 必失败」时改用**幽灵 pid 999999**（不存在进程，AX 立即
  返回错误），顺带覆盖 `resolveWindow` 四级退化链的 none 尾路。
- **渲染域逐 tab 拆进程**：设置页 7 个 tab 同进程连续渲染时，每次 `onAppear`（登录项
  AppleScript / SMAppService / spaceAvailability / 安装扫描 mdfind）在 CI 实测 2~28s，
  累计 >120s 超时。修法：拆成 7 个逐 tab 独立域（`runSettingsTab*RenderTests`）。
- **快照渲染改自建离屏窗**：共享设置窗在 CI 上 `cacheDisplay` 触发
  `AttributeGraph: cycle detected` 硬崩（Trace/BPT trap）。修法：`NSWindow` + 纯 `NSView`
  自建离屏窗，独占覆盖 layer / 非 layer / 空 bounds 三分支。
- **合成 Carbon 事件**（新域 `runHotKeyCarbonEventTests`）：`CreateEvent` +
  `SetEventParameter(typeEventHotKeyID)` 直投 `handleHotKeyEvent`，覆盖缺参/签名不符/
  未知 id/录制外分派；主 toggle 键只走去重门 skip 臂，**不注册任何系统热键、不进入
  .accept 真搬窗路径**。

### 新增域（本批）

| 域 | 覆盖目标 | 真机安全边界 |
|---|---|---|
| `runWindowResolutionFallbackTests` | `resolveWindow` 四级退化链（fast→exactID_scan→windowNumber→title→none） | 幽灵 pid，零真实窗口读写，无 env 门 |
| `BubbleHistoryPanelController`（UI 门） | 历史面板控制器：open/refresh/搜索/范围/展开/复制/删除/填充/回车填充/清空两段确认/关闭 | 真开我方 NSPanel；用户 2 分钟内有输入则诚实跳过 |
| `runHotKeyCarbonEventTests` | Carbon 处理器装配 + 事件分派分支 | 零系统热键注册、零真实 HID |

### 口径说明

CI runner 无 yabai、无 AX 授权、无真实终端/IDE 进程，故「真机域」（AX 写、space 查询、
网格建窗、会话恢复）在 CI 上只能走到守卫/早退分支，**CI 数字天然低于真机基线**
（真机 Sources 纯净基线 74.76%，2026-09-21 B312）。CI 数字只用于「缺口定位 + 可提缝面
趋势」，发布验收仍按本台账顶部口径①+②+③。

### 2026-11-03 第二轮实测（提交 `8d11028`，run 41648375399）

- **总量**：`llvm-cov report` TOTAL **40974 行 / 11437 missed / 72.09%**（上一轮 12464 missed / 69.58%，
  本轮多覆盖 1027 行）。LCOV 全口径（含 Tests）60935 行 / 12898 missed / 78.83%。
- **锁回收验证**：全程 0 次「另一个真机 E2E 正在运行」，UI 域不再连锁归零。
  唯一超时域 `runAgentAccessLoopbackTests`（真实 curl 打环，300s 覆盖值，该域无 profraw）。
- **新域首验全绿**：`runWindowResolutionFallbackTests` 4/4、`runHotKeyCarbonEventTests` 9/9、
  `BubbleHistoryPanelController` 23/23（历史面板控制器全链在 CI 真渲染通过）。

### 本轮定位并修复的假覆盖 / 硬崩（CI 取证）

- **游离 `@EnvironmentObject` 求值 fatal**：`runSettingsCoverageRenderTests` 与
  `runSettingsRenderPermissionsDuplicatesTests` 直接求值 `view.layoutHotKeySection` /
  `view.permissionsSection`，二者读的是 **SettingsView 自身的** `@EnvironmentObject
  hotKeyManager`——注入到子视图无效，CI 上 `Fatal error: No ObservableObject of type
  HotKeyManager found` → Trace/BPT（整域 profraw 连同断言丢失）。修法：把整棵
  SettingsView 交给 SwiftUI 求值（外层 `.environmentObject` + 选中 tab + ImageRenderer）。
- **同实例 body 缓存造成的「假通过」**：`runSettingsCoverageRenderTests` 复用同一个
  `SettingsView` 连渲染四种播报模式，体感「四模式全渲染出图」全 PASS，但实测
  `SettingsView+VoiceAnnouncementSection.swift` 第 30~205 行**整段 0 覆盖**——游离的
  `@StateObject` 不订阅 `@Published`，SwiftUI 直接命中首次（mode=.none）的 body 缓存。
  修法：每次渲染新建 `SettingsView()` 实例；该域覆盖率随后应由 42.83% 明显抬升。
- **共享设置窗在 CI 离屏布局触发 `AttributeGraph: cycle detected`**（`SettingsWindowController`
  与 `runSettingsSnapshotRenderTests` 两个域）：崩点在 `SettingsWindowController.shared`
  首次构建 SwiftUI 全树，而非 `renderWindowToPNG`。属 CI 无窗口服务器的环境限制，
  归口径③（真机可跑，CI 不可达）。

---

## 2026-11-19 覆盖率收口轮（分支 `test/coverage-100`）

> **目标（用户 2026-11-19）**：把单元测试覆盖率补到 100%。
> **结论**：字面 llvm-cov 100.00% 在本工程**物理不可达**（结构性原因见下）；本轮按台账顶部
> 三项口径（① CLI 可提缝面 + ② 真机 E2E 通道 + ③ 物理不可达逐项归因）继续收口，
> 新增 9 组可提缝面直测，CI 实测多覆盖 64 行（+0.15pp）。

### 本轮新增断言（全 CLI 直测，零真机副作用）

| 目标 | 覆盖点 | 域文件 |
|---|---|---|
| MCP `tools/call` 路由 | `handleMessage` 分支：`content[text]` + `isError` 包裹、未知工具仍回合法 JSON-RPC result（此前只直测 `handleToolCall`，路由层零覆盖） | RunnerAgentAccessTests |
| `AgentApiRequestDecoder` | `decodeWindowID` NSNumber 桥接分支（小数取整 / 超 UInt32 / Bool / 字符串拒绝）、`parseJSONObject` 空数据与非对象 JSON | 同上 |
| `AgentSettingValue.displayValue` | 五态字符串化逐字（变更留痕与 GET 回显的唯一口径） | RunnerAgentSettingsWriteTests |
| iTerm2 捕获方言 | app 名→bundle 映射、ASID bounds 就近匹配、多 pane tab/session 排序落库（此前只测 Terminal tty 直查） | RunnerCaptureSeamTests |
| `ScreenGeometry.isEmpty` | 空表 / 非空两态 | RunnerCoordinateGeometryTests |
| `RestoreSpaceTopology` | `unavailable` / `available` / `available([])` 三态语义 | RunnerRestoreOrchestrationTests |
| `RestoreWindowOperating` 默认实现 | `visibleFrameForDisplay` = SpaceController display→NSScreen→quartz 换算（有无屏两态） | 同上 |
| 收敛默认参数 | `waitForRelayout` / `convergeFrame` / `convergeFramePolling` 省略 sleep 闭包的生产默认路径 | RunnerRestoreOrchestrationTests / RunnerConvergencePipelineTests |
| 远程会话匹配 | 标题后缀多命中 → nil（歧义不押注） | RunnerSessionRestoreTests |

### 实测取证

- **门禁**：run `44363011818`（提交 `bd2ca4a`）success，`VibeFocusTestRunner: 4037 checks,
  4037 passed, 0 failed`（上一轮 4015，本批 +22）；16 个域按 CI 无 yabai/AX 清单跳过。
- **覆盖率**：run `44363029597` success；llvm-cov report TOTAL **41794 行 / 9885 missed /
  76.35%**（上一轮 merge/integration 同 41794 行 / 9949 missed / 76.20%，**+64 行**）。
  LCOV 全口径 63583 行 / 11539 missed / 81.85%；LCOV Sources-only 31031 / 7730 / 75.09%。
- **靶点逐行复核（LCOV DA，前→后）**：`MCPProtocol` 21→4（路由包 109–115 全部执行）；
  `AgentSettingsCatalog` 10→1（displayValue 50–58 全部执行）；`AgentApiCore` 9→1
  （NSNumber 桥接 139–145 全部执行）；`RestoreSwitchOrchestration` 9→0（拓扑两态 +
  默认几何实现）；`SessionRestoreController` 20→15（iTerm 分支 77–79）；`RemoteSessionProbe`
  1→0（多命中叉口 101）；`ScreenGeometry` 1→0（`isEmpty`）；`FrameConvergence` 4→1。
- 覆盖率逐域跑存在环境性波动（如 `SpaceController+Context` 33→77 属域执行面变化），
  上述靶点均按 DA 行逐条核对，非总量摊派。

### 本轮确认的测量假象（不是未覆盖）

- `AgentSettingsCatalog.swift:306`（`return "settings_key_unknown"`）DA 恒 0，但
  `apply(key:"no.such.key")` 断言 PASS——返回值必须经该行，属内联/归因假象。
- `FrameConvergence.swift:250`（`convergeFramePolling` 的 sleep 默认闭包）同理：断言
  PASS（省略 sleep 的默认路径已执行），DA 仍 0——默认参数闭包被归因到调用方。
- 另有死存储消除类（如「已 nil 再赋 nil」的 `spaceExact = nil`）在 llvm-cov 上永远 0。

### 为什么字面 100% 不可达（结构性）

1. **B 态（真机 E2E 通道，约 9000 行）**：CI runner 无 yabai、无 AX 授权、无真实终端/
   IDE/WindowServer 会话。AX 写、space 查询、网格建窗、会话恢复、气泡面板等整文件在
   CI 恒走守卫早退（`WindowManager+MoveWindow`/`Toggle+Routes`/`TerminalGridController`/
   `SessionRestoreExecutor`/`InputBubbleController` 等），其覆盖由口径②真机 E2E 承担。
   本轮 coverage 逐域失败的 12 个域也全部是这类环境前置（yabai 不可用 / 真实 comm 链 /
   真窗口管线），与本批新增断言无关。
2. **C 态（C1~C7 豁免）**：生命周期胶水（重入即重复启动）、真实模态弹窗（CLI runModal
   挂死）、系统授权（拉起系统 UI / 提权）、真实发声（打扰用户）、信号真身（执行即杀
   进程）、渲染树绑定（脱离渲染树求值 SIGTRAP）、生产状态禁写（污染运行中实例）——
   单测执行这些代码会写坏测试进程或用户机器，台账逐项有替代验证通道。
3. **测量通道本身的损失**：逐域隔离下冻结/超时域不产 profraw；内联、死存储、默认参数
   闭包会产生「已执行但 DA:0」的行。因此即使把可测面全部写满，llvm-cov 也不会显示
   100.00%。

**验收口径不变**（用户 2026-09-20 签字）：① CLI 可提缝面 100% + ② 真机 E2E 通道全绿 +
③ 物理不可达逐项归因；字面 100% 不作为验收要求。本轮未发现新的 A 态（可提缝未清）项，
残余 missed 均为上述 B/C 态与测量假象。

### 2026-11-19 收口第二轮（批次 31–36，分支 `test/coverage-100b`）

> 继续按同一口径把 CLI 可测面写满。本轮新增 6 组域/扩展（下），Sources-only missed
> 7476 → **7085**（−391 行，75.92% → **77.18%**）。停止点理由：剩余大块经逐行复核
> 全部落在 B 态（真机 E2E 通道）与 C 态（豁免清单）之内，未再发现 A 态（可提缝未清）项。

#### 新增断言与靶点

| 目标 | 覆盖点 | 域 |
|---|---|---|
| `SpaceController+Switch`（105→26） | `switchToSpace` 四态：目标已可见 `noDrift/visible`、隐藏目标 SA 直切 `refocused/hidden`、聚焦带动落位验证（一次性 flag 桩）`refocused/hidden`、目标缺失 `failed/missing`、查询失败 `noDrift/unknown` | RunnerYabaiStubSeam |
| `SpaceController+Recovery`（157→61） | SA 恢复状态机闸门：`blockedBySIP` 拒绝自动恢复且不弹权；yabai 缺失早退（零提权）；verdict/时间戳/legacy 键读写全族 | 同上 |
| `WindowManager+Finding` / `+Toggle+FocusResolution` | UI 门控域自建真窗：单窗段锁「候选=1 → cgwindowlist 快路径 + adopt 收尾」，双窗段走 yabai 探测 → AX 分支；`captureFocusedWindowIdentity` AX 成功臂 | RunnerFindingFocusCaptureUI |
| `WindowManager+Layout`（166→134） | `placeWindow` 原语幽灵窗（FloatSettle 空转 + 直写守卫）、无授权全动作守卫、`applyLayoutAction` 在有授权且「前台 app 无在屏 layer0 窗」时走降级/自摆（前台他属 app 有窗时一律跳过，防真机误移用户窗口） | RunnerLayoutGuard |
| `WindowManager+MoveWindow+PostMove`（104→70） | `saveToggleRecordForMainMove` 三态：主屏外正常落库（帧/来源 space/display/身份）、主屏内 origFrame 被 `shouldRejectSave` 拒收、单屏 `singleDisplay:true` 放行 | RunnerPostMoveRecord |
| `ClaudeHookServer+API`（88→53） | 回环/token 门/分级授权/未知端点/写限流 429；全部写端点空 JSON → 400；幽灵窗 404；restore 不存在 409；capture 前置失败；layout 合法 preset；settings 批量缺 value；sessions 带绑定行 | RunnerAgentApiGuardSweep |
| `SessionRestoreExecutor` | 空快照全链空转（ok=true 零建窗，零 AppleEvent） | RunnerRestoreGuardSweep A0 |

#### 实测取证

- **门禁**：run `44396085594`（提交 `581028f`）success，
  `VibeFocusTestRunner: 4157 checks, 4157 passed, 0 failed, 16 domains skipped`
  （本轮起点 4037 → +120）；Standalone 9/28/24 三组全绿、零警告构建同轮通过。
- **覆盖率**（Sources-only 自算，LCOV DA 逐行并集）：
  - 起点 run `44370107659`：31,041 行 / 7,476 missed / **75.92%**
  - 批次 31–33 run `44379513177`（`39b4f39`）：7,183 missed / 76.86%
  - 批次 31–35 run `44384190011`（`a4817a4`）：7,198 missed / 76.81%
  - **定稿 run `44392636086`（`66c420c`，已合入 main）：31,041 行 / 7,085 missed /
    **77.18%**；全口径（含 Tests）64,557 行 / 10,983 missed / 82.99%**
  - 定稿后又以 run `44396109085`（`581028f`，摆位安全闸粒化）复测：7,145 missed /
    76.98%，与 77.18% 的差全部落在下述抖动域（Layout/API 两个目标文件均为 134/53 未变）。
  - 逐域全量存在 ±0.2pp 环境抖动（`Toggle+Routes` 223↔271、`ScreenOverlay+Display`
    42↔54 等域执行面随 runner 会话状态变化）；批次 36 把 UI 域单窗段确定性化后，
    `FocusResolution`/`Finding` 不再随 AX 会话有无在 63/34 与 31/14 之间漂移（定稿
    稳定在 31/14）。
- **逐文件变化（起点 → 末次，missed）**：`SpaceController+Recovery` 157→61、
  `SpaceController+Switch` 105→26、`ClaudeHookServer+API` 88→53、
  `WindowManager+MoveWindow+PostMove` 104→70、`WindowManager+Layout` 166→134、
  `WindowManager+MoveWindow` 220→196、`SpaceController+Yabai` 18→**0**、
  `WindowManager+MoveWindow+AXDirect` 120→107、`SpaceController+Query` 1→**0**、
  `CGWindowEntry` 2→1。

#### 剩余项归因（逐行复核，均为 B/C 态）

| 文件 | 残余 missed | 归因 |
|---|---|---|
| `WindowManager+Toggle+FocusResolution` | 31（`116-126,134-147,173-178`） | 单候选快路径（116-126）与 `adopt` 收尾（87-100）已由 UI 域覆定（批次 36 单窗段确定性命中）；yabai 命中分支（134-147）与「AX 窗不在 CG 快照」兜底（173-178）需要真焦点窗口——CI 无 yabai、无 AX 会话时结构性不可达（B 态） |
| `WindowManager+Finding` | 14（`73-77,80-85,161-162,181`） | 无前台 app / 前台 app 无 AX 焦点窗 / CG 快照里进程已退出 / 命中真实终端宿主窗——全部依赖真实桌面会话（B 态）；`captureFocusedWindowIdentity` 成功臂（95-114）已由 UI 域覆盖 |
| `WindowManager+Layout` | 134（`25-136,143-149,177-185,225-230`） | `applyLayoutAction` 入口链要求「前台 app 无在屏窗」才允许执行（安全闸：真机前台有用户窗口时绝不实摆）；CI runner 的前台 app 恒有在屏窗 → 整链在测量通道内被安全闸拦下。`placeWindow`/FloatSettle/无授权守卫（160-230 段）已覆盖；其余归真机 E2E（B 态） |
| `SessionRestoreExecutor` | 199 | 建窗/投递/活窗观测全部走真实终端 AppleScript 与 yabai（B 态）；纯函数 `groupByTargetSpace` 与空快照链已直测 |
| `TerminalGrid*` / `InputBubble*` / `SettingsView+*` / `HotKeyManager+*` / `CrashSignalHandler` | 见大块表 | 维持既有 B/C 态登记（真机窗口、渲染树、Carbon 事件、信号真身） |

**验收口径不变**：字面 100% 仍物理不可达；本轮可测面增量已全部落库，残余项逐行归入
B/C 态，无新增豁免需求。

### 2026-11-19 收口第三轮（批次 37–42，分支 `test/coverage-100e`）

> 起点 `226622c` / run `44413980265`：Sources-only 31,801 行 / 5,534 missed / **82.60%**。
> 本批 4 个提交（`69971b4`、`61d547f`、`3538233`、`14b77e8`）新增 5 组域 + 1 处假红修复，
> 终测 run `44417368728`（`14b77e8`）：Sources-only **31,819 行 / 5,465 missed / 82.82%**
> （**−69 missed / +0.22pp**）；全口径 LCOV 68,506 行 / 9,408 missed / **86.27%**
> （起点 68,113 / 9,481 / 86.08%）。行数 +18 来自给移主屏执行半区提缝时新增的
> 环境 struct 与显式 if/else 接线，非生产逻辑扩张。

#### 本批新增断言与靶点

| 目标 | 覆盖点 | 域（CI checks） |
|---|---|---|
| 气泡自动弹出 tick | 焦点门 summon、同窗不重弹、气泡占用、开关关闭、非终端清 lastSeen 后重弹、无活跃绑定/同窗补绑定、hookPull 到达、userAction 有/无绑定、外部移动、开面板改绑、自动隐藏、同窗保持、移动开关关、多窗只弹跨越窗 | `RunnerInputBubbleTickSeamTests`（21） |
| 标题写入通道本体 | 不支持 bundle 不构脚本、非定向成功、定向 matched、定向未命中（判据先于错误号）、脚本报错、Terminal 诊断回读二次执行/回读为空、AX 元素不可写、iTerm2 当前会话与 Terminal 前窗 tab 的 tty 捕获三态 | `RunnerTitleEditorChannelsSeamTests`（14） |
| 移主屏执行半区 | 成功 200/`window_focused`/handled、身份与会话透传、onComplete 恰一次、气泡直弹、项目名解析 + 目标 bundleID、零失败 touch、开关关闭、非空闲不弹、409/`window_move_failed`、失败 touch 带触发名、失败臂零庆祝 | `RunnerHookMoveExecuteSeamTests`（11） |
| 气泡历史翻阅执行半区 | 首次 `moveTo` 展示条目并 stash 现场 + 光标跳尾、换条目不重写 stash、越界消费不动作、`exitToStashed` 还原清空、`.none` 不消费、`setNavText` 独立换文本 | `RunnerInputBubbleHistoryNavSeamTests`（7） |
| toggle 路由补口 | 有前台 PID 无句柄早退、无可映射副屏且无回退屏早退、回滚失败落 `move.rollback.failed`、knownIdentity/AX/orig 三件透传且零身份捕获、焦点回补失败仍只尝试一次、无主屏早退、knownOrigFrame 兜底照常落记录、源窗 display nil | `RunnerToggleRoutesSeamTests`（25） |
| srSeam 假分发修正 | 假 AppleScript 按 `sessions of t` / `tty of t` 区分 iTerm/Terminal 枚举——修复 Terminal 窗被判无 pane 的确定性假红（断言面不变） | `RunnerSessionRestoreExecutorSeamTests`（19） |

#### 逐文件变化（起点 → 终测，missed）

`HookEventHandler+WindowMove+Execute` 47→**14**、`WindowManager+Toggle+Routes` 100→**86**、
`TitleEditorService+Channels` 57→**47**、`ScreenOverlayManager+Display` 54→**42**
（后者非本批靶点，属第二轮已记录的域执行面抖动）。

#### 剩余项归因（逐行复核）

| 文件 | 残余 missed | 归因 |
|---|---|---|
| `HookEventHandler+WindowMove+Execute` | 14（`107-112,126-133`） | 真实气泡召唤（`summonForMovedWindow`）与真实完成音/角标 `Task` —— 出声与真面板（C4/B 态） |
| `TitleEditorService+Channels` | 47（`99-100,199-256,261`） | 真实 `NSAppleScript` 执行与真实 AX 属性写（生产 else 臂）——CI 无授权弹窗/无真实终端（B 态） |
| `WindowManager+Toggle+Routes` | 86 | 各路由的真实窗口原语闭包（float/frame 直写/AX）与生产 else 臂；路由判定与失败/回滚分支已由本批与既有 seam 覆盖 |
| `WindowManager+MoveWindow` | 100 | `moveWindowToMainScreen` 的 deps 接线闭包（只在真实移动时执行）+ yabai/AX 生产臂——B 态 |
| `CoordinateKit+Screen` | 13（`24,41,78,173-176,186-191`） | 零屏/多屏分支：单屏 CI runner 结构性不可达（精确几何换算与包含判定已由纯函数域覆盖） |
| `AgentCLI` 本地直读映射 | 26（`340-348,359,365-370,378-379,398-399,417-418`） | `runWindowsList`/`runSessionsList` 的行映射需要 runner 上真有 layer0 在屏窗 / 有 session-activity 文件；`runViaAPI` 的 curl 失败与 HTTP 错误臂需要本机 app 不在跑（B 态） |
| `ScreenIndexPreferences` load/save 生产三源 | 58 | 沙箱守卫刻意短路（`isProductionAppProcess` false）——测试进程绝不读写用户真实 SQLite/plist/defaults；沙箱文件读写与 legacy 迁移已由既有域覆盖 |

#### 实测取证

- **覆盖率** run `44417368728` success：`coverage-report.txt` TOTAL 42,842 行 / 7,404
  missed / 82.72%（全口径 llvm-cov report）。
- **新域逐域**（同一 run 内隔离执行）：`InputBubbleHistoryNavSeam` 7/7、
  `SessionRestoreExecutorSeam` 19/19、`ToggleRoutesSeam` 25/25、
  `HookMoveExecuteSeam` 11/11、`TitleEditorChannelsSeam` 14/14、
  `InputBubbleTickSeam` 21/21 —— 全绿。
- **环境失败集合**：本 run 的 24 条 FAIL 与起点 run `44413980265` 完全同一集合
  （`runHookWalkTests` 真实 comm 链 7 条 + yabai 缺失前置 / overlay / `runAsync` 等），
  无新增失败；真机门禁仍按 AGENTS.md 在全量 Runner 上验收。

**验收口径不变**：字面 100% 仍物理不可达（B/C 态 + 测量通道损失），本批可测面增量已
全部落库，无新增豁免需求。

### 2026-11-19 收口第四轮（批次 43，分支 `test/coverage-100f`）

> 起点 `2456051` / run `44417368728`：Sources-only 31,819 行 / 5,465 missed / **82.82%**
> （全口径 LCOV 68,506 / 9,408 / 86.27%）。本批 8 个提交新增新域
> `runYabaiDirectSeamTests`（43 checks），全部走「替身可执行文件
> （`VIBEFOCUS_YABAI_PATH`）+ 环境注入」，零真实 yabai/AX/窗口副作用。终测 run
> `44428344019`（`9e987fa`）：Sources-only **31,819 行 / 5,264 missed / 83.46%**
> （**−201 missed / +0.64pp**）；全口径 LCOV **68,891 / 9,218 / 86.62%**
> （行数增加来自本批新增的 Runner 测试文件）。

#### 本批新增断言与靶点

| 组 | 覆盖点（全部直测 CLI 可提缝面） |
|---|---|
| A `YabaiClient` 执行原语 | `run` 成功 / 非零退出 / 不可执行文件（launch catch）/ `stub-hang` 超时 terminate→nil；`queryJSON` 解码数组 / 非 JSON / 退出码守卫；`runAsync` / `queryJSONAsync` 成功、失败、launch 异常、退出码守卫 |
| B `SpaceController.focusWindow` 五分支 | disabled 早退；stub `--focus` 成功；失败 → Carbon 幽灵窗 false；unmanaged → Carbon false；表外窗口 id → `queryWindow` nil → `no_window` false；`focusWindowByCGWindowID` 幽灵窗 false |
| C 落位链 | `isEnabled=false` 零 fork；stub success；`runYabaiVariants` 失败路径 |
| D `applyAvailability` 四态 | launch 失败 → unavailable + "Unable to launch yabai"；exit0+SA 已载 → available/canControl true/message nil；exit0+SA 缺失 → available/canControl false + scripting-addition 提示；非零退出 → unavailable + 格式化错误 |
| E 快照响应体 | `ClaudeHookServer.buildSnapshotsBody()` JSON ok + count 与 snapshots 一致；`WindowManager.terminalScreenText` 空 AX 树 → nil |
| F `attemptSilentSARecovery` | 成功落账（verdict 键写入 → succeeded）；紧随调用被状态机闸门早退（canControl/lastErrorMessage 保持 sentinel）；UserDefaults 键原样还原 |
| G `SessionRestoreEnvironment` 默认闭包 | screens / cgDisplayID / primaryDisplayID / quartzVisibleFrame / exactYabaiDisplayIndex / automationInstanceRefusal ×2 / querySpaces / queryAllWindows / queryWindow 表外 id / bundleIdentifierOfPID 无效 pid / classifyTTY 合成路径 → `.shell` / focusSpace(.yabai) / setWindowFloat / parkingScreen / runYabai / now —— 17 个默认实现直调 |
| H `yabaiPath` 常规解析 | 撤注入 + PATH 前置替身目录 + `SHELL=/bin/bash`：`findViaUserShell` 命中、`findViaBashWhich` 命中、`yabaiPath()` 非 nil 且入缓存、二次命中同路径 |
| I SA 探针直调 | 无 focused space/探针启动失败 → false；stub exit0 → true；`scripting-addition` 报错 → false |
| J 查询缓存与 float 三臂 | `isCacheExpired` 过期/新鲜；`clearWindowQueryCache`；`setWindowFloat`：query_nil → skippedNoOp、unmanaged → skippedNoOp、可管理 → toggled（stub `--toggle float` 非零不影响决策返回值） |

#### 逐文件变化（起点 → 终测，missed）

| 文件 | 起点 | 终测 | 变化 |
|---|---|---|---|
| `Space/YabaiClient.swift` | 75 | **8** | −67（A/H 组：执行原语、常规解析链） |
| `Space/SpaceController.swift` | 63 | **5** | −58（D 组：`applyAvailability` 四态；`private → internal` 仅放开可见性，生产入口不变） |
| `Space/SpaceController+Move.swift` | 49 | **0** | −49（B 组 `focusWindow` 五分支 + J 组 `setWindowFloat` 三臂） |
| `Window/WindowManager+AXRead.swift` | 36 | **18** | −18（E 组：空 AX 树降级） |
| `Space/SpaceController+Recovery.swift` | 61 | **49** | −12（F/I 组：静默 SA 恢复成功链、状态机闸门、探针直调） |
| `Space/SpaceController+SARecoveryState.swift` | 7 | **0** | −7（F 组：verdict/时间戳读写全族） |
| `Space/SpaceController+Switch.swift` | 26 | 25 | −1 |
| `TerminalGrid/TerminalGridController+Automation.swift` | 69 | 68 | −1（域执行面抖动） |
| `Overlay/ScreenOverlayManager+Display.swift` | 42 | 54 | +12（域执行面抖动，非本批靶点） |

#### 剩余项归因（逐行复核，均为 B/C 态或单例生命周期夹具）

| 文件 | 残余 missed | 归因 |
|---|---|---|
| `SpaceController+Recovery` | 49（`14-16,23-38,131,182-210`） | 手动 SA 加载的同步提权与 `osascript` 管理员 shell（C3 系统授权）；`blockedBySIP` 持久化需 SIP 阻断的真实环境（B 态）；提权恢复编排同 C3 |
| `SpaceController+Switch` | 25（`98-156`） | `refocusWindowOnSpace` 的候选截断/聚焦失败/落位轮询日志臂：判据是「视角真落到目标 space」（700ms 实时钟轮询 + 真实焦点落位），替身无法伪造视角落定位（B 态） |
| `WindowManager+AXRead` | 18（`60,108-114,162-175`） | 真实 AX 元素/属性读与授权访问（B 态） |
| `YabaiClient` | 8（`69-70,82-83,125-126,153-154`） | 69-70 标准安装路径命中（CI runner 未在 `/opt/homebrew/bin` 等路径装 yabai；真机开发机即命中）；82-83 `which` 兜底缓存写（user-shell 先行命中，which 兜底只在无用户 shell 时走）；125-126/153-154 两个 fallback 的 Process 启动 catch（需 Process launch 失败，CI 无此条件） |
| `SpaceController` | 5（`83-84,94-95,98`） | 60s health timer 闭包、屏参变化通知闭包、`deinit`——单例进程生命周期胶水（C1；需实时钟/销毁 shared 单例，执行即改写共享运行时状态） |
| 其余大块（`WindowManager+WindowQuery`/`InputBubble*`/`TerminalGrid*`/`Settings*`/`SessionRestoreExecutor` 等） | 见上轮登记 | 维持既有 B/C 态归因（真桌面会话、渲染树、真实终端 AppleScript、提权/信号真身） |

#### 实测取证

- **门禁** run `44428344019`（`9e987fa`）success：`swift build` 零警告、Standalone 全绿、
  新域 `runYabaiDirectSeamTests` 43/43 全绿（定向 run `44427721115` 先行确认 J1–J3）。
- **全量逐域**（`VIBEFOCUS_PER_DOMAIN_RUN: 1`）：352 个域段合计 5,022 checks，FAIL 24 条，
  与前一轮 run `44417368728` 的 FAIL 集合**逐条完全一致**（CI 无 yabai/AX 的既有环境域：
  bind149 / hookDispatch / overlayQ / perf / pipeline / registry / spaceQY / spaceRO /
  spaceSwitch / yabai），本批零新增失败。
- **覆盖率**（Sources-only 自算，LCOV DA 逐行并集）：31,819 行 / 5,465 → **5,264** missed，
  82.82% → **83.46%**；全口径 68,506/9,408/86.27% → 68,891/9,218/**86.62%**。
- 同 commit 前一次全量（run `44425831906`）观测 Sources-only 5,280 / 83.41%，与本轮终测
  存在 ±9 行域执行抖动（`ScreenOverlayManager+Display` 一类随 runner 会话状态浮动）；
  靶点变化均按 LCOV DA 行逐条核对，非总量摊派。
- 夹具确定性修正（本批内两处）：替身补「单窗查询失败」臂，B5/F3 改用表外窗口 id
  （`4_000_999`），避免 `decodeSingleOrFirst` 对全量数组回退命中造成假绿/假红。

**验收口径不变**：字面 100% 仍物理不可达（B/C 态 + 测量通道损失）；本批 CLI 可提缝面
增量已全部落库，剩余 CLI 残余行经逐行复核均为真实 fork/AX/提权/实时钟/单例生命周期臂，
无新增豁免需求。

### 2026-11-23 收口第五轮（分支 `test/coverage-100g`）：假绿清算 + 新代码接线

> **触发**：上一轮收口（2026-11-19，83.46%）之后 main 又进了 2026-11-20~22 的
> 窗口原子合发与零动画总闸两个修复，两批新代码**只测了纯判据、没测接线**；
> 而用户当时的投诉正是「判据对但没接上」。同时本轮发现一类**系统性假绿**：
> 大量设置页测试用 `SettingsView()` 后置写 `@State`，而 B317 早已记录
> 「无窗 NSHostingView 下 post-install 写 @State 不落 storage」——这些断言
> 一直在渲染默认态。

#### 一、新代码接线补口（2026-11-21/22 进 main）

| 目标 | 覆盖点 | 域 |
|---|---|---|
| `SpaceController.runYabai` 动画总闸 | 前置节流断言 / 帧写入后强制复断言 / 读命令零断言 / 总闸自命令不递归；替身 argv 落盘回读 | RunnerYabaiStubSeam X1–X5 |
| `YabaiAnimationConfig` 判据余项 | display/rule 读域、裸 `-m`、未知域、`--version`、`--toggle zoom-fullscreen`、单发 `--resize`/`--move`、`--raise` | RunnerYabaiAnimationGuard A'17–21 / G4b–e |
| `assertDisabledOnLaunch` 本体 | query→disable 顺序；读不到原值仍关断 | RunnerYabaiAnimationGuard F'1–3 |
| `YabaiAnimationGuard.resetThrottleForTesting` | 进程级节流态测试缝（生产不调用） | 同上 + Stub X1–X5 依赖 |
| `FrameWriteExecutor` 段二单 `.move` 补发 | 只缺 origin 时只发 move、零 robust/adaptive | RunnerConvergencePipeline C′1–4 |
| `SessionRestoreExecutor` 写回/泊靠归因 | operation 标签前缀、泊靠先于写回、写回恰一条消息 | RunnerSessionRestoreExecutorSeam A15–17 |

#### 二、假绿清算（设置页初始化缝）

| 位置 | 假绿表现 | 修法 |
|---|---|---|
| 7 个 tab 渲染域 | 全在渲染 general tab（其余 6 个 tab 内容从未求值） | `init(initialTab:)` 注入 |
| 权限分区「其它副本」段 | `duplicateAppPaths` 后置写不生效 | init 缝 `duplicateAppPaths` |
| 摆位分区开关×冲突横幅 | 四态断言渲染的都是默认态 | init 缝 `layoutHotKeysEnabled` / `layoutConflictSummary` |
| 各分区操作结果横幅（12 个字段） | 安装/测试/注册/接入物料横幅分支从未求值 | `ResultMessages` 初始值集合 |
| 快照行「已设开机恢复」/多屏计数 | pill 与计数分支未求值 | init 缝 `gridSnapshots` / `gridAutoRestoreSnapshotID` |
| claudeHook 运行状态/Token/错误行 | 依赖 `hookInstallMessage` 后置写 | @Published 直注 + ResultMessages |
| 项目音效规则 ForEach 行体 | 裸求值不实例化 ForEach 子视图 | ImageRenderer 真渲染 |
| 会话卡片结果行/警告横幅 | 纯 @State 条件分支 | ResultMessages + 真渲染 |
| 唤醒重建调度臂 | 决策表已穷举但调度/取消/补射零覆盖 | 投 Notification 驱动实例方法 |

#### 三、其他可直测补口

`announceCompletion` 模板/音频边界（空模板回落、无路径回落、提问收尾、{tokens}）、
`ScreenOverlayManager.suspend/resume` 幂等与配对、`MCPRegistration`/`AgentOnboarding`
的 IO 失败面、`VibeFocusCrashPipeline.installHandlers`、`serializeFields` 空集双臂与
`logOperationDuration` 计时、`ScreenMinimapView.screenTapHelp` 三分支、
`WorkspaceSection` `.unavailable` 双态。

#### 实测（CI，`coverage-verify.yml`）

- 基线 main（run `45054279106`）：Sources 纯净 **31,962 行 / 5,258 missed / 83.55%**
- **终测（run `45065818388`，`2be91b4`）：32,019 行 / 4,790 missed / 85.04%
  （−468 missed / +1.49pp）**；断言 **5,161 过 / 22 败**（基线 5,071/22，
  失败集合与基线**逐条完全一致**——全部是 CI 无 yabai/AX 的既有环境域，
  本轮零新增失败）。
- 主要来源（missed 减少）：ClaudeHookSection −62、SoundProjectRules −46、
  PermissionsSection −45、WorkspaceSection −35、SettingsUI −34、
  Overlay+Rebuild −34、RestoreOutcome −27、CodexSection −24、AgentAccess −22、
  LayoutSection −21、`YabaiAnimationGuard` 8→**0**。
- 设置页假绿修正是本轮最大单一来源——印证「断言在跑但测的是默认态」比缺测试更隐蔽。

#### 第五轮补遗（`test/coverage-100h`，审计清单 A 态清账）

另起一轮独立审计后补了此前漏判的可直测项：
`HotKeyManager` 持久化读取三臂（decoded/legacyDefault 迁移/损坏回落 + 布局表命中与
withDefaults）、`FrameWriteExecutor` 省略 pollSleep 的生产默认参数、
`LANSettingsView` 未映射/已映射两分支（旧 defaults 写法是假绿，改 memberwise 注入）、
`TerminalGridController.runScript` 生产体（`return 1`/`error` 双态锁 lastScriptError）、
`SessionRestoreExecutor` deliver 两条失败出口（query nil / 永不落位）、Terminal 多 pane
附加、`InputBubbleAutoShow` 64 容量基线 FIFO 淘汰（含对照用例）。

**终测（run `45070340998`，`2d2dcb1`）：32,019 行 / 4,763 missed / 85.12%
（missed −495 / +1.58pp）**；断言 **5,176 过 / 22 败**（失败集合仍与基线逐条一致）。

本轮另记两处「自造断言错误」的订正（非产品缺陷）：`ClaudeMCPConfig.remove` 对坏 JSON
返回 changed=false（幂等成功）而非失败；基线淘汰场景中淘汰拍不能同时含被淘汰窗
（否则先删后写回，淘汰根本没发生）。

#### 剩余项复核（逐行）

Top 缺口仍为既有 B/C 态：`InputBubbleController`(真面板/真 AX 读)、
`TerminalGridController`(真建窗 osascript)、`AppDelegate`(C1 启动编排)、
`HotKeyManager+CarbonHotKey/EventTap`(口径② HotKey E2E)、`CrashSignalHandler`(C5 信号真身)、
`TitleEditorService`(C2 模态态)、`SARecoveryAdmin`(C3 提权)、`ScreenIndexPreferences`
(C7 装机态沙箱守卫)、`PerfMonitor` 看门狗线程(C7)。**本轮未发现新的 A 态。**

#### 可直测面自检（机械证据）

对 `Sources/` 全仓 `static func` 做「名字是否在 `Tests/` 中出现」的机械扫描：
**0 个未被引用**——所有可直接调用的纯函数/决策表在测试里都至少被触及一次。
这与「字面行覆盖 84.6%」的差异全部来自 B/C 态实例方法（真窗/真 AX/真提权/真发声/
真信号）与闭包体内的 action 代码。

**验收口径不变**：字面 100% 仍物理不可达；本轮把可达面里「测了但测错对象」的一类
假绿清掉，并把 2026-11-21/22 新代码的接线纳入断言。
