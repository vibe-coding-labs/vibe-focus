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
| ~~P1 替换~~ | **完成（2026-08-31 04:25）**：deploy-release.sh 执行成功——旧进程 1436
  （8-11 构建）终止并备份至 ~/Applications/VibeFocus.app.backup-20260831-042548；
  新进程 98945 运行新 bundle（二进制含 CRASH LOOP 熔断标记），带熔断 keepalive
  （wrapper + plist）已安装并加载。验证：进程 PID/启动时间变化 ✅、二进制标记 ✅、
  无崩溃循环记录（符合预期）✅。部署脚本在执行中修正了 3 个问题：
  SCRIPT_DIR 应取仓库根、pkill 需兼容旧可执行名 VibeFocus、
  keepalive 脚本末尾 echo 引用了 wrapper 内部变量 | 2026-08-31 诊断 |

### 2.13 验收标准

- [ ] 新增/被拆分文件的公共 API 100% 有含「场景」段的文档注释
- [ ] 对外部系统的解析逻辑全部为纯函数 + fixture 测试覆盖
- [x] `swift build` 零警告（2026-08-31 达成，clean build 16 类 → 0）
- [x] `bash Tests/run_all_tests.sh` 全绿（32/32）
      （`swift test` 待 2.4 工具链问题解决后恢复为准入门槛）
- [ ] 单文件 ≤ 300 行（存量逐步收敛，新增代码即时遵守）

### 2.14 追加修复记录（2026-08-31，title-editor Ctrl+T 改名不生效）

- **根因链**（日志考古 + 按键复现 + TCC 实证）：① 5 月 `6333b77` 把
  `NSAppleEventsUsageDescription` 只加进了 `scripts/dev-build.sh`，打包脚本迁移到
  `run.sh`/`build-release.sh` 时丢失 → Info.plist 缺 Usage 描述时 macOS TCC
  **不弹授权框直接静默拒绝** AppleEvent（-1743）；② 三路写对 iTerm2 全废：
  AX not settable + AppleScript -1743 + TTY OSC 被 shell prompt 覆盖 → 标题改不了；
  ③ `showAutomationPermissionAlert` 包 `DispatchQueue.main.async` 在 GCD main
  queue drain 点开 `NSAlert.runModal()` —— 弹窗静默不显示（实测复现），权限缺失
  时用户得不到任何引导。
- **修复**（commit `7e7eac6`）：两个打包脚本的 plist 模板补回
  `NSAppleEventsUsageDescription`；引导弹窗改同步（调用链本就在主线程上下文）+
  每进程只弹一次 + 展示日志。
- **验证**：重建部署后首次改名触发系统 TCC 授权框（文案即 Usage 描述）→ Allow 后
  AppleScript 通道 success、iTerm2 session name 真实变更；授权后常规路径 63ms；
  32/32 测试绿。
- **遗留认知**：iTerm2 的 session name 是否显示在标题栏由该 profile 的
  *Title Components* 决定（用户 Default profile 为 6=Job+Profile，不含 Session
  name）——通道层修复已完备，标题栏可见性属 iTerm2 用户配置；
  Apple Terminal 的 custom title 通道无此问题。
- **教训**：多打包脚本并存时 plist 键是隐性契约——新增 Usage 类 key 必须同步到
  所有 bundle 组装模板（run.sh / build-release.sh / dev-build.sh），并在部署后
  `plutil -p` 抽查实际产物。

---

### 2.15 追加修复记录（2026-09-01，toggle 跨屏切换失效）

- **根因链**（先断言后落码，Tests/AXMoveValidation.swift T0-T4）：用户环境 yabai
  v7.1.18 全部 space 为 float 布局（无 yabairc，v7 默认）；float 布局下
  `window --space` **静默失效**（exit 0 窗口不动，bsp 布局同命令立即生效）——
  toggle 跨屏移动全部落空；失效移动后 AX 写与 yabai float 重摆并发竞争，
  窗口弹回原位/尺寸错乱。
