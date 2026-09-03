# 设计文档：Rectangle 式摆位 + 共存处理 + Terminal 编排

日期：2026-09-03　分支：`feat/rectangle-integration`
状态：已实现（本文件描述落地架构与决策依据）

## 0. 目标与总原则

1. **抄设计，不搬代码**：Rectangle（rxhanson/Rectangle，MIT）是完整 app 的 Xcode 工程
   （纯 AX 直写 + 自家 AccessibilityElement/Defaults 体系 + MASShortcut fork），直接 vendor
   会在 VibeFocus 里养出第二套窗口引擎。本方案只取它的**布局语义**（半屏/四分/最大化/居中/
   换屏）与**贴边交互设计**，实现全部落在 VibeFocus 自己的 AX 双阶段写 + yabai 跨屏闭环上。
2. **共存是真实需求，不是假想**：本机实测 Rectangle.app 正在运行（另有 yabai v7.1.18 作为
   VibeFocus 增强层）。共存策略必须是"自动降级 + 用户显式选择"，不能弹窗骚扰。
3. **Terminal 编排在既有 Hook/TTY 基建上生长**：session↔窗口绑定（SessionWindowRegistry +
   windows 表）、窗口↔TTY 解析、AppleScript 执行模式全部复用，新代码只补
   "建窗/摆格/捕获/恢复"四段。

## 1. LayoutKit（Sources/Layout/，纯函数层）

| 文件 | 内容 |
|---|---|
| `LayoutAction.swift` | 11 个摆位动作：左右上下半屏、四角四分、最大化、居中、下一屏。Carbon hotkey id 固定分配 100+index（与 1=toggle、2=title editor 错开） |
| `LayoutFrameCalculator.swift` | action → Quartz 目标 frame。可见区入参 = `CoordinateKit.quartzVisibleFrame(of:)`；支持留白 gap（0=Rectangle 默认）；居中需要窗口原 frame（保持尺寸、clamp 到可视区） |
| `LayoutHotKeyTable.swift` | action→热键绑定表（UserDefaults JSON）。默认键位对齐 Rectangle 惯例：⌃⌥+方向键/UIJK/Return/C/N |
| `LayoutPreferences.swift` | 总开关、snap gap、共存用户选择（unspecified/keepDisabled/enableAnyway）持久化 |
| `WindowLayoutManagerProbe.swift` | 共存探测：判定核心 `evaluate()` 零 I/O 可单测（照 YabaiEnvironmentProbe 模式），生产入口扫 NSWorkspace.runningApplications + /Applications |

**热键模型泛化（手术式）**：不动既有单值 toggle 键（id=1）与 Ctrl+T（id=2），三层各加一段
查表循环：Carbon 按 id 分派；CGEventTap / NSEvent fallback 在主键不匹配后遍历绑定表。
新增 `HotKeyManager.triggerLayoutActionIfNeeded(_:source:)`（独立去抖状态，不与 toggle 互锁）。

## 2. 摆位执行（Sources/Window/WindowManager+Layout.swift）

`applyLayoutAction(_:triggerSource:operationID:) -> Bool`：

1. 复用 `resolveFocusedWindowForToggle`（CGWindowList→yabai→AX 三级）拿焦点窗口；
2. **原生全屏窗口跳过**（AX "AXFullScreen" 属性 best-effort，读失败 fail-open 不拦截）；
3. 目标屏：半屏/四分/最大化/居中 = 窗口当前屏；`nextDisplay` = NSScreen.screens 环形下一块；
4. frame = `LayoutFrameCalculator`；留白 = `LayoutPreferences.snapGap`；
5. 路由：同屏 → `apply(frame:to:)`（AX 双阶段写）；跨屏 → float 脱管 + settle +
   `moveWindowToFrameViaYabai`（与 moveWindowToMainScreen P2 路径同构）；
   **跨屏摆位继承现有硬约束：需要 yabai**（裸 AX 跨屏写被 WindowServer 钳回源屏，见
   AXWrite.swift:15 注释）。

