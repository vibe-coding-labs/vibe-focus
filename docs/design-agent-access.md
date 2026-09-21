# 设计提案：双面向产品——让 Agent 与人共用同一能力层

日期：2026-09-21 · 状态：提案（待评审）
关联：`design-rectangle-integration.md`（能力层现状）、`architecture-baseline.md`、B125/B126 乱蹦事故复盘、`docs/troubleshooting-runbook.md`

---

## 1. 定位与问题

vibe-focus 的本质是 **macOS 多终端会话编排层**：窗口进出主屏、网格铺开、布局快照/恢复、
会话↔窗口绑定、完成通知。今天这层能力只有一个受众——**人**，经 GUI（菜单/设置窗/气泡/热键）触达。

Agent（claude code / codex / ZCode 等）目前只有一个**被动、单向、动作固定**的入口：
`POST /claude/hook`（ClaudeHookServer.swift:85）。hook 事件进来后动作被硬编码为四类：
绑定（SessionStart）、拉主屏（Stop/SessionEnd）、归位（UPS）、通知（Notification）。
Agent 不能主动查询状态，更不能执行任意能力——创建网格、捕获/恢复快照、摆位、float、
切 space、改标题全都只有 GUI/热键入口。

**提案核心**：把能力层产品化为正式的 Agent 接口，让产品同时面向两类受众：

> **单一能力层，两种受众，三个通道。**
> 人经 GUI 用它；Agent 经 CLI / HTTP / MCP 用它。每个界面动作都有一个 Agent 等价物。

这不是推倒重来：hook 链（SessionStart 绑定→Stop 拉主屏→UPS 归位）继续原样工作，
它就是 Agent 通道的第一个特例；本提案是把「特例」升格为「正式接口面」。

### 先说清楚「Agent 使用界面」不是什么

不是让 Agent 去点 UI（AX 合成点击 / 合成键注入）。那条路已有实锤边界：
合成鼠标事件无 HID 信用导致激活被推迟（B176 实测）、锁屏合成键探针不可靠、
AX 写操作归真机 E2E。**正确答案是语义接口**：UI 按钮背后调用的方法
（见 §3 能力层清单）本来就是结构化的，把它们原样暴露即可——这正是本提案的全部内容。

---

## 2. 现状资产盘点（2026-09-21 勘察结论）

### 2.1 Agent 侧已有（可复用的地基）

| 资产 | 现状 | 复用方式 |
|---|---|---|
| HTTP 服务 | GCDWebServer，`POST /claude/hook` 单路由，默认 127.0.0.1:39277（ClaudeHookPreferences.swift:18-19） | **命令 API 挂同一 server**，路由并列 |
| Token 门 | query `?token=` / header `X-VibeFocus-Token`，纯函数 `resolveProvidedToken`/`isTokenValid`（ClaudeHookServer+Pure.swift:65/73），401 语义完整 | 命令 API 直接复用同一门 |
| 凭据分发 | `~/.vibefocus/hook-config.json` 已含 port+token（HookInstaller.writeConfigFile:16） | CLI/MCP 桥的凭据现成读取，零新增配置面 |
| CLI 分发架构 | AppEntry.swift `init()` 内「即退式」参数分发：`--diagnose`/`--check-ax`/`--print-remote-install-script`/`--install-claude-hook-project` 等 6 旗标 | 新子命令按同一模式加，不取单实例锁 |
| LAN/远程 | spool 落盘+拉取（RemoteSpoolDrainer）、label→窗口映射（claudeHookRemoteBindings） | 远程 Agent 事件到达的成熟先例 |
| 审计 | AuditLogger（SQLite `window_audit_log`）、SessionActivityTracker（`session-activity.json`） | Agent 触发操作沿用同一记账 |

### 2.2 人侧界面 → 背后动作（Agent 等价物的原料）

| 人的界面 | 人的动作 | 底层方法（file:line） |
|---|---|---|
| 状态栏菜单 | Toggle | `WindowManager.toggle`（WindowManager+Toggle.swift:49） |
| 菜单·摆位子菜单 | 11 种 LayoutAction | `WindowManager.applyLayoutAction`（+Layout.swift:21） |
| 菜单/设置·终端网格 | 创建网格 | `TerminalGridController.createGrid`（TerminalGridController.swift:34） |
| 设置·编排 | 捕获/恢复/删除快照 | `SessionRestoreController.captureCurrentLayout`（:25）/`restoreLayout`（:178）/`removeSnapshot`（:197） |
| minimap 胶囊 | 切屏/切 space | `SpaceController.switchToSpace`（+Switch.swift:195） |
| 设置·工作区 | float 切换 | `SpaceController.setWindowFloat`（+Move.swift:48） |
| ⌃T 标题编辑 | 改窗标题 | `TitleEditorService.applyTitle`（TitleEditorService.swift:237 起；自动版 `autoSetTitle`:194 已是 hook 在用） |
| 设置·Claude 集成 | live 会话列表 | `SessionActivityTracker` + `SessionWindowRegistry` |
| 通知/语音/角标 | 完成告知 | `UserNotificationPoster`、`VoiceAnnouncementManager`、`DockBadgeManager` |
| 气泡历史面板 | 历史查看/回填 | `InputBubbleHistoryStore`（record:139/remove:184） |

