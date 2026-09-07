# 代码质量审计与夜间批次清单（2026-09-07 凌晨）

> 目标：高内聚低耦合 + 大文件拆分 + 逻辑重构 + 单测补齐。
> 与 docs/quality-plan-2026-09.md（P0~P7）衔接；本文件是执行层工作清单，每批完成后更新状态。

## 覆盖率基线（scripts/coverage_test_runner.sh，2026-09-07 实测）

- 全库 TOTAL：行覆盖 10.6%（6422 函数中 5741 未覆盖）、区域 10.85%。
- **2026-09-07 早晨复测：行覆盖 17.14%、区域 16.49%**（重构会话 Batch 11~17
  真身直测收口 + 夜间 B 系列后；剩余未覆盖为编排胶水/GCD/NSView 层，按三通道
  模型归真机 E2E 验收域）。
- **口径说明（重要）**：Runner 单测（无环境变量默认模式）只能覆盖纯函数/可注入逻辑；
  编排类文件（AX/yabai/AppleScript 编排）天然 0%，由真机 E2E（VIBEFOCUS_*_E2E）验收。
  三条测试通道：Runner 直测（真实实现单测）/ Standalone 镜像（自包含）/ 真机 E2E（行为）。
- 高覆盖样例：ToggleEngine+Restore 94.8%（分支 100%）、TerminalGridPlanner 88.9%（分支 100%）、
  TerminalAutoRestorePlan 92.9%（分支 100%）——「纯函数内核分支 100% + 编排 E2E」模式成立。

## 文件规模 Top（>300 行）

| 文件 | 行数 | 状态/计划 |
|---|---|---|
| TerminalGrid/TerminalGridController.swift | 1055 | **B1 已拆**：→ 6 文件（主编排 266 + SpaceDelivery 168 + Restore 268 + Capture 127 + TargetResolve 136 + Automation 121），提取纯函数 tty 解析/捕获排序/恢复帧规划（去重 restore 与 autoRestore 重复块）+ 12 条 Runner 断言 |
| Window/WindowManager+MoveWindow.swift | 554 | 重构会话域（Batch 6/7 MoveToMainPipeline 已推进），避让，观察其后续 |
| Settings/SettingsView+TerminalGridSection.swift | 536 | B3 候选：UI 文件，拆 Tab/子视图 + 表单校验逻辑提纯 |
| App/SoundManager.swift | 515 | B2 候选：音效域（有 ProjectSoundResolverTests 基础），拆播放引擎/音效选择/工程解析 |
| Toggle/ToggleEngine+Restore.swift | 444 | 覆盖已 94.8%，P1 已收敛，暂不动 |
| Space/SpaceController+Recovery.swift | 402 | B4 候选：SA 状态机域，改前先补镜像测试 |
| Hook/ClaudeHookModels.swift | 381 | 已有 HookModelsFullTests，查缺口再定 |
| App/AppDelegate+MenuAndInstance.swift | 362 | B5 候选：菜单/单实例小而独立 |
| Settings/DesignSystem.swift | 351 | 色板 token 文件，内聚良好，不拆 |
| App/VoiceAnnouncementManager.swift + RestoreOutcome | 317+28 | 覆盖 59-75%，B6 候选：补缺口测试 |

## 纪律

- 每批次：独立 worktree → 拆分/重构 → 提纯逻辑补穷尽单测 → 三门禁（构建零警告 +
  Runner 全绿 + run_all_tests）→ 合并推送 → 本清单更新。
- 并行避让：重构会话域 = Window 编排（FrameWriteExecutor/FloatSettle/MoveToMainPipeline/
  阶段状态机）；本清单不动这些文件，B 前先 fetch 查 origin/main 近期提交。
- E2E 同机互斥锁（P5）在岗；动窗口行为的批次加跑对应 E2E。

## 冲刺收官（2026-09-07 08:00）

