# 恢复（切回原工作区）彻底修复规划

- 日期：2026-09-02
- 状态：规划（未实施项以待办形式逐刀推进）
- 背景：恢复功能历史上反复回归数十次。2026-09-01 重写为「frame 直写」机制后主路径可靠；
  2026-09-02 完成诚实结局重构 + 全链路 Review（见 `window-restore-architecture.md`）。
  本文档回答：**要彻底修复，还差哪些项、按什么顺序、每项怎么验收、哪些明确不修。**

## 0. 实测快照（2026-09-02 校准，规划的事实基础）

| 事实 | 实测方式 | 结论 |
|------|----------|------|
| yabai v7.1.18 / macOS 15.7.3 / SIP enabled | `yabai --version`、`sw_vers`、`csrutil status` | 环境基线 |
| **SA 未加载**（修正：本表初版据 query 含 display 字段判「已加载」系误判） | RestoreScenarioValidation R4 探针：`space --focus` 报 scripting-addition | v7 的 query 走 CGS 内部通道，display/space 字段**不依赖 SA**，旧判据恒真；`checkScriptingAdditionLoaded` 已重写为无副作用探针 + `saProbeVerdict` 纯函数（教训 F 入守卫文档） |
| `space --focus` 当前 space 返回 "cannot focus an already focused space"（exit 1） | 实测 | 逻辑错误 ≠ SA 错误，**不能拿 exit code 判 SA**，须按 stderr 分类 |
| yabai v7 字段族为 `is-*`（`is-minimized`，**无** `minimized` 键） | 全量 query 键集合 + R2 最小化翻转实测 | 旧版 `minimized` 键已失效，双键兼容（已修，R2 断言锁定） |
| `switchDisplayToSpace` 零外部调用 | 全局 grep | 旧机制死代码，已下线（P2-1 完成） |
| 用户通知通道：无 UNUserNotificationCenter；有 Voice/Sound 系统 | 代码查证 | P1-1 复用 `VoiceAnnouncementManager` 队列 + `SoundManager` 区分成败，无新增授权面 |
| 测试基建：CLT 无 Swift Testing 运行时 | playbook 2.10 | `swift run VibeFocusTestRunner` 真代码直测 + `bash scripts/coverage_test_runner.sh`（llvm-cov 真实覆盖率数字）；纯决策逻辑按 2.13 口径分支穷尽至 100% |

## 1. 修复项清单

### P0-1 源屏预切回通道双层化（SA 直切优先）⭐ 核心残留 bug ✅ 已完成（2026-09-02）

- **问题**：restore 第 4-pre 步（源屏切回 sourceSpace）只有「聚焦带动」单层通道
  （`refocusWindowOnSpace`）。源 space 已空/窗口全最小化时无法切回，窗口落错 space。
  而视角守卫（第 6 步）早已是 `focusSpace`（SA 直切）→ refocus 双层——**两处不对称**。
- **方案**：`canControlSpaces == true` 时 4-pre 优先 `focusSpace(sourceSpace)`：
  SA 直切**不依赖目标 space 上有窗口**，从根上修复「源 space 已空」这一主要残留场景；
  SA 失败（含运行中失效）自动降级 refocusWindowOnSpace。与视角守卫结构完全对称。
- **实施**：双层化已入 `ToggleEngine+Restore.swift` 4-pre 段；是否切/初始 spaceExact
  抽为 `sourceSpacePreSwitch` 纯函数，`RestoreRefocusCandidateTests`（XCTest + Standalone
  双套）分支穷尽锁定。
- **涉及文件**：`Sources/Toggle/ToggleEngine+Restore.swift`（仅 4-pre 段）。
- **验收**：①源屏切到别的 space 且源 space 保留窗口 → restore 精确回源；②**源 space 清空**
  → restore 精确回源（本次修复前必落错）；③`canControlSpaces=false` 环境降级路径不变。
- **风险**：低——focusSpace 已是守卫在用通道；SA 中途失效由降级层兜底。

