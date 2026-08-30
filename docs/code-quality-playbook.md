# VibeFocus 代码质量治理手册（Playbook）

> **创建时间:** 2026-08-31
> **定位:** 可执行的日常规范 + 治理进度台账。承接并细化
> [2026-07-23-code-quality-improvement.md](2026-07-23-code-quality-improvement.md)
> 中未完成的 Phase 4（大文件拆分）与 Phase 6（文档完善），并新增该计划没有的
> 「场景说明注释」与「样例数据（fixture）」两项要求。
>
> **背景:** 2026-08-31 崩溃诊断（见会话记录）确认：崩溃本身已在 8-11 修复，
> 但排查成本极高的根因之一是「业务逻辑被埋点日志淹没、竞态场景只存在于
> 个别 commit message 里、yabai 输入输出没有样例可对照」。本手册针对这三点。

---

## 一、规范

### 1.1 文件拆分规范

| 规则 | 要求 |
|------|------|
| 行数上限 | 单文件 > 300 行时必须评估拆分；拆分后每个文件单一职责 |
| 命名 | 沿用现有 `类型+职责.swift` 约定（如 `ScreenOverlayManager+Refresh.swift`） |
| 分层 | 每个职责文件头部用 `// MARK: - <层名>` 标明所属层 |
| 禁止 | 纯粹按行数「切段」——拆分边界必须是职责边界（类型 / I/O / 编排 / 纯函数） |

推荐的职责分层（本仓库已自然形成，拆分时向它靠拢）：

```
纯类型与纯函数   → 独立文件，零依赖 AppKit 状态，可被 Standalone 测试直接覆盖
I/O 查询层      → 只做外部进程调用（yabai/HTTP/文件）与 JSON 解析，不做决策
编排层          → 调用 I/O + 应用结果到状态/UI，持有竞态守卫
UI 层           → SwiftUI/AppKit 视图与窗口管理
```

### 1.2 注释规范（场景说明）

公共类型与非平凡的函数必须有 `///` 文档注释，且**必须包含「场景」段**。
模板：

```swift
/// <一句话职责>。
///
/// ## 场景
/// - 触发时机：<谁在什么条件下调用；列出全部调用方>
/// - 并发约束：<是否必须主线程 / 是否可重入 / 与哪些操作互斥>
/// - 竞态风险：<曾发生过的崩溃或错乱场景，以及本函数如何防御>
///
/// ## 样例
/// ```text
/// <输入/输出样例；yabai 类命令给真实 JSON 片段>
/// ```
///
/// - Parameter x: ...
/// - Returns: ...
```

要求：
- 「竞态风险」段是**强制项**（凡是碰 WindowServer / NSScreen / 多线程回调的函数）。
  历史崩溃场景必须写进代码注释，不能只活在 commit message 里。
- 不要写「做了一个 X」式的复述型注释；只写代码本身看不出来的约束、时序、样例。
- 测试文件头部沿用现有三行约定（见 `Tests/XCTest/ScreenHotplugGuardTests.swift`）：

```swift
// Tests/.../FooTests.swift
// Verification: <被验证的行为>
// Sources: Sources/.../Foo.swift
// Run: swift test --filter FooTests
```

### 1.3 样例数据（fixture）规范

| 规则 | 要求 |
|------|------|
| 存放位置 | `Tests/Fixtures/`（JSON/文本），文件名 = 外部系统名 + 场景（如 `yabai-spaces-two-displays.json`） |
| 真实性 | 样例必须取自真实输出（可手工整理），保留真实字段拼写（`is-visible`、`has-focus`） |
| 覆盖变体 | 每类样例至少覆盖：正常态 + 边界态（空数组、缺字段、类型漂移 Int/Bool） |
| 解析可测 | 对外部 JSON 的解析逻辑必须抽成**纯函数**（如 `parse(from:)`），用 fixture 驱动测试；
          禁止把解析内联在 I/O 函数里导致只能 fork 真实进程才能测 |

### 1.4 与 P-INST 埋点的关系

本轮**不删**埋点（Phase 7 待做），但新增/修改代码时遵守：
埋点必须放在函数边界（`defer` 计时），不得把业务逻辑挤成三行一段。
Phase 7 执行时用编译开关 `#if PERF_INSTRUMENT` 收敛，届时按本手册验收。

---

## 二、治理台账

### 2.1 已完成（承接 07-23 计划）