- **覆盖率**：全库行覆盖 10.60% → **15.84%**（+49% 相对提升）；函数覆盖 6433 中新增 1000+ 可测函数入覆盖。
  B13~B18 六轮镜像转直测后，WindowMove+Decision 80.9%、ClaudeHookModels 80.8%（区域）、
  TerminalContext+Helpers 75%——提取单元函数级≈100%，编排路径由真机 E2E 家族验收。
- **Runner 直测断言**：278 → **867/867 全绿**（+589 条，全部真实实现直测、零镜像漂移；含 Batch 20 LayoutFrameCalculator 14 断言 + Batch 27 鉴权 13 断言 bcf1c4c + B28 Overlay 偏好层/Space 解码 17 断言 90d5b13 + B29 yabai 环境探针/绑定决策 18 断言 df2ac5a + B30 解码去重助手/语音模式 5 断言 010b1d3 + B31 Doctor 取证纯逻辑 10 断言 e485523 + B33 路径注入/路由提纯 9 断言 79028dc + B34 SettingsUI 提纯前置 13 断言 29b5b63 + B35 section 拆分/请求契约提纯 12 断言 7cef427 + B36 提示音门控/项目音效解析 12 断言 bda04ec + B37 能力自检/屏幕映射/网格库 22 断言 d44376c + B38 共存探测/热键/队列策略 19 断言 b54d1da + B39 切换反馈/标题脚本 12 断言 f4a5d32 + B40 错误文案/状态枚举收尾 5 断言 069762e + B41 提权模板/Doctor 端到端 7 断言 3233816 + B42 偏好契约回环 5 断言 6abfaea + B43 坐标纯函数 10 断言 ce0d3d1 + B45 热键校验提纯 4 断言 16ebc1a + B46 音效解析计划 6 断言 7f3e94a + B47 Doctor 报告全段落 6 断言 17c4a80）。
- **结构**：1055 行巨石 → 六模块；编排页/提示音段拆分；恢复帧规划去重；模型与编排分层。
- **真 bug**：volume 必填解码静默重置用户偏好（单测先行实锤修复）。
- **死测试清理**：FocusStepsCalculationTests（镜像函数已从源码删除）。

## 批次台账

