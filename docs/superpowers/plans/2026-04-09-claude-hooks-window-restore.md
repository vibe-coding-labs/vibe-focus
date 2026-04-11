# Claude Hooks Session-Driven Window Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 支持 ClaudeCode Hooks 驱动的“会话结束自动聚焦窗口到主屏最大化”，并确保每个窗口可通过 `Ctrl+M` 独立恢复到原屏幕/原工作区/原位置和尺寸。

**Architecture:** 在应用内新增本地 Hook 事件接收层（零系统侵入，不自动改用户系统配置），通过 `session_id` 建立“会话 -> 窗口”绑定。`SessionEnd` 到达时，对绑定窗口执行“保存原状态 + 移动到主屏最大化”。恢复继续复用现有 `WindowManager` 状态循环，但扩展状态结构以显式记录屏幕与工作区上下文，支持多窗口并发会话完成后的独立恢复。

**Tech Stack:** Swift, SwiftUI, AppKit Accessibility API, Network framework (`NWListener`), UserDefaults JSON persistence, yabai（可选工作区增强）

---

## Scope And Constraints

- 零系统侵入：不自动写 `~/.claude/settings.json`，只提供 Hook 命令和状态提示。
- 不破坏现有 `Ctrl+M` 行为：手动切换循环必须保持可用。
- 多窗口并发：允许多个 `session_id` 先后完成并堆叠到主屏，恢复时按当前窗口精确匹配。
- yabai 可选：有 yabai 时记录/恢复工作区；无 yabai 时保持纯屏幕与几何恢复。

## Execution Status (2026-04-09)

- 已完成：Task 1 / Task 2 / Task 3 / Task 4 / Task 5
- 部分完成：Task 6（仅完成编译验证）
- 待完成：Task 6 手动回归、Task 7 提交拆分
- 本轮新增加固：`ClaudeHookServer` 已支持分片请求累积解析、请求体大小保护、回环来源校验

## File Structure

**Create**
- `Sources/ClaudeHookModels.swift` (Hook 事件模型、会话绑定模型、持久化 DTO)
- `Sources/ClaudeHookServer.swift` (localhost 事件接收器，解析 `SessionStart/SessionEnd`)
- `Sources/SessionWindowRegistry.swift` (会话与窗口绑定、清理策略、状态查询)
- `Sources/ClaudeHookPreferences.swift` (开关、监听端口、鉴权 token、自动聚焦策略)
- `Resources/claude-session-hook-example.sh` (用户可复制到 Claude Hooks 的示例脚本)

**Modify**
- `Sources/WindowManager.swift` (新增“按窗口标识移动到主屏并保存状态”能力)
- `Sources/WindowManagerSupport.swift` (补充按 `windowID/pid` 查找 AX 窗口与状态捕获)
- `Sources/SpaceController.swift` (补充按窗口查询 display/space 的轻量接口，避免主线程阻塞)
- `Sources/SettingsUI.swift` (Claude Hooks 配置区、连接状态、示例命令复制)
- `Sources/Support.swift` (Hook 相关日志前缀与诊断输出增强)
- `README.md` (新增 Claude Hooks 接入说明和验证步骤)

## Task 1: Lock Event Contract And Safety Boundaries

**Files:**
- Modify: `docs/superpowers/plans/2026-04-09-claude-hooks-window-restore.md`
- Modify: `README.md`

- [x] **Step 1: 固化 Hook 输入契约**

定义最小事件 JSON：
- `event`: `SessionStart` | `SessionEnd`
- `session_id`: 非空字符串
- `timestamp`: 可选，客户端生成
- `source`: 固定 `claude-code-hook`

- [x] **Step 2: 定义鉴权与容错策略**

约束：
- 默认仅监听 `127.0.0.1`
- 支持 `X-VibeFocus-Token`（可选，启用后必须匹配）
- 非法 JSON、缺字段、未知事件统一返回 `4xx` 且不崩溃