- **修复**（commit 见 09-01）：move_to_main/restore 改为 float 脱管 → settle
  300ms（隔离 yabai 默认重摆）→ `--move abs`+`--resize abs` 直写目标 frame
  （macOS 窗口归属跟随物理位置）→ 写后 400ms 验证不符重写。移动原语
  `moveWindowToFrameViaYabai` 带闭环验证。
- **验证**：T0-T4 全 PASS 后落码；端到端实测窗口从副屏 (966,-437 533x499)
  精确到达主屏 (72,38 1656x1079)；32/32 测试绿。
- **过程教训（反面教材，必须吸取）**：
  1. **禁止无断言的试错式修复**——本轮前半段在未固化事实链的情况下连续改代码
     + 部署 + 按键实验，两次部署错误版本，且实验窗口误触用户环境（space 1 被
     切 bsp 重排、Chrome/ZCode 窗口被 toggle 扔屏）。正确姿势即本轮后半段：
     事实清单（F1-F7）→ 断言脚本（自建/无害夹具窗口）→ 全 PASS → 落码 → 单次
     端到端。
  2. **环境事实先于代码假设**：`yabai --space` 在 bsp 时代的经验不适用于 float
     布局；排查窗口操作类 BUG 第一步先导出环境全貌（yabai --version、
     query --spaces 的 type、query --windows 的 is-floating 分布）。
  3. **日志 success ≠ 事实成功**：yabai exit 0 不代表窗口移动了；所有窗口操作
     后必须读回验证（闭环断言），静默失败要有 WARN/ERROR。
- **遗留**：yabai float 布局 `--space` 失效疑似 yabai 侧 bug（upstream 已有
  v7.1.25），可选升级；restore 对"源 space 为源屏非可见 space"场景退化为回到
  源屏可见 space（float 布局无精确 space 寻址）。

### 2.16 第十轮完成（2026-09-01，逻辑混乱专项重构「四刀」）

> 背景：机械层治理（拆文件/访问控制/警告清零）收官后，全仓扫描发现剩余混乱集中在
> **逻辑层**——同一决策/同一条知识多处各写一套且互相矛盾，是历次 BUG 的根源
> （半屏 sizeDrift、stuck 死循环、跨屏 toggle 失效均源于此）。本轮按风险从小到大
> 分四刀 + 一个独立修复，每刀以 swift build 零警告 + Standalone 测试全绿为闸门独立提交。

| 刀 | 提交 | 内容 |
|------|------|------|
| fix(hook) | 6661712 | installCooldown 只拦截"无变化重装"：此前关开关后 3s 内 applyPreferences 被整体跳过却返回成功，settings.json 残留已禁用 hook（防抖误用于状态收敛的真 bug） |
| 第二刀 refactor(store) | e52c1e0 | **windows 表列所有权收敛**：saveToggleRecord 的 UPDATE 不再写 session_id（手动 toggle 曾把 SessionWindowRegistry 已绑定的 session 在 DB 里抹成 NULL，静默数据丢失）；ToggleRecord 增加 reason 字段，WindowMoveReason 全链透传到 toggle_reason 列（此前硬编码 manual_hotkey，hook 触发的移动审计全错） |
| 第一刀 refactor(toggle) | ff65f95 | **决策统一**：evaluateRestoreDecision 成为决策主实现（输入收集 + 纯函数 decideRestore 出 6-case 枚举），消除"纯函数仅测试引用、生产内联重写一份"的影子决策；ToggleWindowResolution 增加 windowFrame/onMainScreen typed 字段，toggle 路由按 case 分发；删 parseFrameString（CGRect→String→正则解析回 CGRect 的日志字典数据总线）；CoordinateKit.isOnMainScreen(_:mainScreenFrame:) 成为唯一主屏归属判定；finished 日志 mode 字段如实反映 stuck 分支（schema 变更）。新增 ToggleDecisionRoutingTests（26 项）锁定决策树+路由表契约 |
| 第三刀 refactor(restore) | 50c6a04 | **尸体清理**：删恒真条件 `if record.sourceSpace > 0 || true`；删假指标 moved=false/floatMs=0/applyMs=0（诊断日志不再撒谎，改记真实 frameOK）；restore 接收 toggle 已解析的 windowID（消除 toggle 内第 3 次重复 AX 焦点解析，此前违反"禁止中途重新解析焦点"铁律）；双份 restore_success 审计收敛为 ToggleEngine 一处；死代码删除：findBestCandidate（+2 个仅测它的测试文件）、ensureWindowAtFrame、apply(positionFirst:) 死分支、WindowManager.framesMatch、CoordinateKit.quartzFrame、createSyntheticToggleRecord、refreshOverlays()（SIGSEGV 历史执行者）、resolveRestoreRecord（+其测试文件） |
| 第四刀 refactor(space) | 74a4335 | **yabai 层收敛**（净删 259 行）：stuck 解堵从已知静默失效的 `window --space` 迁移到 float→settle→frame 直写已验证路径；删 SpaceController.moveWindow（Strategy 1=静默失效命令，Strategy 2=SLS 权限不足从未可用）与 NativeSpaceBridge 死通道（318 行→60 行）；负缓存修复（命令失败/解码失败不再缓存 2s 冒充"不存在"）；YabaiSpaceInfo/YabaiWindowInfo 布尔字段 Bool/Int 双形态容错解码（yabai 类型漂移防御，此前 Space 层缺防御、yabai 一漂移 toggle 核心路径查询全瘫） |