| 项目 | 提交 | 说明 |
|------|------|------|
| Phase 2: final 标记 | 5ee13f6 | 4 个非 final 类 |
| Phase 1: 访问控制（一期） | 9fa4e63 | private 收敛 |
| Phase 6: 关键 API 文档（一期） | d0c9470 | 11 个文件 |

### 2.2 本轮完成（2026-08-31）

| 项目 | 内容 |
|------|------|
| Overlay 查询层拆分 | `ScreenOverlayManager+SpaceIndex.swift`（546 行）拆为：
  `SpaceSnapshot.swift`（纯类型 + Resolver + JSON 解析纯函数）、
  `ScreenOverlayManager+SpaceQuery.swift`（async I/O 查询层）、
  `ScreenOverlayManager+Refresh.swift`（刷新编排层 + 热插拔守卫场景注释） |
| 同步查询死代码删除 | `queryYabaiSpaces` / `queryFocusedSpaceIndex` /
  `getPerScreenSpaceIndex` / `getYabaiDisplayIndex` / `getYabaiSpaceIndex`
  全部为文件外零调用的死代码（async 化后遗留），删除 ≈ 200 行；
  保留 `getYabaiPath()`（async 路径在用） |
| 解析抽纯函数 | `SpaceSnapshot.parse(from:)` / `AllSpaceSnapshot.parse(from:)` 替代
  查询函数里的内联 `JSONSerialization` + `compactMap`，可 fixture 测试 |
| 样例数据 | 新增 `Tests/Fixtures/yabai-spaces-two-displays.json`（真实双屏多 space 样例，
  覆盖 is-visible/has-focus/缺字段变体）+ `SpaceSnapshotParsingTests` |
| 场景注释 | `refreshSpaceIndices` / `applyRefreshResults` / `handleScreenChange` /
  `updateOverlaysInPlace` 补齐「场景/竞态风险/时序」文档（含 2026-08-10 SIGSEGV 时序） |

### 2.3 第二轮完成（2026-08-31 续）

| 项目 | 内容 |
|------|------|
| Toggle 拆分 | `WindowManager+Toggle.swift`（522 行）拆为：
  `+Toggle.swift`（215 行，主编排）、`+Toggle+FocusResolution.swift`（226 行，
  CGWindowList→yabai→AX 三级焦点解析 + `parseFrameString` 纯函数）、
  `+Toggle+Routes.swift`（187 行，stuck/move_to_main 路径）；
  三分支"焦点身份不可缓存（P3.4 回退教训）"与 stuck 死循环 bug 时序写入场景注释 |
| Voice 拆分 | `VoiceAnnouncementManager.swift`（555 行）拆为：
  `VoiceAnnouncementPreferences.swift`（112 行，类型 + `VoiceAnnouncementTemplate.interpolate`
  插值纯函数 + Error）、`+LLMSummary.swift`（191 行，LLM 请求/fallback 链）、
  `+Persistence.swift`（49 行）、主文件 283 行；
  跨文件 extension 需要的可见性放宽已注明（llmTask/speak/preferencesKey） |
| 样例数据 | 新增插值测试 `Tests/Standalone/VoiceAnnouncementTemplateTests.swift`
  （10 项：正常插值/缺失字段兜底/路径形态变体） |
| 场景注释 | toggle 编排（overlay 抑制原因/耗时归因公式）、LLM 并发约束（Task 取消检查）、
  持久化"加载失败不回写"铁律补齐场景段 |

### 2.4 第三轮完成（2026-08-31 续，P1 崩溃修复）

| 项目 | 内容 |
|------|------|
| crashSignalHandler 留 .ips |
  `_exit(128+sig)` 改 `signal(sig, SIG_DFL) + raise(sig)`（async-signal-safe），
  崩溃后 macOS CrashReporter 生成带完整堆栈的 .ips，
  与 CrashContextRecorder.bootstrap 既有的 .ips 解析归因逻辑衔接；
  兜底 `_exit` 防 handler 返回到损坏现场二次崩溃 |
| 崩溃循环熔断 | AppDelegate 启动最早期（归档前）捕获
  `/tmp/vibefocus-crash-fatal.log` mtime → `ScreenOverlayManager.crashLoopSuppressed`；
  60s 内有致命信号则本次启动禁止创建 overlay 窗口
  （showOverlays/updateOverlaysInPlace/startRefreshTimer/handleScreenChange 四处 guard），
  切断"启动→创建 overlay→SIGSEGV→keepalive 拉起→再崩"循环；
  菜单栏/热键/hook 不受影响，下次启动自动恢复 |