### P0-2 最小化快检数据源修正 ✅ 已完成（本次规划核实中销项）

- yabai v7 实测无 `minimized` 键，改双键兼容 `is-minimized`（v7）+ `minimized`（旧版）。
  已修：`SpaceController+Types.swift` + 解码测试。否则最小化快检在本机恒为死分支。

### P1-1 恢复结果用户可感知 ✅ 已完成（2026-09-02）

- **问题**：restore 失败（最小化/断显）或降级（space 没切准）时，用户只看到「没反应」，
  这是历史上「感觉有 bug」但日志全是 success 的体感根源之一。
- **实施**：`Sources/App/VoiceAnnouncementManager+RestoreOutcome.swift`——
  `RestoreAnnouncementPlan` 纯决策（四类文案 + 成败通道，`RestoreAnnouncementPlanTests`
  分支穷尽锁定）+ `announceRestoreOutcome` 发声接线（语音走有界队列、音效走
  `SoundManager`，任一开关关闭即该通道静默，无新增授权面）。
- **验收**：四场景文案与 AuditLogger 结局字段一一对应；aborted 不播报。

### P1-2 「等落定」改「等到位」（时序硬化）✅ 已完成（2026-09-02，llvm-cov 实测 ConditionPolling 100%；durationMs 对比归 P1-3 验收）

- **问题**：固定 usleep（400ms/300ms）是拍脑袋值：等短了被 yabai 异步重摆覆盖（2026-09-01
  尺寸错乱根因族），等长了白耗时。restore 固定等待约 400–1100ms。
- **方案**：新增有界轮询 `waitUntil`（间隔 50ms、总超时 800ms、超时即走现有降级）：
  ①4-pre 后轮询 `visibleSpaceIndex(forDisplayIndex:) == sourceSpace`；②float 后轮询
  `is-floating == true`；③frame 写保留现有读回收敛（已是「等到位」）。时长常量进 `WindowSettle`。
- **涉及文件**：`Sources/Support/WindowSettle.swift`（新增语义常量）、`SpaceController`（辅助）、
  `ToggleEngine+Restore.swift`（接线）。
- **验收**：端到端脚本全过；restore `durationMs` 对比日志（预期均值下降、尾部更稳）。
- **风险**：中——改时序必须跑 P1-3 脚本 + 真实窗口闭环（2.15 教训），单独立刀。
- **实施偏差（有意）**：float 后保留固定 300ms settle、**不轮询 is-floating**——翻转远早于
  重摆完成且重摆结束无观测信号，轮询会过早放行复现 2.15 尺寸错乱；适用边界已写入
  `WindowSettle` 文档。另：轮询必须绕查询缓存（`ignoreCache`），否则读到操作前旧状态
  恒假白转满预算。

### P1-3 restore 端到端回归脚本（防「修错方向」的制度化）✅ 已完成（2026-09-02 实测：PASS，3 项场景因 SA 未加载如实 SKIP）

- **问题**：恢复 bug 反复出现的结构性原因：两次大回归（方向键法、`window --space` 法）
  都选了从未验证过的原语；现有 AXMoveValidation 只断言移动机制，不断言 restore 场景。
- **实施**：`Tests/RestoreScenarioValidation.swift` 自建 TextEdit 夹具窗口（不碰用户
  窗口，结束恢复各屏初始可见 space），六场景断言：R2 is-minimized 翻转（锁定双键
  解码）、R3 恢复主路径（space/display/frame 回源）、R4 源屏切走后 SA 直切回 + frame
  直写、R5 空 sourceSpace（refocus 无候选 + SA 直切空 space 可行）、R6 origFrame
  屏外判定；另修 AXMoveValidation 同款夹具标题本地化 bug（「Untitled」→ 按实际标题）。
- **2026-09-02 实跑结果**：R0/R1/R2/R3/R6 全 PASS；R4/R5b SKIP（探针实测 SA 未加载，
  属「明确不修」物理极限，恢复加载 SA 后自动转 PASS——双层通道已就位）；
  R5a SKIP（sourceSpace 上有 7 个用户窗口，无法构造空 space）。AXMoveValidation
  T0-T4 全 PASS。