**过程约束**：全程遵守「试错式修复反面教材」教训（2.15）——先 grep 全仓验证每个
死代码结论为零调用再删；行为等价性靠 RoutingTests 契约 + 既有 33 个 Standalone
测试守护；日志 schema 变更（mode/spaceMoveResult/floatMs/applyMs）在提交信息中明示。

### 2.16a 第十一轮完成（2026-09-01/02，遗留清单清剿「五~十九刀」，重构与单测同批交付）

> ⚠️ 并行会话警示：另一会话同期在 settings/sound 线独立编号「十八/十九/二十刀」
> （settings 线，commit message 刀号与本表不可互比；其会话仍在改写历史，勿以哈希互引）。共享仓多会话并行时
> 禁用 git add -A（第十九刀曾借此把对方 WIP 扫入己方提交，reset 修复时又与对方
> add -A 相撞，最终代码经对方提交入库、台账行以本行存证）。

> 背景与上轮同源：把 2.17 遗留清单里的 P2 全部 + P3 大半清掉，
> 每刀"重构一点就配套新增/完善一点单元测试"（本轮共新增 13 个 Standalone 测试文件、
> 251 项检查），门禁同前：swift build 零警告 + run_all_tests.sh 全绿。

| 刀 | 提交 | 内容 | 配套测试 |
|------|------|------|------|
| 第五刀 refactor(hook) | 7085f77 | **WindowMove 决策统一**（与第一刀同构）：生产 handleWindowMoveTrigger 真正调 decideWindowMove 纯函数；remoteOnly 拒绝前移到一切绑定 IO 之前（此前后置在 self-heal 之后，被拒事件留下 binding 持久化副作用）；新增 httpResponse(for:) 纯函数收敛决策→响应码对照；删 moveBindingToMainScreen（决策上收，双重 onMain 预检收敛为一）；删 alreadyCompleted 死 case、proceed source 死三元、isLocalBinding/hasMachineLabel 死参数 | HookWindowMoveRoutingTests（39 项：决策树 9 case + remoteOnly 顺序契约 + stale 1800 严格边界 + 响应映射表） |
| 第六刀 refactor(settings) | 2658da5 | **restoreStrategy 死设置下线**：pullToCurrent"拉到当前工作区"依赖 yabai v7 float 布局下静默失效的 `window --space`，无法诚实实现（第四刀实证），按"要么消费要么下线"取下线；删 SpaceRestoreStrategy/Picker/@AppStorage 全链，恢复恒为切回原工作区语义，行为零变化 | 5 个 XCTest 文件同步摘除死类型断言 |
| 第七刀 refactor(arch) | b7ee821 | **反向依赖切断**：冷却状态从 HookEventHandler 私有字典抽为中立 MoveCooldownRegistry（Support/），WindowManager restore/move_to_main 后直接写注册表——Hook→Window→Hook 单例环断开（Window/Toggle 目录 grep 零 HookEventHandler 引用）；冷却语义/时长/时序零变化 | MoveCooldownRegistryTests（24 项：30s 严格边界、覆盖写重置、clear 放行、窗口隔离、Stop↔UPS↔手动归位流转） |
| 第八刀 refactor(space) | 472a12f | **YabaiErrorClassifier**：4 处各自裸写的 stderr.contains 收敛为表驱动的六类纯函数分类（SA 缺失/MC 阻塞/无焦点/窗口不存在/未识别/空），大小写不敏感统一、优先级=表序；4 个调用点判定语义与历史一致。spaceMoveTrusted 评估后不强行接线（生产 `window --space` 变更调用已清零，无消费者） | YabaiErrorClassifierTests（16 项：真实 yabai 报错 fixture、大小写漂移、优先级、空白串边界） |
| 第九刀 refactor(timing) | bac8a25 | **WindowSettle 常量表**：9 处裸 usleep（300/400/25/15/150ms）收敛为 5 个带语义命名的常量，两级分组（yabai 级 vs WindowServer 级），注明实测依据与全部使用点；行为零变化，25/15ms 归一留给 frame 收敛循环统一 | WindowSettleTimingTests（11 项：基准值锁定 + 两级不变量 + 有界性） |
| 第十刀 refactor(hook) | 62edeca | **影子决策清尾**：删 decideWindowResolution/WindowResolutionSource（只覆盖 hasBinding 分支、无法表达 self-heal，真实决策在 resolveWindowIdentity 内联且无分歧语义可收敛）与已废弃的 decideRestoreEligibility/RestoreEligibility（UPS 改单向移动后仅测试引用）；连带删 WindowResolutionTests 及另两个测试文件的死类型段落，净 −240 行 | 无新增（删除的是纯死代码及其测试）；全量门禁守护 |
| 第十一步刀 refactor(hook) | d61f5a0 | **会话绑定解析统一**："绑定查找 + machineLabel 自愈 + 注册 + 活性校验"曾于 UPS（resolveWindowIdentity）与 Stop（handleWindowMoveTrigger）各写一份，校验时序漂移（UPS 自愈后不校验）。收敛为 resolveSessionBinding 唯一编排 + SessionBindingOutcome 五态 + decideSessionBindingStep 纯决策；统一不变量"凡交付必先过 verifyBinding"（UPS 行为强化：易主窗口不再下发放移动） | HookSessionBindingTests（23 项：分支顺序、自愈全失败形态、双调用方映射表、端到端序列） |
| 第十二步刀 refactor(window) | d0d2217 | **帧收敛判据统一**（收敛循环统一的安全步）：三份循环各写一种判据（yabai 漂移和 / apply 逐轴 / PostMove 漂移和，曾互相打架），统一为 CoordinateKit 漂移和系列（originDrift/sizeDrift/isSizeConverged/isFrameConverged）唯一事实源；apply 逐轴→漂移和为唯一行为微调（更严格，不再放过 PostMove 会重写的合计超调）；删生产零调用的 framesMatch（第四种判据变体）及其全部测试镜像 + knife-3 遗留的 wm.framesMatch 死测试引用，净 −300 行 | FrameConvergenceTests（18 项：漂移和算法、≤ 边界、漂移和 vs 逐轴差异锁定、半屏高场景） |
| 第十三刀 fix(coord) | c5e045b | **displayContext 副屏归属修正**（2.15"断言脚本先行"执行样例）：Quartz 点直接比 Cocoa frame 仅主屏/垂直对齐副屏碰巧正确，纵向偏移副屏永远 miss → 先做全局 Quartz→Cocoa 变换再比较；NSScreen 数组 0-based 下标被当 yabai 1-based 索引写入 sourceDisplay 审计列（副屏记成主屏）→ 新增 yabaiDisplayIndex(for:)（nsScreen(forYabaiDisplayIndex:) 逆映射）；删生产零调用的 screenForRect/convertQuartzToCocoa。行为变化仅审计列取值（无决策读取方），移动/restore 决策零变化 | DisplayContextTests（15 项：全局变换不变量、多布局归属矩阵、旧判据缺陷防回退断言、yabai 索引 roundtrip） |
| 第十四刀 refactor(window) | f56497c | **帧收敛循环统一**（2.17 收官项）："写 frame→等落定→读回→重写"三份平行实现（moveWindowToFrameViaYabai / writeSizeWithReadback / PostMove rewrite）收敛为 FrameConvergence.convergeFrame 唯一骨架，写机制/读机制/判据/时长由调用点注入；15ms postRewriteSettle 档与 25ms axWriteSettle 同语义归一并入 25ms（保守大值），原常量下线；writeSizeWithReadback inout 五参回传改结果元组。有意微调：PostMove rewrite 读失败 break→重试（与另两处对齐）+ 耗尽新增 exhausted warn；写硬失败短路当轮 settle/read | FrameConvergenceLoopTests（19 项：骨架契约——尝试计数/事件时序 write→settle→read/读失败重试/写失败短路/attempts 归一 + 三调用点策略表 + frame vs size 判据分工）；WindowSettleTimingTests 同步（11→10 项） |
| 第十五刀 refactor(coord) | 864f5e5 | **帧日志描述族统一**：三种帧日志格式串（"x,y WxH" 17 处 / "x,y" 5 处 / "WxH" 3 处）内联散落 7 文件 26 处，收敛为 QuartzRect 描述族唯一事实源（description 既有实现确认为规范 + originDescription/sizeDescription 新增变体，同一 Int() 向零截断语义）；26 处纯接线，abs:x:y yabai CLI 参数格式不动。行为零变化（防漂移测试逐字符断言与历史内联等价） | FrameDescriptionTests（10 项：三变体格式锁、负坐标向零截断语义、组合一致性矩阵、与历史内联逐字符等价防漂移） |
| 第十六刀 refactor / 扫描器驱动 | ad55907 | **零调用/影子函数清扫 + token 纯函数接线**：444 函数全量引用计数扫描，23 候选 triage——影子接线 1 组（ClaudeHookServer token 验证：生产内联改调 resolveProvidedToken/isTokenValid，语义同构零变化，配套 TokenValidationLogicTests 15 项）；删死函数 12 个（displayVisibleSpace/windowSpaceIndex/windowDisplayIndex/isFrameOnExpectedScreen/centerIsInside/screenArray/isCorrupted/SpaceIndexResolver 整枚举/hookCommandExample/normalizeTTY/parseVersion/findBinding）；测试侧清偿 7 个死文件 + 12 处死镜像段。净 −971 行 | TokenValidationLogicTests（15 项：取值优先级/判定契约/接线路径端到端） |
| 第十七刀 fix(hook) | b2103d3 | **hooks 设置编排纯函数化**（逻辑混乱重写 + 覆盖率100% 样例）："VibeFocus hook 条目"判据曾三处各写一份且 install 对用户 settings.json 有破坏性写入——开关关闭时 removeValue 整键删除连带清掉用户自装同事件 hook；merge 整键覆盖丢弃外部条目。收敛为 HookSettingsComposition 四纯函数（识别/摘除/终态编排/判定），install/uninstall/isHookInstalled 全接线，cleanVibeFocusHooks 删除；两个真 bug 修复（外部 hook 一律保留）| HookSettingsCompositionTests（26 项：四函数分支穷尽 + 两 bug 防回退断言） |
| 第十八刀 refactor(window) | acf394b | **TTY 归一化判据统一（十六刀误判清偿）**：normalizeTTY 曾被扫描器判"影子零调用"删除，实为 5 份内联副本掩盖真实消费者。恢复完整版 + 抽出前缀半边 fullDevicePath（iTerm2×3/TitleEditor 共用），6 处全量接线，行为零变化 | TTYNormalizationTests（12 项：两函数分支穷尽 + 精确匹配怪癖锁定 + 组合一致性） |
| 第十九刀 refactor(window) | 随并行会话「fix(sound): SoundManager 播放互斥（第二十刀）」提交入库（哈希被该会话 amend 改写，按提交标题寻址），本会话原作者 | **Claude Code 窗口定位决策纯函数化**：findClaudeCodeWindow 内联的 cwd→项目名提取与三级策略匹配抽为 projectName(fromCwd:)（nil/空/全斜杠→nil，isEmpty 守卫折叠进契约）+ matchClaudeCodeCandidate（返回 candidate+strategy 供分策略日志，hostApp 谓词注入）；顺带修正策略 2 注释的"非主屏幕"doc 漂移（约束从未实现）。行为零变化 | ClaudeCodeWindowMatchTests（24 项：cwd 边界矩阵 11 项/策略顺序与条件穷尽/两条端到端组合） |