### 2.3 Agent 可直读的持久化面

- SQLite `~/.vibefocus/vibefocus.db`（路径可 `VIBEFOCUS_DB_PATH` 覆盖，WindowStateStore+Database.swift:12）：
  `windows` 表（绑定+toggle 单一事实源，含 session_id/orig_*/target_* 全字段）、
  `preferences` KV（含快照 JSON）、`window_audit_log`。CLI 直读已有先例（`--diagnose` 走 sqlite3 READONLY，Doctor.swift:376）。
- `~/.vibefocus/session-activity.json`：live 会话活动快照。
- `~/Library/Logs/VibeFocus/vibefocus.log` + events.jsonl。

### 2.4 明确不存在（本提案要补的缺口）

无 MCP、无 URL scheme、无 AppleScript 入站端点、除 hook 外无任何监听面——
全仓扫描确认（详见勘察记录 §5）。

---

## 3. 三通道架构

```
            ┌────────────────────────────────────────────┐
   人 ────►  │  GUI（菜单/设置/气泡/热键/minimap）          │
            ├────────────────────────────────────────────┤
            │           能 力 层（§2.2 方法全集）          │
            ├────────────────────────────────────────────┤
   Agent ─► │  ① CLI 子命令   ② HTTP 命令 API   ③ MCP 桥  │
            └────────────────────────────────────────────┘
```

三个通道是同一 API 的三种皮，**不做第二套能力实现**（单一事实源契约的延伸）。

### 通道① CLI 子命令（Agent 最顺手，第一批落地）

Agent 天生最擅长 shell；现有即退式分发架构扩展点现成。契约：
JSON 打 stdout（`--json` 默认开，`--pretty` 人读）、错误分类退出码、stderr 只放人读日志。

```bash
VibeFocusHotkeys status                      # 版本/AX/yabai/hook端口/live会话数（--diagnose 的机器可读版）
VibeFocusHotkeys windows list                # CGWindowID/pid/title/app/frame/space/display
VibeFocusHotkeys windows move-main --id 3220 --reason "agent:claude:done"
VibeFocusHotkeys windows layout --preset left-half --id 3220
VibeFocusHotkeys windows float --id 3220 --on|--off
VibeFocusHotkeys grid create --rows 2 --cols 3 [--target display|space]
VibeFocusHotkeys snapshot capture [--name ...] | snapshot list | snapshot restore [--id ...]
VibeFocusHotkeys sessions list               # live 会话面板的 agent 视角
VibeFocusHotkeys space switch --display 1 --index 2
VibeFocusHotkeys title set --id 3220 --text "B311-bubble"
VibeFocusHotkeys notify --text "需要你确认 XXX"
```

**进程边界要点**：CLI 是独立进程，无 AX 授权（AX 绑定 App 签名身份，tccutil 教训）。
- 读类命令：**CLI 本地直读**——CGWindowList（免 AX）+ `~/.vibefocus/vibefocus.db`（Doctor 先例）。
  App 不在跑也能答，agent 排障场景的健壮性来源。
- 写类命令：**转发常驻 App 执行**（`curl` 同源逻辑，凭据读 hook-config.json；App 不可达时
  明确报 `app_not_running` 而不是静默失败）。写操作必须在 App 进程内走完整管线
  （回滚/收敛/审计一样不少），这是安全性而不是权宜。

### 通道② HTTP 命令 API（能力枢纽，CLI 与 MCP 都骑在上面）

在现有 GCDWebServer 上并列挂路由（复用 token 门与 401 语义）：

```
GET  /api/v1/status | /api/v1/windows | /api/v1/windows/{id}
GET  /api/v1/sessions | /api/v1/snapshots
POST /api/v1/windows/{id}/move-main | /layout | /float
POST /api/v1/grid/create
POST /api/v1/snapshots/capture | /api/v1/snapshots/{id}/restore
POST /api/v1/space/switch | /api/v1/title | /api/v1/notify
```

- 每个写端点 = 薄封装调 §2.2 同一批方法；`triggerSource="agent:<client>"`
  一路传进 ToggleEngine/AuditLogger，审计可归因（对齐 B125 复盘「每次移动可追溯」）。