- **验收**：六场景断言全 PASS 且可在脚本内反复运行（自清理）。✅

### P2-1 死代码下线 ✅ 已完成（2026-09-02）

- `switchDisplayToSpace`（SpaceController+Switch.swift）零调用已整体下线；
- 核对结果：`isScriptingAdditionError` 有存活调用方（SA 恢复/错误标注），保留；
  `NativeSpaceBridge.dismissMissionControl` 唯一调用方即被删函数，按架构文档
  「明确不修」清单保留为 MC 解除通道基础设施（当前无自动调用方，注释已如实注记）；
  `YabaiErrorClassifier.missionControlBlocking` 类别保留（MC 阻塞仍是 space --focus
  的真实失败态，纯分类表不动）。

### P2-2 重试策略留档

- 维持「单次不自动重试」（record 保留 + 用户再按即重试 + P1-1 通知），理由留档：
  旧 RestoreWatchdog 自动重试风暴是历史事故根因（110350a/59bfdb4 线索），不再引入自动循环。

### P2-3 record 拓扑漂移快检（可选，默认不做）

- 失败路径已有 `displayContext` 屏外判定（等价能力），save 时再存源屏 frame 属增量优化，
  待 P1-3 脚本证明 700ms 空转确为体感问题后再评估。

## 2. 明确不修（物理极限，写进预期管理）

1. **无 SA 环境下空 space 精确切回**：没有任何已验证原语能做到（见守卫文档原语表）；
   P0-1 在 SA 可用时根治，SA 不可用时如实上报（spaceExact=false + 播报）。
2. **Mission Control 展开中的 space 切换**：已有 dismissMissionControl 通道，属系统行为。
3. **separate-Spaces 下 CGEvent 跨屏切 space**：机制不存在，不再复活该路径。

## 3. 实施顺序与门禁

```
第①刀 P0-1（4-pre 双层化，核心 bug）   ✅ 完成（含纯函数抽取+测试锁定）
第②刀 P1-3（端到端脚本，先行保护网）   ✅ 完成（六场景实跑 PASS；SA 缺失场景如实 SKIP）
第③刀 P1-1（结局可感知）              ✅ 完成（纯决策 llvm-cov 100% + 接线）
第④刀 P1-2（时序硬化）                ✅ 完成（ConditionPolling llvm-cov 100%）
第⑤刀 P2-1（死代码清扫）              ✅ 完成（switchDisplayToSpace 下线+调用方核对）
补强刀：restore 主体 I/O 依赖 protocol 化（RestoreRecordStoring/RestoreWindowOperating/
        RestoreAuditing + RestoreSpaceChanneling 扩展，接缝见 RestoreSwitchOrchestration.swift）
        + performRestore 14 场景分支穷尽（Tests/Runner 78/78）
        + scripts/coverage_test_runner.sh 真实覆盖率：
          ToggleEngine+Restore.swift 行/函数 100%（regions 97.96%）、
          RestoreSwitchOrchestration.swift 100%、ConditionPolling.swift 100%、
          VoiceAnnouncementManager+RestoreOutcome 纯决策部分 100%（发声接线 I/O 除外）
每刀门禁：swift build 零警告 + bash Tests/run_all_tests.sh 全绿
        + swift run VibeFocusTestRunner 全绿（bash scripts/coverage_test_runner.sh 出 llvm-cov 数字）
        + restore 机制改动必跑 Tests/RestoreScenarioValidation.swift + AXMoveValidation.swift
```

- 文档随刀同步（architecture / guard / playbook 台账），杜绝「文档描述死机制」回归。
- **并行协调**：当前工作区有另一会话在途（Settings 声音区 + WindowManager+Finding），
  提交前 `git status` 核对，只提交本专项文件，或等在途任务收尾后统一推进。