### 2.17 待办（第十一轮后的遗留清单，按优先级）

| 优先级 | 项目 | 说明 |
|--------|------|------|
| P3 | 条件等待渐进替换 | 固定 usleep 已全部常量化（WindowSettle）且写读回循环已统一为 convergeFrame 单骨架（第十四刀）——条件等待只需在骨架的 sleep/read 缝隙做文章（轮询 frame 稳定代替固定等待，moveWindowToFrameViaYabai 另可轮询 isFloating）。按 2.15 闭环验证思路渐进替换，缩短固定等待的手感损耗；**需真实窗口闭环验证，盲改不做** |

已裁决销项（不再列入待办）：
- Hook 事件决策统一、restoreStrategy 死设置（P2 两项）→ 2.16a 第五/六刀；
- WindowManager→HookEventHandler 反向依赖 → 第七刀 MoveCooldownRegistry；
- YabaiError 分类器 → 第八刀；settle 魔法数 → 第九刀 WindowSettle；
- decideWindowResolution/decideRestoreEligibility 影子 → 第十刀删除；
- UPS/Stop 绑定解析两份编排 → 第十一步刀 resolveSessionBinding；
- 帧收敛判据三种写法 + 死 framesMatch → 第十二步刀 CoordinateKit 漂移和系列；
- CoordinateKit 副屏转换错位 → 第十三刀 displayContext 修正（多屏闭环验证仍建议
  随下次部署做一轮真实双屏 toggle 观察 sourceDisplay 审计列取值）；
