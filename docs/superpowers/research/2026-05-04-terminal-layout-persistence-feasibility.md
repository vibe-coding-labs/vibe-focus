# Terminal Layout Persistence — 技术可行性调研

> 调研日期: 2026-05-04

## 需求

持续追踪所有 Terminal 窗口的屏幕 ID + 工作区 ID + 屏幕位置 + 窗口大小，在机器重启后自动恢复完整的终端工作区布局。

## 当前 Claude Hooks 采集能力

### 已配置的 Hook 事件

| Hook 事件 | 触发时机 | 采集数据 | 用途 |
|-----------|---------|---------|------|
| **SessionStart** | Claude Code 启动 | session_id, cwd, model, terminal_ctx (TTY, PPID, WINDOWID, ITERM_SESSION_ID 等) | 绑定 Claude session → Terminal 窗口 |
| **UserPromptSubmit** | 用户提交 prompt | 同上 + 触发窗口位置恢复 | 自动恢复 Terminal 窗口到副屏 |
| **Stop** | Claude Code 停止 | 同上 + 触发窗口移动到主屏 | 最大化主屏窗口 |
| **PostToolUse** | 每次工具调用后 | 工具使用记录 | claude-mem 持久化记忆 |

### Hook Forwarder 数据流

```
Claude Code Event
  → ~/.vibefocus/hook-forwarder.sh
  → 附加 terminal_ctx (TERM_SESSION_ID, ITERM_SESSION_ID, TTY, PPID, WINDOWID 等)
  → HTTP POST → http://127.0.0.1:39277/claude/hook
  → VibeFocus ClaudeHookServer 处理
```

### Terminal Context 变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `TERM_SESSION_ID` | macOS Terminal.app | Terminal session ID |
| `ITERM_SESSION_ID` | iTerm2 | iTerm2 session ID |
| `KITTY_WINDOW_ID` | Kitty | Kitty window ID |
| `WEZTERM_PANE` | WezTerm | WezTerm pane ID |
| `TTY` | `tty` command | 终端设备路径 |
| `PPID` | 环境变量 | 父进程 ID |
| `WINDOWID` | X11/Wayland | 窗口 ID (macOS 上通常为空) |
| `CLAUDE_PROJECT_DIR` | Claude Code | 当前项目目录 |

## VibeFocus 现有窗口追踪能力

### SavedWindowState 数据结构

```swift
struct SavedWindowState: Codable {
    let id: String
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String?
    let windowID: UInt32?           // CGWindowID
    let windowNumber: Int?
    let title: String?
    let originalFrame: RectPayload   // x, y, width, height
    let targetFrame: RectPayload
    let sourceSpaceIndex: Int?       // macOS Space index
    let targetSpaceIndex: Int?
    let sourceYabaiDisplayIndex: Int?
    let sourceDisplaySpaceIndex: Int?
    let sourceDisplayIndex: Int?
    let sourceDisplayID: UInt32?     // CGDirectDisplayID
    let targetDisplayIndex: Int?
    let restoreReason: String?
    let sessionID: String?
    let savedAt: Date                // 24h 过期
}
```

### 已使用的 API

| API | 用途 | 文件 |
|-----|------|------|
| `CGWindowListCopyWindowInfo` | 枚举所有窗口, 获取位置/大小/PID | WindowManager.swift |
| `AXUIElement` | 窗口操控 (移动/缩放) | WindowManagerSupport.swift |
| `NSScreen` | 显示器信息, 主屏检测 | WindowManager.swift |
| `yabai -m query --spaces` | Space 信息查询 | SpaceController.swift |
| `NativeSpaceBridge` (SkyLight) | 跨 Space 窗口移动 | NativeSpaceBridge.swift |
| `NSRunningApplication` | 通过 PID 查找应用 | WindowManagerSupport.swift |

### 现有追踪模式

- **事件驱动** — 仅在 hotkey 或 hook 事件触发时追踪
- **单窗口绑定** — 只追踪 SessionWindowRegistry 绑定的 Claude 终端
- **24h 过期** — SavedWindowState 最大保留 24 小时
- **CGWindowID 作为主键** — 重启后失效

## 技术可行性评估

### 结论: ✅ 完全可行

所有需要的数据获取能力已在 VibeFocus 中实现，核心新增：

1. **定时快照机制** — 每 5 秒轮询 CGWindowList 记录所有 Terminal 窗口
2. **跨重启稳定标识** — (bundleID + title + displayIndex) 替代 CGWindowID
3. **启发式窗口匹配** — 重启后通过 title + position + display 匹配
4. **启动恢复流程** — VibeFocus 启动时自动恢复布局

### 数据获取对照

| 需要的数据 | 现有 API | 可行性 |
|-----------|---------|--------|
| 屏幕 ID | `CGDirectDisplayID` via `NSScreen` | ✅ 已实现 |
| 工作区 ID | `yabai -m query --spaces` / `NativeSpaceBridge` | ✅ 已实现 |
| 屏幕位置 | `kCGWindowBounds` from `CGWindowListCopyWindowInfo` | ✅ 已实现 |
| 窗口大小 | 同上 | ✅ 已实现 |
| 窗口标题 | `kCGWindowName` | ✅ 已实现 |
| App 名称 | `kCGWindowOwnerName` / `NSRunningApplication.bundleIdentifier` | ✅ 已实现 |

### 风险

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| CGWindowID 重启后变化 | 无法直接匹配 | 启发式匹配: title + display + position |
| macOS Space ID 跨重启不稳定 | Space 恢复可能失败 | position + display 作为 fallback |
| yabai 未安装 | 无法获取 Space 信息 | NativeSpaceBridge fallback |
| CGWindowList 轮询开销 | CPU 使用 | 5s 间隔 + 只查 Terminal 类 app + 跳过最小化 |
| Accessibility 权限丢失 | 无法操控窗口 | 权限检查 + 快照仍可记录 |

### 支持的终端应用

| 终端 | Bundle ID | 检测方式 |
|------|-----------|---------|
| Terminal.app | com.apple.Terminal | NSRunningApplication |
| iTerm2 | com.googlecode.iterm2 | NSRunningApplication |
| Kitty | net.kovidgoyal.kitty | NSRunningApplication |
| WezTerm | com.github.wez.wezterm | NSRunningApplication |
| Warp | dev.warp.Warp-Stable | NSRunningApplication |
| Alacritty | io.alacritty | NSRunningApplication |
| Hyper | co.zeit.hyper | NSRunningApplication |
| Tabby | org.tabby | NSRunningApplication |

## 实现计划

见 `docs/superpowers/plans/2026-05-04-terminal-layout-persistence.md` (5 个 Task)
