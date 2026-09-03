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

**遗留待用户/协调项 ⏸**
- **AX 摆位写 E2E**：重装会打破 TCC 辅助功能授权（本机反复实证），重新授权需要用户
  在系统设置输一次密码；授权后 ⌃⌥ 摆位热键即可全链路走通（写入复用 ⌃Q 日常在用的
  同一 AX 引擎，几何已单测锁定）。
- **应用内网格 E2E**：验证期间主工作区并行会话于 00:12/00:20 提交并重新部署了
  main 构建（部署互踩），按 worktree 规范停止争抢部署；功能分支合入并重装后按 §7
  流程回归即可（建窗/校验/纠偏脚本已逐一真机验证）。
- 踩坑记录：`do script "<会退出的命令>"` 窗口跑完即关（与调试手册 toggle 坑同源），
  网格纯 shell 格必须用空命令。