| 启动路径改就地更新 | AppDelegate 的 `refreshOverlays()`（全量 close+重建，
  崩溃循环中"启动即崩"的执行者）改 `updateOverlaysInPlace()`；
  全仓 refreshOverlays 调用方自此清零 |
| keepalive 治理 | 新增 `scripts/install-keepalive.sh`：wrapper 循环自管——
  崩溃（fatal 日志非空且 mtime 晚于本次拉起）延迟 60s 重启，
  用户主动 Quit 不再复活；`unload` 子命令卸载。
  注意：机器上现存旧裸 plist（直接 open -W）需手动跑一次本脚本替换，
  替换后行为变更需人工观察一轮 |

### 2.5 第四轮完成（2026-08-31 续，拆分线 P1 收尾）

| 项目 | 内容 |
|------|------|
| MoveWindow 拆分 | `WindowManager+MoveWindow.swift`（423 行）拆为：
  主文件（292 行，moveWindowToMainScreen 编排，含 P2 双路径机制说明）、
  `+MoveWindow+PostMove.swift`（138 行，移动后 size 校验重写 + toggle record 保存，
  含"半屏高 bug 结构性根因"与 rewrite 上限约束）、
  `+WindowResolution.swift`（100 行，WindowIdentity→AX 四级解析） |
| TitleEditor 拆分 | `TitleEditorService.swift`（354 行）拆为：
  主文件（229 行，editTitle/autoSetTitle/applyTitle 三路写编排）、
  `+Channels.swift`（191 行，AX/AppleScript/权限弹窗通道，
  顺手合并两处重复的 AppleScript 转义为 `escapingAppleScriptString` 纯函数） |

### 2.6 第五轮完成（2026-08-31 续，P2 收尾）

| 项目 | 内容 |
|------|------|
| AXHelpers 拆分 | `WindowManager+AXHelpers.swift`（348 行）按读写职责拆为：
  `+AXRead.swift`（128 行，读取原语：windowHandle/windowNumber/title/frame/
  isAttributeSettable，文件头固化"热路径禁 AX frame"铁律）、
  `+AXWrite.swift`（247 行，apply 两阶段写入编排，positionFirst 顺序选择
  承载两个历史 bug 的修复说明） |
| CrashContext 拆分 | `CrashContext.swift`（324 行，文件名已无对应实体）拆为：
  `CrashSignalHandler.swift`（275 行，信号层：FD/双缓冲/handler/安装/归档，
  文件头补三层诊断体系全景图）、`CrashRuntimeSnapshot.swift`（89 行，
  运行时快照层：toggle/hook 双热路径的 PRE-CRASH STATE 数据源） |
| 略超限文件评估 | **结论：三个均不拆**，理由：`ClaudeHookModels.swift`（340 行）是
  8 个强相关领域类型的纯类型集合，拆分降低内聚；`ClaudeHookPreferences.swift`
  （306 行）超上限仅 6 行、默认值唯一源职责单一；
  `SettingsView+ClaudeHookSection.swift`（341 行）SwiftUI 视图拆分会引入
  EnvironmentObject 传递复杂度，待真实新增功能时再拆（P3） |

### 2.7 第六轮完成（2026-08-31 续，分批提交 + 埋点收敛第一阶段）

| 项目 | 内容 |
|------|------|
| 变更集落盘 | 五轮治理 34 文件按主题分 4 批提交：docs（playbook）→ test（fixture +
  swift-testing 修复）→ refactor（六处拆分，零行为变更）→ fix(crash)（P1 修复四项） |
| 埋点收敛第一阶段 | **103 处**标准形态埋点收敛到 `#if PERF_INSTRUMENT`（71 个文件），
  默认构建零埋点开销；`swift build -Xswiftc -DPERF_INSTRUMENT` 启用归因；
  双模式 build + 全量测试验证通过 |
| 收敛工具 | `scripts/condense-perf-instrumentation.py`（defer 式）与
  `condense-perf-elapsed.py`（elapsed 式）：幂等、变量外泄自动跳过、build 作闸门 |
| 保留常开 | 编排函数耗时字段外泄进日志字典的归因埋点（MoveWindow/Toggle/
  HookEventHandler 等 ~160 处）——它们是耗时归因体系的一部分，不收敛 |