- handler 遵守既有铁律：MainActor 短片泵 RunLoop（B154 先例）、不长时间占主线程（B249 教训）。
- 绑定面：**恒 127.0.0.1**，不随 LAN 模式开放到 0.0.0.0（远程 agent 走 SSH 隧道，见 §7 开放问题）。
- 实现落点：`Sources/Hook/ClaudeHookServer+API.swift`（或平级 `Sources/Api/`），路由注册与 `/claude/hook` 并列。

### 通道③ MCP 桥（行业标准工具面）

claude code / codex / ZCode 等 agent host 原生支持 MCP；tools 是 Agent 生态的通用货币。

- 形态：Package.swift 新增 stdio 可执行 target `VibeFocusMCP`（**独立桥进程**，
  不塞进 App）——桌面 App 暴露 MCP 的标准模式：桥实现 MCP stdio 协议，把 tool 调用
  转成对 `127.0.0.1:<port>/api/v1/*` 的 HTTP 请求，token 读 hook-config.json。
- 选桥而非 App 内嵌的理由：不占 App 主线程、崩溃隔离、MCP 生命周期由 agent host 管理
  （host 起 agent 时拉起桥，App 死了桥能报错而不是一起死）。
- tools 清单与 HTTP 端点一一对应，命名 `vibefocus_windows_list` / `vibefocus_window_move_main` /
  `vibefocus_grid_create` / `vibefocus_snapshot_capture` / `vibefocus_snapshot_restore` /
  `vibefocus_sessions_list` / `vibefocus_space_switch` / `vibefocus_title_set` / `vibefocus_notify` / `vibefocus_status`。
- 安装：设置页「Claude 集成」加「安装 MCP 配置」按钮，写 `~/.claude.json` 的 mcpServers
  或项目级 `.mcp.json`——与现有 hook 一键安装按钮同交互模式（HookInstaller 先例）。

### 落地顺序（依赖决定）

**②读端点 → ①只读命令 → ②写端点+①包装 → ③MCP 桥**。
②是枢纽必须先行；①的读可以不依赖②（直读路径），写必须依赖②；
③纯增量，骑在②上。

---

## 4. 核心叙事：每个界面都有一个 Agent 等价物

| 人的界面（怎么用产品） | Agent 等价物（怎么用同一产品） | 增量价值 |
|---|---|---|
| 看屏幕上的窗口 | `windows list` / `GET /windows`（结构化 JSON） | Agent 现在靠截图/AX 盲猜窗口状态，结构化读通道是**感知**能力的根治 |
| 菜单摆位 11 动作 | `windows layout --preset` | Agent 自排工作区（如 Stop 后自动摆回左半屏） |
| 网格创建按钮 | `grid create` | **旗舰场景**：meta-agent 起 N 个 claude/codex 会话后一键铺 N 格，人在 UI 里干的事 agent 用 API 干 |
| 捕获/恢复快照 | `snapshot capture/restore` | 给 agent 的 **undo**：危险操作前存档、搞砸后一键还原 |
| minimap 点胶囊切 space | `space switch` | Agent 导航工作区（配合既有 live 切换反馈） |
| 历史面板 | `sessions list` | Agent 看到全部会话的 running/done/waiting 态，自行决定接手哪个 |
| ⌃T 改标题 | `title set` | Agent 给窗口起语义名（与 hook 的 autoSetTitle 对称） |
| 通知中心/语音播报 | `notify --text`（反向通道） | **Agent 对人说话**：要确认、报进度；复用 UserNotificationPoster/VoiceAnnouncementManager |
| 设置窗 | `status`（只读；settings 写不开放） | Agent 读配置自适应行为（如得知免打扰时段） |

「每个界面动作都有 Agent 等价物」就是**双面向**的可验收定义；新增界面功能时
（沿用本表对照补齐）同时交付两个皮，作为功能完成的定义之一。

---

## 5. 安全与授权模型

原则：**Agent 与人同级但不越权；人是授权者，也是事后审计者。**

1. **总开关**：设置页新增「Agent 接入」分区，`agentAccessEnabled`（默认**关**）。
   开启是人的一次明确授权动作，与 hook 启用 Toggle 同交互模式。
2. **操作分级**（子开关，默认全关）：
   - **L0 读**（status/windows/sessions/snapshots list）：总开关开即用。读无破坏性。
   - **L1 布局写**（move-main/layout/float/space/title/notify）：需「允许 Agent 摆放窗口」。
     动窗口是用户最敏感的操作（B125 乱蹦事故、B126「UPS 永不搬窗」均为用户最痛点），
     故单独门控；且 move 复用带回滚的 moveWindowToMainScreen 管线，风险兜底现成。
   - **L2 建窗/改局**（grid create / snapshot restore）：会真开终端窗、真跑命令、真重排现有窗。
     需独立子开关 + 设置页明确提示「Agent 将创建真实终端窗口并执行启动命令」。
   - **永不开放**：退出 App、改热键、改安全偏好、卸载 hook、关闭审计。