| 批次 | 内容 | 状态 |
|---|---|---|
| B1 | TerminalGridController 1055→6 文件 + 纯函数提取（parseWindowTTYMap/sortedByReadingOrder/restoreTargetFrames 去重）+ 12 断言 | ✅ 2026-09-07 |
| B2 | SoundManager 模型块拆出 SoundPreferencesModels（515→393）+ **实锤并修复 volume 必填解码潜伏 bug**（旧 JSON 静默重置用户偏好）+ 真实实现兼容解码 15 断言 | ✅ 2026-09-07 |
| B3 | SettingsView+TerminalGridSection 拆四文件（536→137/214/87/99）+ summaryText/selectionDetailText/steppedGap 提纯 + 13 断言 | ✅ 2026-09-07 |
| B4 | SA 恢复状态机真实实现测试补齐（recoveryVerdict 6 + autoRecoveryAllowed 冷静期矩阵 6 + saProbeVerdict 4 = 16 断言，Runner 直测优于镜像）| ✅ 2026-09-07 |
| B5 | VoiceAnnouncement 模板插值/队列策略转 Runner 直测（消镜像漂移，8 断言）；AppDelegate+MenuAndInstance 审计结论=纯菜单粘合无需拆分 | ✅ 2026-09-07 |
| B6 | ClaudeHookModels 数据契约真实实现 23 断言（payload 双事件键别名/session 别名+trim+空拒绝/嵌套 ctx snake_case；TerminalContext 五因子绑定判据+isRemote；Response snake_case 编码）| ✅ 2026-09-07 |
| B7 | Hook 窗移决策树 Runner 直测 20 断言（守护顺序逐条+边界：超龄阈值/pidMatches nil 容错；httpResponse 映射表 8+1）——路由唯一事实源消镜像漂移 | ✅ 2026-09-07 |
| B8 | Space 投递七分支决策表 Runner 直测 9 断言（含 nil 查询失败容错两分支）——+SpaceDelivery 文件从 0% 抬升 | ✅ 2026-09-07 |
| B9 | SettingsView+SoundSection 318→3 文件（85/119/110）+ SoundSectionText/规则兜底音效提纯 6 断言 | ✅ 2026-09-07 |
| B10 | SessionWindowRegistry 查找级联隔离库直测 6 断言（直命中/pid 有效者优先/别名通道/DB 兜底层实证/markCompleted 联动）——新 env 门控 VIBEFOCUS_REGISTRY_E2E=1（须配隔离 DB）| ✅ 2026-09-07 |
| B11 | 终端上下文匹配族（tty 归一/命令-标题匹配/ps basename/iTerm UUID/注入防御 allowlist）+ Claude 窗口定位两级策略，Runner 直测 18 断言 | ✅ 2026-09-07 |
| B12 | GridTargetCode.parse 全形态/非法输入 + TerminalSelectionResolver.resolve（手动优先/auto 频次/空回落）Runner 直测 9 断言 | ✅ 2026-09-07 |
| B13 | float 脱管决策（含惰性不触查询不变量）/refocus 候选选择/outcomeLabel 四分支/retryable/源屏预切三态，Runner 直测 18 断言 | ✅ 2026-09-07 |
| B14 | restore 结局→播报计划总映射 Runner 直测 10 断言（spaceExact 三态/文案 nil 语义/成败音效通道）| ✅ 2026-09-07 |
| B15 | Quartz/Cocoa y 互转 + MoveCooldownRegistry 冷却纯决策/剩余秒数取整 Runner 直测 7 断言（无记录→0 语义对齐实现）| ✅ 2026-09-07 |
| B16 | walkToTerminalPID 谓词注入行走直测 9 断言（起始即终端/上溯/深度上限/ppid≤1 断链/自环/深度防御 + 注册表静态集合）| ✅ 2026-09-07 |
| B16.5 | soundType 兜底接线修正——规则未选音效时 Picker/试听共用 effectiveSoundType 单一事实源 | ✅ 2026-09-07 |
| B17 | Hook 脚本生成器不变量直测 9 断言（hooks JSON 合法性+恒注册事件/远程安装脚本 host 插值与 machine_label 归一/helper 端口与上下文采集）| ✅ 2026-09-07 |
| B18 | YabaiErrorClassifier 直测 8 断言（六类别/大小写不敏感/多类命中优先级）| ✅ 2026-09-07 |
| B19 | 镜像存活审计：70 个 Standalone 逐符号核对，**删除 1 个死镜像**（FocusStepsCalculationTests 镜像的 calculateFocusSteps 已从源码删除，测试在测自己的副本）；其余存活 | ✅ 2026-09-07 |
| B20 | SettingsUI.swift（244 行 34 个 @State 状态枢纽）审计结论=拆分属高风险 SwiftUI 状态重构且无单测面，缓办并记录；AppDelegate+MenuAndInstance=纯菜单粘合无需拆分 | 审计完成 2026-09-07 |
| B21 | SettingsView+ClaudeHookSection 334→265+89（Codex 区段独立）+ CodexInstallPresentation 展示映射提纯 5 断言 | ✅ 2026-09-07 |
| B22 | LAN 远程绑定持久化 Runner 直测（env 门控）3 断言：set nil 丢弃/active 过滤/独立 defaults 域；旧字典迁移路径留镜像覆盖（同进程 UserDefaults 缓存语义不适合进程内断言）| ✅ 2026-09-07 |
| B23 | TerminalUsageTable 直测 7 断言（record 幂等累加/lastAt 单调/minCount 过滤/14 天半衰排序/编解码回环与坏数据回退）| ✅ 2026-09-07 |
| B24 | 注册表状态操作隔离库直测 8 断言（markCompleted 置位+清别名/reactivate/touch 推进/空白消息拒覆盖/remap 迁移/clearAllBindings 清空）| ✅ 2026-09-07 |
| B25 | shellQuoted 单引号转义直测 3 断言（惯用法四字符序列/原样包裹/空串）；cellCommand 分支已由并行会话直测覆盖，本批去重不重复添加 | ✅ 2026-09-07 |
| B26 | IPS 崩溃报告解析直测 5 断言（首行头丢弃/多行 JSON 保留/非法与空输入回退）| ✅ 2026-09-07 |
| 热修复 | B26 合并（68cb44b）冲突解决误删 IPS do 块闭合 `}`——main 编译断裂（`private` 非 local 报错），阻塞全部并行会话；814f63a 补括号 + B24 var→let 警告修复，合并并行 Batch 20 后三门禁全绿（构建零警告 + Runner 623/623 + run_all_tests 75/75）推送 78d22b2。**教训入册：合并冲突删标记行后必须跑构建门禁再推送** | ✅ 2026-09-07 |
| B28 | 缺口审计（全 Sources 类型 vs 测试符号对照）后 Overlay 偏好层 + Space 解码漂移直测 17 断言：legacy 迁移补默认/字段保真/非法回退、CodableColor 键集锁定+回环保真、IndexPosition 6 形态映射互异、YabaiSpaceInfo is-visible Bool/Int 四态、YabaiDisplayInfo 解析（90d5b13）| ✅ 2026-09-07 |
| B29 | yabai 环境探针全注入直测（三层编排 L1/L2/版本 trim、parseSpaces 宽松语义、locateBinary 候选序）+ YabaiEnvironmentProfile 派生语义穷尽（spaceMoveTrusted 保守策略=v7 float 事故判据）+ decideSessionBindingStep 转直测消镜像，18 断言（df2ac5a）| ✅ 2026-09-07 |
| B30 | ScreenIndexPreferences.load 四源回退链：CF/UserDefaults 两源逐字重复的 decode→enforce→legacy→save 块收敛为 decodeWithLegacyFallback 单一助手（行为逐项对齐，savesLegacyUpgrade 参数供测试避副作用）+ VoiceAnnouncementMode 映射锁定，5 断言（010b1d3）| ✅ 2026-09-07 |
| B31 | Doctor 取证纯逻辑镜像转直测 10 断言：parseJournalLine 三事件行+容错（install 无 pid 占位/未知 kind/junk→nil）、accessibilityFlips 翻转捕获（nil 轴跳过不阻断）、unmatchedLaunches 配对抵消+at 排序（外部击杀实证）、runtimeAXFlipLine 版面守卫（e485523）| ✅ 2026-09-07 |
| B31 后覆盖率复测 | 行覆盖 12.88%（27267 行基数；B19 基线 15.84% 口径相同但分母已扩张——并行功能开发新增大量编排/SwiftUI 代码 + env 门控注册表测试不计入普通运行）。结构指标持续向好：**18 个文件行覆盖 100%**（LayoutFrameCalculator/ToggleFocusBranching/ToggleTriggerGate/ConditionPolling/FloatSettle/YabaiErrorClassifier/OverlayRefreshPolicy/Decision 三兄弟等纯内核族全部满格），函数级满格面更广 | 复测于 2026-09-07 |
| B32 | 依赖注入改造拔除编排层零覆盖根因：SessionWindowRegistry `private init` → `init(store:)`（三文件 12 处 WindowStateStore.shared 硬引用改走注入属性，直构临时 SQLite 即整链直测，无需 env 门控）；CodexHookPreferences 路径/脚本参数化 + install 清理合并段提纯为 mergedHooks 纯函数；直测 21 断言（isInstalled 四态/清理精准/合并保真+开关裁剪；init 剪枝/bind 拒绝/状态操作落库经真临时库），Runner 697→718（ff73ad9）| ✅ 2026-09-07 |
| B33 | Claude 偏好路径注入（claudeSettingsPath/Dir home 注入、isHookInstalled(at:)、uninstall 全参数化+removesHelpers 测试开关）+ SessionStart 前置分流提纯 decideSessionStartRoute 纯函数（handler 双通道收敛单主体）+ 直测 9 断言（安装→卸载回环经临时 settings）；ClaudeHookServer 审计结论=剩余 0% 属 GCDWebServer 第三方编排、DI 价值低缓办（79028dc）| ✅ 2026-09-07 |
| B34 | SettingsUI 拆分前置扫清：34 @State 的决策逻辑提纯为可测纯类型——提示音规则四操作从 SoundManager 单例下沉 SoundPreferences 纯结构（mutating，越界静默语义保留）、节流/免打扰表单钳制同步下沉、端口表单内联三元提纯 ClaudeHookPreferences.clampedUserPort（0=恢复默认）；SoundManager 五操作改委托行为不变；直测 13 断言。**缓办项解除：SettingsView 现可按 section 低风险拆分，状态决策均有纯类型单测兜底**（29b5b63）| ✅ 2026-09-07 |
| B35 | SettingsView section 拆分落地：混杂双域的 SettingsView+Helpers（261 行）拆为 Installations + HookTest；SettingsUI+Helpers（179 行）拆出 SessionLists（余纯展示助手）；HookTest 提纯 buildHookRequest 请求契约与 hookResponseVerdict 四态裁决（nonisolated 纯函数，测试免网络）；直测 12 断言。**B20 缓办项就此闭环：Settings 模块无 300 行以上视图文件，全部按域内聚**（7cef427）| ✅ 2026-09-07 |
| B36 | 全新缺口扫描（符号对照升级：区分零覆盖与仅镜像）后提示音双决策转直测：SoundPlayGate.decide 免打扰四语义（跨午夜/起闭右开/同日窗/无效配置）+ 硬静音优先级 + 节流取整边界（UTC 固定时区注入）、ProjectSoundResolver.resolvedType 首命中/非法跳过/路径归一匹配/全局回落，12 断言（bda04ec）| ✅ 2026-09-08 |
| B37 | 镜像/零覆盖三件套转直测：BuildCapabilities 二进制安全搜索契约（needle 三段命中/summary 登记序/missing 缺失清单——部署互踩 drift 自检）、ScreenLayoutMapper 纯函数全语义（y 翻转/scale 双向约束/胶囊带几何/网格预览等分）、TerminalGridStore store 注入直测（增改删/latest）+ TerminalGridPreferences 钳制回环（显式 0 间距持久=旧 bug 回归锁、标准域先存后还原），22 断言（d44376c）| ✅ 2026-09-08 |
| B38 | 仅镜像/零覆盖收尾批：WindowLayoutManagerProbe.evaluate 双通道探测（name 兜底/运行即安装/conflictSummary 拼接）、HotKeyConfiguration 显示串与冲突表互异 + 默认 ⌃Q 不撞表回归锁、TerminalSelectionResolver.supportLevel 三级别映射、VoiceAnnouncementQueuePolicy.appendedQueue FIFO/满丢最旧/容量防御/值语义、SpacePreferences 默认值与回环，19 断言（b54d1da）| ✅ 2026-09-08 |
| B39 | 并行会话新增镜像转直测：GridSpaceSwitchFeedback.message 三态如实反馈（空工作区失败说明原因不许静默——用户报告回归锁）、TitleEditor 脚本决策层增量加严（转义/定向寻址双哨兵/front 回退/verdict 大小写敏感/诊断 target_gone），12 断言（f4a5d32）| ✅ 2026-09-08 |
| B40 | 双口径扫描收尾：VoiceAnnouncementError 四类 LLM 错误文案互异+状态码插值、SpaceAvailability/LogLevel rawValue 契约，5 断言；审计注记=ToggleRecordStore 为协议抽象（DI 本体）属扫描假阳性，其余零覆盖均为 SwiftUI/App 生命周期/shell 编排豁免项——**可单测面清账完成**（069762e）| ✅ 2026-09-08 |
| B41 | 编排内嵌模板提纯：executeWithAdminPrivileges 的 AppleScript 模板构造（转义防注入+提权包装）提取为 makeAdminShellScript 纯函数（照 TitleEditor 模式，决策与执行分离）+ Doctor.report DoctorPaths 全注入端到端直测（临时 exits.jsonl → 生命周期/最近死亡/无配对现形三段），7 断言（3233816）| ✅ 2026-09-08 |
| B42 | 仅镜像清单最后三类型直测：ClaudeHookEventType 四事件 PascalCase + WindowMoveReason 三原因 snake_case（线上 JSON 契约）、VoiceAnnouncementPreferences 默认实例 Codable 回环、TitleEditorPreferences 双开关默认开+显式关闭；教训入册=Optional 链比较中 `.none` 解析为 Optional.none 而非枚举同名 case，断言须显式限定枚举类型，5 断言（6abfaea）| ✅ 2026-09-08 |
| B43 | CoordinateKit 纯函数补齐直测（原仅 E2E 门控消费、普通运行零覆盖）：originDrift/sizeDrift 曼哈顿漂移和（2.16a 第十二刀唯一公式）、isSizeConverged/isFrameConverged 漂移和判据回归锁（逐轴合计超调不许收敛——apply/PostMove 自我打架史）、clampFrame 尺寸收窄+位置夹回、isOnMainScreen 中心点归属，10 断言（ce0d3d1）| ✅ 2026-09-08 |
| B44 | 大文件按域拆分：ClaudeHookModels.swift（381 行混装窗口模型与 Hook 数据契约两域）拆为 HookWindowModels.swift（窗口身份/状态/ToggleRecord，192 行）+ 瘦身后 ClaudeHookModels.swift（EventType/TerminalContext/Payload/Response，195 行）；纯文件搬移零行为变更，两域类型均有 Runner 直测兜底（28ee38f）| ✅ 2026-09-08 |
| B45 | HotKeyManager.validate 提纯为 nonisolated static validationError(for:)（修饰键要求 + knownConflicts 查表唯一事实源），两处调用点静态化行为不变；Runner 内同语义镜像 hotKeyPassesSystemConflicts 删除、校验路径直测真身（无修饰键拒绝/冲突携带原因/默认 ⌃Q 合法/shiftKey 不算修饰），4 断言（16ebc1a）| ✅ 2026-09-08 |
| B46 | resolveSound 解析映射提纯为 SoundManager.soundResolutionPlan 纯函数（none/系统命名音/Bundle 资源名/自定义文件四通道 + 缺失降级 Hero + 显式路径优先级），resolveSound 只剩按计划执行；直测 6 断言免 IO 直锁映射（7f3e94a）| ✅ 2026-09-08 |
| B47 | Doctor.report 全段落端到端补齐（B41 三段之外的六段）：辅助功能授权时间线（当前状态+翻转计数）、疑似外部击杀计数、致命信号现场（存在 size/缺失不存在）、.ips 报告列表、keepalive 尾部回显、构建能力标记段恒在场——DoctorPaths 注入 + 临时夹具零真身 IO，6 断言（17c4a80）| ✅ 2026-09-08 |
| B48 | 双份判据漂移修复：CodexHookInstaller.cleanVibeFocusHooks 内联仅按 command 匹配（url 形态旧条目漏删），统一改调 HookSettingsComposition.stripVibeFocusEntries 唯一判据（url 精确 OR command 含脚本路径），targetURL 传递链补齐 clean/mergedHooks/uninstall 三签名；行为变化=Codex 安装/卸载现会清 url 精确匹配旧 HTTP 条目（与 Claude 侧对齐），断言更新 6 处（c0b4b6e）| ✅ 2026-09-08 |
| B49 | CoordinateKit 按纯净度拆分（330→171+175）：纯坐标数学（标识符/y 换算/clampFrame/漂移判据族，仅 CoreGraphics+Foundation、零 AppKit 触碰）与 NSScreen 查询半区（主屏帧/索引互转/NSApp 枚举）分文件——落实原文件「纯坐标数学」设计声明；纯文件搬移零行为变更，B43/B15 直测兜底（01cdb99）| ✅ 2026-09-08 |
| B50 | keepalive 崩溃裁决判据根治（第三次实证误报后）：2026-09-08 02:40 安装重启（SIGTERM）期间并行派生进程 touch 共享 fatal 文件（mtime 变、size 0→0）再次误判 60s 冷却——(mtime,size) 任一变化判据收敛为「仅 size 差分」（真崩溃必为 CrashSignalHandler O_APPEND 追加、size 必增；mtime 只随行取证不裁决；absent≡0 归档语义；入册误报史 2026-07-12 ×3 + 09-06 + 09-08 全部 size 不变）；生成器函数化 write_wrapper/write_plist + BASH_SOURCE 守卫（可 source 模板库，source 不触碰 launchd）+ 四个运行时注入缝（VIBEFOCUS_KEEPALIVE_OPEN_BIN/_COOLDOWN/_FATAL_LOG/_KLOG，缺省=生产行为不变）；KeepaliveWrapperDecisionTests 以假 open 二进制驱动生成物 7 场景 28 断言（生成器契约/mtime 触碰不误判/真崩溃 respawn+冷却重拉收摊/陈旧复活不误判/缺失→建空文件不误判/无变化基线/缺失→追加判崩溃）+ 真实决策日志隔离性总断言 | ✅ 2026-09-08 |
| 备注 | Tests/XCTest/ 套件在 CLT 环境从未可执行（playbook 2.10），属死重——**2026-09-08 已向用户征询裁决并附事实**（72 文件/10306 行；Package.swift:65 以专用 target 引用但本机不可执行；所锁逻辑已全部被 Runner 814 条真身直测覆盖且更新），用户未即时答复，默认维持保留现状；任何时刻用户回复「删」即 fork worktree 清理 + 三门禁推送。git 历史可找回，未来换完整 Xcode 亦可从历史复活 | 征询于 2026-09-08 |
| 覆盖率复测（B39 后） | 行覆盖 **16.93%**（27371 行基数，函数 23.62%）；较 B31 后复测 12.88% **+4.05pp**——分母微增下覆盖行增长超 1100 行，B32~B39 注入化/直测化与并行会话直测共同贡献；18 文件 100% 满格继续有效 | 复测于 2026-09-08 |
| 覆盖率复测（B50 后） | 行覆盖 **18.09%**（27469 行基数，函数 27.10%、区域 24.88%），较 B39 后 **+1.16pp**——B41~B50 直测 + 并行会话 minimap 几何匹配/标题脚本工作共同贡献。热点结构复核（≥80 cov-lines 且 <40% 清单）：头部几乎全为 SwiftUI 视图豁免类（OverlaySection/ClaudeHookSection/PermissionsSection/LANSettingsView 等 Settings/App 视图文件群）；非豁免头部均有入册结论——SpaceController+Recovery 7.54%（fork/admin 编排本体，纯决策 B4 已直测）、ClaudeHookServer 6.46%（GCDWebServer 第三方编排 B33 缓办）、SoundManager 8.97%（拆分否决+决策 B2/B34/B36/B46 已提纯）、CrashSignalHandler 0%（async-signal 上下文本体不可测）、WindowManager+MoveWindow/TerminalGridController+Restore 0~4%（AX/yabai IO 编排，纯内核已满格）。**与 B40 清账结论一致：无可单测面新增漏洞；后续增量继续走「决策提纯→Runner 直测」模式（随功能演进），文件级行覆盖数字不再作为批次目标** | 复测于 2026-09-08 |