- frame 收敛循环三份平行实现 + axWrite(25ms)/postRewrite(15ms) 双档归一 → 第十四刀
  convergeFrame 唯一骨架（判据/时长注入式，条件等待替换时骨架的 sleep/read 即唯一缝隙）；
- 零调用函数/影子纯函数（"extracted for testability" 无生产消费者）→ 第十六刀
  扫描器驱动清扫（引用计数法可复用：全量函数名 grep 计数，defs==refs 即候选）；
- hooks 设置判据三处内联 + install 整键删除外部 hook → 第十七刀
  HookSettingsComposition 纯函数族（换端口后旧 HTTP 条目不识别的判据局限留档，
  变更影响用户文件删除范围，须真实环境验证后另行走刀）；
- TTY 前缀补全 5 处内联 + normalizeTTY 误删 → 第十八刀恢复统一（教训：
  "零调用"候选须先 grep 内联同构逻辑再裁决，扫描器只认函数名不认语义）；
- spaceMoveTrusted 接线 → 评估后不接线：生产 `window --space` 变更类调用已清零
  （第四刀），探测器保留作能力档案（YabaiEnvironmentProfileTests 已覆盖），无消费者不造通道。

---



1. 读透目标文件，按 1.1 分层标出职责边界；
2. `git mv` 不适用（Swift 无需移动即改文件组织）——新建目标文件 → 剪切代码 →
   删旧文件；**不改任何行为**（拆分 commit 里禁止混入功能修改）；
3. 为新文件头与关键函数补 1.2 场景注释；
4. 解析/决策逻辑若不可测，顺手抽纯函数 + fixture（1.3）；
5. `swift build` 零警告 + `bash Tests/run_all_tests.sh` 全绿（`swift test` 待 2.3 环境问题解决后纳入）；
6. 更新本手册 2.2/2.3（本轮完成）与 2.5（待办）台账。