**与 toggle record 的互操作决策（重要）**：摆位动作**不清除** pending restore record。
理由：核心用户流是 "⌃Q 聚焦 → ⌃⌥→ 摆右半 → ⌃Q 恢复"，若摆位清 record 该流程被破坏；
反向场景（摆位后误恢复）不成立，因为 record 只记录 origFrame，恢复语义依然正确。
摆位不写 record（记录只归 move-to-main 语义，防腐守卫不变）。

## 3. 共存检测与妥善处理

- 冲突名单（name + bundleID 双匹配）：Rectangle、Rectangle Pro、Magnet、Moom、SizeUp、
  Spectacle、Amethyst、Hammerspoon、BetterSnapTool、Swish、Loop。
  **yabai/skhd 不在名单**——yabai 是 VibeFocus 集成的增强层，不是摆位竞品。
- 处理策略（零打扰分级）：
  1. 探测到正在运行的摆位竞品 **且用户未做过显式选择** → VibeFocus 摆位热键自动停用
     （`LayoutPreferences.isEnabled = false`），菜单项保留但标注；
  2. 不弹启动警告框（本机 Rectangle 常驻，开机弹窗是敌意行为）；提示出现在设置页
     "摆位快捷键"卡片（黄条 + 仍要启用按钮）与菜单栏条目；
  3. 用户在设置页显式选择后写 `coexistenceChoice`，之后不再自动改。
- 热键冲突复用既有 `knownConflicts` 机制 + 新增"表内组合键重复"校验。

## 4. Terminal 编排（Sources/TerminalGrid/）

| 文件 | 内容 |
|---|---|
| `TerminalGridModels.swift` | `TerminalGridSnapshot`/`CellSnapshot`（Codable；frame 拆 x/y/w/h 存，回避 CGRect Codable 歧义） |
| `TerminalGridPlanner.swift` | rows×cols（1…4）+ gap → row-major 格子 frames（Quartz，纯函数） |
| `TerminalAutomationScript.swift` | AppleScript 生成器（纯字符串，注入逃逸）：Terminal `do script`+`set bounds`+`tty of tab`；iTerm2 `create window with default profile`+`write text`+`set bounds` |
| `ClaudeSessionLocator.swift` | cwd→`~/.claude/projects/` 目录名映射（实证规则：非 `[A-Za-z0-9_-]` → `-`）；tty→claude 进程→cwd→最新 `<uuid>.jsonl`（文件名即 sessionID） |
| `TerminalGridStore.swift` | 快照列表持久化在 WindowStateStore preferences KV（JSON，ScreenIndexPreferences 模式，零 migration） |
| `TerminalGridPreferences.swift` | rows/cols/目标屏/启动命令/终端 app 偏好（UserDefaults） |
| `TerminalGridController.swift` | 异步编排（osascript 经 ShellRunner 在后台队列） |

**创建网格**：选屏（默认主屏）→ Planner 出格 → 逐格 AppleScript 建窗
（`do script "<启动命令>"` + `set bounds` Cocoa 坐标，Quartz→Cocoa 用
`CoordinateKit.cocoaY(fromQuartzY: maxY)`）→ 逐格回读窗口 id + tty → 存快照。

**捕获布局（记住摆法 + session）**：枚举当前终端 app 在目标屏的窗口（CGWindowList，
layer 0 + isOnScreen）→ 按 y/x 聚类反推 rows×cols → 每窗：
1. sessionID 先查 windows 表（Hook 链路早已持久化 tty/session_id/cwd）；
2. 无记录再走 TTY fallback：`ps -t ttysN` 找 claude 进程 → `lsof` cwd →
   projects 目录最新 jsonl；
3. Terminal.app 的 tty 用 `tty of tab` AppleScript 全量枚举映射；iTerm2 无 tty 暴露，
   依赖 Hook 路径。

**恢复布局（自动 --resume）**：快照的 displayID 失效（断显/换分辨率）时按 rows×cols 在
新屏重排，否则按记录 frame 恢复 → 逐格建窗，命令 = 有 sessionID 则
`claude --resume <id>`，否则用户配置的启动命令 → 回报成功/失败格数。

**权限**：Apple Events 自动化权限（-1743）失败时返回可读错误，设置页给引导文案
（复用 TitleEditor 的处理经验）。

## 5. 入口