- [x] **Step 3: 文档化“零系统侵入”原则**

在 README 明确：
- App 不会修改用户 Claude 配置
- 只提供一条可复制命令供用户手动放入 Hook

## Task 2: Build Session-Window Registry

**Files:**
- Create: `Sources/ClaudeHookModels.swift`
- Create: `Sources/SessionWindowRegistry.swift`
- Modify: `Sources/WindowManager.swift`

- [x] **Step 1: 建立窗口标识模型**

定义 `WindowIdentity`：
- `windowID`
- `pid`
- `bundleIdentifier`
- `title`
- `capturedAt`

- [x] **Step 2: 建立会话绑定模型**

定义 `SessionWindowBinding`：
- `sessionID`
- `windowIdentity`
- `lastSeenAt`
- `isCompleted`

- [x] **Step 3: 实现 SessionStart 绑定逻辑**

行为：
- 捕获当前前台窗口（沿用 AX 路径）
- 更新或创建 `session_id -> windowIdentity`
- 记录时间戳用于过期清理

- [x] **Step 4: 实现清理策略**

策略：
- 会话完成后保留短期记录（例如 30 分钟）便于诊断
- 过期会话定时清理，避免无限增长

## Task 3: Extend WindowManager For Non-Focused Target Windows

**Files:**
- Modify: `Sources/WindowManager.swift`
- Modify: `Sources/WindowManagerSupport.swift`
- Modify: `Sources/SpaceController.swift`

- [x] **Step 1: 新增“按窗口身份解析 AX 窗口”能力**

新增 API（示例）：
- `resolveWindow(identity:) -> AXUIElement?`

匹配优先级：
- `windowID`
- `pid+title+windowNumber`
- 失败返回 nil

- [x] **Step 2: 新增“按目标窗口执行聚焦移动”入口**

新增 API（示例）：
- `moveWindowToMainScreen(identity:reason:)`

要求：
- 先捕获原始 frame、source screen、source space
- 再移动到主屏可见区域最大化
- 保存为 `SavedWindowState`

- [x] **Step 3: 扩展 SavedWindowState 上下文字段**

新增字段（向后兼容可选）：
- `sourceDisplayIndex`
- `sourceDisplayID`
- `targetDisplayIndex`
- `restoreReason` (`manual_hotkey` / `claude_session_end`)
- `sessionID`（可选，便于诊断）

- [x] **Step 4: 保持恢复逻辑兼容**

要求：
- 旧状态数据可解码（新增字段可选）
- `shouldRestoreCurrentWindow()` 仍按当前窗口匹配，不变更用户习惯

## Task 4: Implement Claude Hook Server

**Files:**
- Create: `Sources/ClaudeHookServer.swift`
- Modify: `Sources/SettingsUI.swift`
- Modify: `Sources/Support.swift`

- [x] **Step 1: 实现本地监听器**

功能：
- 应用启动后按开关决定是否监听
- 监听地址 `127.0.0.1:<port>`
- 上报运行状态给 Settings UI

- [x] **Step 2: 实现事件分发**

`SessionStart`:
- 调用 `SessionWindowRegistry.bind(sessionID:frontmostWindow)`

`SessionEnd`:
- 先查绑定窗口
- 找到后调用 `WindowManager.moveWindowToMainScreen(identity:reason:)`
- 未找到则记录告警并返回可诊断响应

- [x] **Step 3: 并发与主线程安全**

要求：
- IO/解析在后台执行
- AX 与窗口操作切回 `@MainActor`
- 同一 `session_id` 的重复 `SessionEnd` 需幂等（已处理则跳过）

## Task 5: Settings UI And Operational UX

**Files:**
- Modify: `Sources/SettingsUI.swift`
- Create: `Resources/claude-session-hook-example.sh`
- Modify: `README.md`

- [x] **Step 1: 新增 Claude Hooks 设置卡片**