| 脚本教训 | 首版 elapsed 脚本把业务语句卷进 #if（已修复：声明行单独成对包裹）；
  批量重跑曾造成 2 文件双重包裹（git checkout 恢复后加幂等保护）——
  机械改写必须以 build 为闸门、小批试点先行 |

### 2.8 第七轮完成（2026-08-31 续，Phase 7 收官 + 单例注入评估）

**埋点第二阶段评估（外泄型归因埋点）**：

脚本扫描（计时变量在 elapsed 之后仍被引用）实测 75 个外泄变量 / 27 文件，
剔除 `logOperationDuration` 返回值（业务日志 API，非埋点）后，
**真实外泄型归因埋点约 47 处**，全部位于 toggle / move / restore 关键路径编排
（MoveWindow 13、ToggleEngine+Restore 6、AXWrite 5、FocusResolution 5、Routes 4、
SpaceController+Context 4、Toggle 3、WindowQuery 3 等）。

**决策：保留常开，不收敛。** 依据：
1. 占比仅 15%，且全部是 2026-07~08 排查副屏 AX 阻塞（ctxMs=1918）、半屏 bug
   （sizeDrift=372）、toggle 卡顿（p2SpaceMoveMs）的直接证据链字段；
2. 收敛需把「计时→累积→fields 字典→finished 日志」整链包 #if，函数体碎片化，
   可读性倒退（违背治理目标）；
3. 其开销与每操作必打的 started/finished 业务日志绑死，单独关闭收益趋零。

**Phase 7 状态：完成。** 最终格局：标准形态埋点 103 处开关化（默认零开销）+
关键路径归因埋点 ~47 处常开 + 其余为业务日志（非埋点）。

**单例注入范围评估（维持 P3 待办，暂不启动）**：

| 单例 | 引用点 | 评估 |
|------|--------|------|
| CrashContextRecorder | 29 | 纯诊断记录器，单例语义合理 |
| WindowManager | 26 | 核心门面，注入需协议抽象 |
| SessionWindowRegistry | 24 | 会话状态中心，注入价值高但影响大 |
| HotKeyManager | 10 | 全局热键状态，07-23 计划已标注"保留" |
| ScreenOverlayManager | 9 | 已有 crashLoopSuppressed 等内部状态 |
| 其余 6 个 | 各 ≤5 | 引用少，随用随改 |

合计 ~120 引用点 × 11 类型。收益（可测性）已被 Standalone 镜像测试模式
部分替代；一次性改造成本 3-5 天且引入协议层间接性。**建议**：不做专项改造，
下一个功能迭代触碰某单例时顺带对其增量注入。

### 2.9 第八轮完成（2026-08-31 续，编译警告清零）

clean build（rm -rf .build）警告 **16 类 → 0**，达成 2.11「零警告」验收项：

| 警告 | 修复 |
|------|------|
| ToggleEngine → ToggleRecordStore conformance crossing | 协议标 `@MainActor`
  （唯一 conformer 为 @MainActor，SQLite 读写不线程安全） |
| NativeSpaceBridge skyLightHandle/_moveWindowFailures 共享可变状态 | enum 标
  `@MainActor`（全部调用方在主线程） |
| CrashSignalHandler 3× 悬垂指针（& 局部数组 → iovec） | 写盘段重构：
  withUnsafeMutableBytes 内取基址 + writev 同作用域，写入行为不变 |
| SettingsView+Helpers completion @Sendable 捕获 | `nonisolated(unsafe)` 绑定
  （原语义即回调线程执行，行为不变） |
| LANHookPreferences getter 内访问自身 | 抽 `persistBindings` 辅助函数 |
| Shortcuts Coordinator doubleValue 非隔离访问 | Coordinator 标 `@MainActor` |
| CrashContextRecorder bootstrap newState 死代码 | **顺带修复真 bug**：成功 ingest
  分支构造的 newState 从未赋给 state（`state?.lastIngestedCrashReport` 在 state 为
  nil 时是 no-op）→ 同一 .ips 报告被重复 ingest；改为 `state = newState` |
| 未使用变量（wm ×2 / 返回值 / guard let db） | 删除或改可用性检查 |

### 2.10 已知环境问题（第一轮发现，未解决）