- 菜单栏：「摆位」子菜单（11 动作，标题带热键）+「终端网格」子菜单（创建/捕获/恢复）。
- 设置页：快捷键 tab 加「摆位快捷键」卡片（总开关 + 共存警告 + 逐动作录制）；
  工作区 tab 加「终端网格」卡片（行列/目标屏/启动命令/快照列表）。

## 6. 测试策略

- 纯函数全部落 `Tests/Standalone/` 镜像测试（仓库惯例）：LayoutFrameCalculator、
  TerminalGridPlanner、WindowLayoutManagerProbe.evaluate、LayoutHotKeyTable（默认键位
  无重复、Codable round-trip）、ClaudeSessionLocator（目录名映射、jsonl 解析）。
- restore 链路未动 → 不强制 VibeFocusTestRunner，仍加跑确认无回归。
- 窗口移动行为按项目铁律真机闭环：摆位（同屏/跨屏）+ 网格创建 + 捕获 + 恢复。

## 7. 真机验证记录（2026-09-04，三屏实机）

**已闭环验证 ✅**
1. **共存探测**：Rectangle 运行中 → 启动日志 `Coexistence policy disabled layout hotkeys
   conflicts=Rectangle（运行中）`，摆位热键不注册；用户显式选择（defaults
   enableAnyway）后重启 → `Layout hotkeys registered count=11`。
2. **真机发现并修复共生 bug**：启动顺序 HotKeyManager.setup() 先注册 11 键、共存策略
   后置 false 时只改偏好不重注册 → Carbon 层残留"死注册"会吞掉 Rectangle 的按键。
   修复为经 `setLayoutActionsEnabled` 重注册（AppDelegate 启动块）。
3. **热键触发链**：⌃⌥→ 实按 → 日志 `Layout trigger accepted action=rightHalf` →
   applyLayoutAction 入口（当时 AX 未授权 → 按设计优雅失败 + beep + 错误日志）。
4. **网格摆位引擎（重要实证）**：Terminal.app 的 AppleScript `set bounds` 是
   **相对窗口当前屏的局部坐标**语义（请求全局 y=578 → 实落 y=-502 = -1080+578，
   窗口开在副屏时必漂移；重试无效）。实测修正：AppleScript 建窗 → 读回 bounds 校验
   → 漂移 >10px 走 `WindowManager.placeWindow`（float 脱管 + yabai abs 写）纠偏，
   实机读回 {872,578,1726,1118} vs 目标 {872,578,1728,1117}（2px 阴影噪声内）。
5. `tty of tab` 全量枚举脚本真机可用（windowID|tty 映射，windowID == CGWindowNumber）。

**网格全链路 E2E（2026-09-04 凌晨，TestRunner 真机集成测试，VIBEFOCUS_GRID_E2E=1）✅**
- 创建 2×2 网格：4 窗全建、全漂移、yabai 全纠偏（±3px 内）、tty 回填、快照入库
- 捕获布局：11 窗全收、row-major 排序、TT Y 兜底定位到存活 claude 会话
  （38cd1ab3…，ps 找进程 → lsof cwd → projects 目录最新 jsonl 全链路命中）
- 恢复布局：逐格重建 + `claude --resume <sessionID>` 注入，恢复出的
  `claude --resume 38cd1ab3…` 进程真实存活（ps 直接证据 pid 79926）
- E2E 期间修掉两个真 bug：
  1. `do script` 建窗异步竞态——零窗口时紧跟的 `front window` 报 Invalid index(-1719)，
     建窗脚本加"轮询窗口数增加"再摆位；
  2. 捕获用 bounds 精确相等反查窗口——两个窗口叠同一格位时串窗（tty 重复、claude
     窗被挤丢），改为按窗口条目 row-major 排序遍历。
- 经验：向指定后台终端窗口的 REPL 注入文本，`do script "…" in window id N` 直接写
  pty，比合成键盘事件可靠（不吃焦点）。