字段：
- 启用开关
- 端口
- token（可选）
- 服务状态（Running/Stopped/Error）

- [x] **Step 2: 提供“一键复制 Hook 命令”**

示例命令（文档化，不自动写系统配置）：
- 从 stdin 读 `session_id`
- POST 到 `http://127.0.0.1:<port>/claude/hook`

- [x] **Step 3: 显示最近事件**

展示：
- 最近 `SessionStart/SessionEnd` 时间
- 绑定窗口命中/失败次数
- 最近错误摘要

## Task 6: Verification And Regression Checks

**Files:**
- Test: 手动验证步骤（README + 本计划）

- [x] **Step 1: 编译验证**

Run: `swift build`  
Expected: `Build complete` 且无新增错误

- [ ] **Step 2: 单会话冒烟**

步骤：
1. 启用 Hook 服务
2. 发送 `SessionStart(session_a)` 绑定当前窗口
3. 发送 `SessionEnd(session_a)` 验证窗口移动主屏最大化
4. 对该窗口按 `Ctrl+M`，应恢复原位置尺寸

- [ ] **Step 3: 多会话叠加回归**

步骤：
1. 分别绑定 `session_a/session_b` 到两个不同窗口
2. 依次触发两个 `SessionEnd`
3. 验证两个窗口叠加到主屏
4. 分别聚焦每个窗口按 `Ctrl+M`，均恢复各自原状态

- [ ] **Step 4: yabai 有无双路径验证**

无 yabai：恢复 frame 正确  
有 yabai：恢复到原工作区策略正确（切回或拉回）

- [ ] **Step 5: 权限失败回归**

关闭辅助功能权限后发送事件：  
Expected: 返回失败并提示权限，不崩溃，不污染状态

## Task 7: Commit Strategy

- [ ] **Step 1: 提交核心能力**

```bash
git add Sources/WindowManager.swift Sources/WindowManagerSupport.swift Sources/SpaceController.swift Sources/ClaudeHookModels.swift Sources/SessionWindowRegistry.swift Sources/ClaudeHookServer.swift
git commit -m "feat(hooks): support session-end window focus flow

- add local claude hook receiver and session-window registry
- allow moving bound windows to main screen without frontmost dependency
- persist richer restore context for multi-window overlap recovery

Co-authored-by: Codex <noreply@openai.com>"
```

- [ ] **Step 2: 提交设置与文档**

```bash
git add Sources/SettingsUI.swift Resources/claude-session-hook-example.sh README.md docs/superpowers/plans/2026-04-09-claude-hooks-window-restore.md
git commit -m "feat(hooks): add hook settings and operational docs

- expose hook endpoint status and copyable command in settings
- document zero-intrusion setup and validation flow

Co-authored-by: Codex <noreply@openai.com>"
```

---

## Dependencies

Task 1 -> Task 2 -> Task 3 -> Task 4 -> Task 5 -> Task 6 -> Task 7

## Risks To Watch

- Hook 事件只含 `session_id` 时，窗口绑定依赖 `SessionStart` 时机准确性。
- 某些终端/IDE 窗口在会话期间重建 `windowID`，需 fallback 匹配。
- AX 权限或窗口不可调整时，必须优雅失败并可诊断。
- 多会话并发事件可能乱序，需要幂等与时间戳防抖。

## Task 8: Runtime Hardening (新增)

- [x] **Step 1: 修复 TCP 分片导致的请求解析不完整**
  
状态：`ClaudeHookServer` 从“一次 receive”改为“分片累积 + Content-Length 完整性判断”。

- [x] **Step 2: 增加请求体大小保护**
  
状态：超过 `64KB` 直接返回 `413 payload_too_large`。

- [x] **Step 3: 增加回环来源限制**
  
状态：仅接受 loopback 来源（如 `127.0.0.1` / `::1` / `localhost`），其他来源返回 `403 forbidden_remote`。