3. **归因与审计**：写操作 `triggerSource="agent:<client>"` 进 `window_audit_log` 与
   windows 表 toggle_reason；设置页「最近 Agent 操作」列表（读 audit 表，--diagnose 同源）。
   乱蹦必可追溯，这是对 B125 复盘结论的结构性延伸。
4. **限流**：复用 `UPSRateLimiter` 模式（600s/20 次先例）防 agent 循环抖窗。
5. **授权语义**：事前开关授权（不搞每次弹窗——会卡死无人值守 agent 流），事后审计 +
   一键「恢复上次快照」兜底。这符合「全场景自适应」：无人值守时 agent 自主+可审计，
   人在场时人随时可插手（GUI 永远在同能力层之上）。
6. **凭据面**：token 沿用 hook 的 32 位自动生成（ClaudeHookPreferences.ensureTokenGenerated）；
   hook-config.json 是唯一凭据分发点，不新增第二套凭据。

---

## 6. 与既有契约/铁律的兼容清单

| 契约 | 影响 | 处理 |
|---|---|---|
| bundle id 单一事实源 | MCP 桥/CLI 读配置 | 只从 `AppIdentity.bundleID` 域与 hook-config.json 读，不引入第二套身份 |
| run.sh 装包事实源 | 桥/CLI 随 bundle 分发 | run.sh 不动（桥在 App bundle 内 `Contents/MacOS/`，装包天然携带） |
| B126「UPS 永不搬窗」 | agent move 是否违背 | 不违背：该铁律管的是 hook 自动链；agent 显式 move 是用户事前授权的新语义，默认关、可审计 |
| 主线程纪律 | HTTP handler | 短片泵 RunLoop（B154）、不阻塞式长查询（B249） |
| 测试布局 | 新增断言 | 端点决策/参数校验提纯进 Runner 域文件（`Tests/Runner/RunnerApiTests.swift` 新建，extension 结构照现有）；HTTP 回环直测按 B154 壳回环先例；CLI 生成物行为测试按 B50 家法 |
| 覆盖率台账 | 新代码新豁免 | 落地批同步刷新 docs/coverage-exemption-ledger.md 并重新提请签字（台账为活文档） |

---

## 7. 分期路线（批次草案）

- **A1 感知批**：`agentAccessEnabled` 开关 + HTTP 读端点（status/windows/sessions/snapshots）
  + CLI 只读命令（直读路径）。验收：agent 能不靠截图回答「现在有几个窗、各自在哪、哪个会话绑哪个窗」。
- **A2 执行批**：L1 写端点 + CLI 包装 + 审计归因 + 限流。验收：hook 之外，agent 可显式
  move-main/layout/float，audit 可见 `agent:` 前缀归因，真机 E2E（动窗口必真机验证——验收铁律）。
- **A3 编排批**：L2（grid/snapshot restore）+ MCP 桥 target + 设置页 MCP 安装按钮。
  验收：claude code 里 agent 用 `vibefocus_grid_create` 真铺网格。
- **A4 反向通道批**：notify/语音、settings 读、远程 agent（SSH 隧道 or spool 语义扩展）、
  气泡唤起留给后评估（合成注入边界见 B176）。

每批照常：worktree + 三门禁 + 撞号改号 + 真机域 E2E。

---

## 8. 设计决策（2026-09-22 已拍板，不再留开放问题）

1. **命名**：工具前缀 `vibefocus_*`（13 个）；设置页文案「Agent 接入」（与 MCP/hook
   生态语言一致，不用「AI」）。已落地。
2. **L2 确认语义**：事前授权模式——人开一次子开关，agent 直接执行不逐次确认，
   快照兜底 + 审计追溯。理由：逐次确认会卡死无人值守编排流，违背双面向的初衷。已落地。
3. **远程 agent 通道**：SSH 隧道转发 127.0.0.1（命令 API 恒绑本机，不扩攻击面）；
   spool 承载命令留待真实需求出现再评估。A4 批次处理。
4. **气泡唤起**：不开放。涉合成注入边界（B176），且 agent 通知人已有 notify 工具；
   待真实场景出现单独立项。永不开放清单随设置页交付：退出应用/改热键/改安全设置/卸载 hook。

落地序微调记录：A1（感知）+A2（执行）+A3（MCP 桥）已合并交付（feat/agent-access-api），
L1 集快照捕获、标题编辑退后（AX 按窗 ID 寻址管道另批）；A4（语音/设置读/远程）待启动。

---

## 9. 一句话总结

产品已经一半是 Agent 产品了（hook 链就是 Agent 通道的特例）；本提案把另一半补上——
**让 Agent 像人一样主动、完整、可审计地使用同一能力层**：读通道给它眼睛，
写通道给它手，快照给它 undo，notify 给它嘴，MCP 给它进入 Agent 生态的门票。