**自动恢复 + 完整上下文还原（feat/terminal-autorestore，2026-09-04）✅**
- **cwd 还原**：捕获阶段纯 shell 格子也记 cwd（tty → 登录 shell → lsof；实证坑：login
  shell 进程名带前导 `-` 如 "-zsh"，必须剥掉再匹配）；恢复命令升级为
  `cd '<cwd>' && claude --resume <id>`（POSIX 单引号转义，shell 层与 AppleScript 层
  双层逃逸不冲突）。快照实证：/tmp 被捕获为解析路径 /private/tmp。
- **自动恢复规划器**（纯函数 TerminalAutoRestorePlanner）：快照格子 × 活窗口观测
  （CG 枚举 + tty 映射 + claude 存活标记）→ 每格三态：
  `create`（格位空）/ `inject`（活窗口空闲 shell → 原地注入命令，防窗口翻倍）/
  `skipRunning`（claude 还在跑，绝不重复拉起/往 REPL 注入）。
  iTerm2 的 AppleScript window id ≠ CGWindowNumber，无法按 CG id 注入 → 传
  injectEnabled=false 降级为只重建缺失格子。
- **启动钩子**：AppDelegate 启动后延迟 6s 调 runAutoRestoreIfEnabled（每次启动至多
  一次；未勾选/无快照静默返回）；设置页新增总开关 + 快照行「设为开机恢复/取消」。
- **真机 E2E**（VIBEFOCUS_GRID_E2E=1）：捕获含 cwd、跳过运行中 claude（pid 不变）、
  关闭格子重建、resume 进程检测全过；/tmp 往返断言在多轮叠窗环境下 flapy，根因是
  测试环境数十扇同 frame 窗使 frame 匹配不唯一（快照层 /private/tmp 记录已实证），
  干净桌面上即为确定性行为。
- 部署互踩升级警示：功能合入 main 后并行会话随即在真机上测试同一功能，共享
  ~/.vibefocus/vibefocus.db 的快照 KV 成为交叉触发源（我留下的测试快照被对方实例
  恢复出 27 扇窗）。**多会话并行时，测试快照用完必须即删**。

**编排终端自动选择（feat/terminal-auto-select，2026-09-04）✅**
- 需求：编排目标必须对准用户实际常用的终端，而不是盲用 Terminal.app/iTerm2。
- **使用量追踪**（TerminalUsageTracker）：监听 NSWorkspace 激活事件，对已知终端
  （TerminalRegistry 9 款）累计激活次数 + 最近时间，UserDefaults JSON 持久化。
- **选择器**（TerminalSelectionResolver 纯函数）：手动指定 > 自动（支持编排集合内，
  当前在运行优先 → 激活计数 → 最近使用）> 兜底 Terminal.app。支持面三级：
  Terminal=full、iTerm2=partial（无 tty/无 CG 注入，自动恢复降级）、其余=none。
- **UI**：选择器「自动（最近常用）/ Terminal.app · 完整 / iTerm2 · 部分」+「自动检测
  结果」行（含理由与重新检测）+ 常用非支持终端橙色提示（≥5 次激活触发）。
- 真机验证：激活 iTerm2×2 / Terminal×1 → 量表如实记录 → 设置页显示
  "自动：最近常用（累计 22 次激活，当前在运行）"。iTerm2 注入限制已在选择理由与
  文案中明示。

**遗留待用户项 ⏸**
- **⌃⌥ 摆位热键 AX 写 E2E**：唯一剩余验收项。重装打破 TCC 辅助功能授权（每次重装
  都复现），重新授权需用户在系统设置输一次密码。链路其余环节已真机验证：热键触发
  （⌃⌥→ → Layout trigger accepted 日志）、AX 权限门（未授权时优雅失败+beep）、写入
  引擎（apply 与日常 ⌃Q 同函数、跨屏 float+yabai 与网格纠偏同一 floatAndWriteFrame，
  已通过网格 E2E 像素级验证）。授权后按 ⌃⌥U 任取一窗验证即可，日志应出现
  `applyLayoutAction result … ok=true`。
- 踩坑记录：`do script "<会退出的命令>"` 窗口跑完即关（与调试手册 toggle 坑同源），
  网格纯 shell 格必须用空命令；部署互踩期间用 TestRunner 集成测试绕开应用部署完成
  验收（`--target` 不重链可执行产品，构建产物部署必须用 `--product VibeFocusHotkeys`）。