- **`swift test` 在当前工具链下不可用**：本机仅有 CommandLineTools（Swift 6.2.3，无完整
  Xcode）。两种配置均验证失败——保留显式依赖 `apple/swift-testing 0.7.0` 时
  TestingMacros-tool 链接失败（swift-syntax 符号缺失）；改为使用工具链内建 Testing 时报
  `missing required module '_TestingInternals'`（CLT 未带齐该模块）。
  Package.swift 已按面向未来的方向处理（移除 0.7.0 显式依赖，Swift 6 工具链自带 Testing），
  装完整 Xcode 后 `swift test` 应可直接工作。
- **过渡期验证路径**：`bash Tests/run_all_tests.sh`（Standalone 镜像测试，直接 `swift`
  编译运行，不依赖 swift-testing）——当前 31/31 通过，新增解析逻辑同套件覆盖
  （`Tests/Standalone/SpaceSnapshotParsingStandaloneTests.swift`，18 项检查）。

### 2.11 第九轮完成（2026-08-31 续，替换产物与部署脚本就绪）

| 项目 | 内容 |
|------|------|
| release 产物 | `swift build -c release` + run.sh 同款组装流程脚本化
  （`scripts/build-release.sh`）→ `dist/VibeFocus.app`；
  未触碰运行中的 app 与 ~/Applications |
| 产物验证 | 二进制含新代码标记：CRASH LOOP detected（熔断）、
  Previous crash-fatal record captured（启动捕获）、updateOverlaysInPlace ×2 |
| 部署脚本 | 新增 `scripts/deploy-release.sh`（幂等）：停旧 keepalive → 停 app →
  备份到 ~/Applications/VibeFocus.app.backup-<ts> → ditto 安装 + ad-hoc 签名 +
  去隔离 → 启动 → 安装带熔断 keepalive；含回滚说明 |
| 一键替换 | 用户本机执行 `bash scripts/deploy-release.sh` 即完成 P1 替换 |

### 2.12 待办（按优先级）

| 优先级 | 项目 | 参照 |
|--------|------|------|
| ~~拆分线~~ | **收官（2026-08-31）**：`NativeSpaceBridge.swift`（307 行，SLS 私有类型
  声明共享，拆分散内聚）与 `WindowStateStore+Database.swift`（306 行，单 extension
  数据库层单一职责）评估后均不拆；剩余 >300 行共 5 个文件全部有书面评估结论，
  300 行上限按 1.1 定义为评估触发线而非硬砍线 | 本手册 1.1 |
| ~~P3 埋点收敛~~ | **收官（2026-08-31）**：第一阶段 103 处开关化 + 第二阶段评估
  保留 47 处关键路径归因常开，Phase 7 完成（见 2.8） | 07-23 计划 Phase 7 |
| P3 | 单例依赖注入（11 类型 ~120 引用点，评估见 2.8；不专项改造，随功能迭代增量注入） | 07-23 计划 Phase 3 |
| P1 | 【用户本机一条命令】产物已就绪（`dist/VibeFocus.app`，含全部修复）：
  `bash scripts/deploy-release.sh` —— 停旧 keepalive/进程、备份、安装新 app、
  启动、安装带熔断 keepalive 一次完成（助手侧前置已全部就绪） | 2026-08-31 诊断 |

### 2.13 验收标准

- [ ] 新增/被拆分文件的公共 API 100% 有含「场景」段的文档注释
- [ ] 对外部系统的解析逻辑全部为纯函数 + fixture 测试覆盖
- [x] `swift build` 零警告（2026-08-31 达成，clean build 16 类 → 0）
- [x] `bash Tests/run_all_tests.sh` 全绿（32/32）
      （`swift test` 待 2.4 工具链问题解决后恢复为准入门槛）
- [ ] 单文件 ≤ 300 行（存量逐步收敛，新增代码即时遵守）

---

## 三、拆分操作流程（checklist）

1. 读透目标文件，按 1.1 分层标出职责边界；
2. `git mv` 不适用（Swift 无需移动即改文件组织）——新建目标文件 → 剪切代码 →
   删旧文件；**不改任何行为**（拆分 commit 里禁止混入功能修改）；
3. 为新文件头与关键函数补 1.2 场景注释；
4. 解析/决策逻辑若不可测，顺手抽纯函数 + fixture（1.3）；
5. `swift build` 零警告 + `bash Tests/run_all_tests.sh` 全绿（`swift test` 待 2.3 环境问题解决后纳入）；
6. 更新本手册 2.2/2.3（本轮完成）与 2.5（待办）台账。
