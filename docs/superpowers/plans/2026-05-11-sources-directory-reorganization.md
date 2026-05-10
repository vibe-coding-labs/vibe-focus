# Sources/ 目录按功能域重新组织

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 `Sources/` 下 77 个扁平源文件按功能域归入 10 个子目录，提高可浏览性和可维护性。纯文件移动，零代码修改。

**Architecture:** 现有文件已按命名自然分组（`WindowManager+*`, `SpaceController+*`, `SettingsView+*`, `HotKeyManager+*` 等）。将其移动到对应功能子目录即可。SPM 的 `path: "Sources"` 配置自动包含所有子目录中的 `.swift` 文件，无需改 Package.swift、无需改任何 import 语句、无需改测试。

**Tech Stack:** Swift 5.9, macOS 13+, Swift Package Manager

**Risks:**
- SPM 子目录可能存在未知限制 → 缓解：Package.swift 已用 `path: "Sources"` 无显式文件列表，子目录自动包含
- git mv 大量文件可能导致 merge 冲突 → 缓解：在 main 分支直接操作，无并行分支

---

## 目标目录结构

```
Sources/
├── App/          (10 files) — 应用生命周期与全局管理器
│   ├── AppDelegate.swift
│   ├── AppDelegate+MenuAndInstance.swift
│   ├── AppLauncher.swift
│   ├── AppLaunchStatus.swift
│   ├── AppLaunchView.swift
│   ├── AppVersion.swift
│   ├── LaunchArguments.swift
│   ├── LaunchHealthChecker.swift
│   ├── LoginItemManager.swift
│   └── SoundManager.swift
├── Hook/         (9 files) — Claude Code Hook 集成
│   ├── ClaudeHookPreferences.swift
│   ├── ClaudeHookModels.swift
│   ├── ClaudeHookServer.swift
│   ├── HookEventHandler.swift
│   ├── HookEventHandler+Remote.swift
│   ├── HookEventHandler+WindowMove.swift
│   ├── LANHookPreferences.swift
│   ├── SessionWindowRegistry.swift
│   └── TerminalAppRegistry.swift
├── HotKey/       (5 files) — 全局快捷键系统
│   ├── HotKeyConfiguration.swift
│   ├── HotKeyManager.swift
│   ├── HotKeyManager+CarbonHotKey.swift
│   ├── HotKeyManager+EventTap.swift
│   └── HotKeyManager+Monitors.swift
├── Overlay/      (6 files) — 屏幕序号显示
│   ├── OverlayWindow.swift
│   ├── ScreenIndexPreferences.swift
│   ├── ScreenOverlayManager.swift
│   ├── ScreenOverlayManager+Display.swift
│   ├── ScreenOverlayManager+Signal.swift
│   └── ScreenOverlayManager+SpaceIndex.swift
├── Settings/     (11 files) — 设置界面
│   ├── SettingsUI.swift
│   ├── SettingsComponents.swift
│   ├── SettingsWindowController.swift
│   ├── SettingsView+ClaudeHookSection.swift
│   ├── SettingsView+Helpers.swift
│   ├── SettingsView+HotKeySection.swift
│   ├── SettingsView+OverlaySection.swift
│   ├── SettingsView+PermissionsSection.swift
│   ├── SettingsView+SoundSection.swift
│   ├── SettingsView+WorkspaceSection.swift
│   └── LANSettingsView.swift
├── Space/        (8 files) — 工作区管理
│   ├── SpaceController.swift
│   ├── SpaceController+Context.swift
│   ├── SpaceController+Move.swift
│   ├── SpaceController+Query.swift
│   ├── SpaceController+Recovery.swift
│   ├── SpaceController+Switch.swift
│   ├── NativeSpaceBridge.swift
│   └── SpaceIndexResolver.swift
├── Support/      (6 files) — 日志、崩溃、工具
│   ├── Support.swift
│   ├── Support+Diagnostics.swift
│   ├── AuditLogger.swift
│   ├── CrashContext.swift
│   ├── CrashContextRecorder.swift
│   └── PreferencesSync.swift
├── TitleEditor/  (3 files) — 终端标题编辑
│   ├── TitleEditorPreferences.swift
│   ├── TitleEditorService.swift
│   └── TitleEditorService+TTYWriter.swift
├── Toggle/       (4 files) — Toggle 引擎与恢复
│   ├── ToggleEngine.swift
│   ├── ShutdownSnapshot.swift
│   ├── ShutdownSnapshotManager.swift
│   └── TerminalRestoreService.swift
└── Window/       (16 files) — 窗口管理与状态存储
    ├── WindowManager.swift
    ├── WindowManager+AXHelpers.swift
    ├── WindowManager+Finding.swift
    ├── WindowManager+MoveWindow.swift
    ├── WindowManager+Restore.swift
    ├── WindowManager+ScreenPosition.swift
    ├── WindowManager+SpaceStrategy.swift
    ├── WindowManager+State.swift
    ├── WindowManager+SystemEvents.swift
    ├── WindowManager+TerminalContext.swift
    ├── WindowManager+Toggle.swift
    ├── WindowManager+WindowQuery.swift
    ├── WindowStateStore.swift
    ├── WindowStateStore+Bindings.swift
    ├── WindowStateStore+Database.swift
    └── WindowStateStore+ToggleRecord.swift
```

---

### Task 1: 创建子目录并移动全部源文件

**Depends on:** None
**Files:**
- Create: 10 subdirectories under `Sources/`
- Move: 77 files from `Sources/` to `Sources/<group>/`

- [ ] **Step 1: 创建 10 个功能子目录**

Run:
```bash
cd Sources && mkdir -p App Hook HotKey Overlay Settings Space Support TitleEditor Toggle Window
```
Expected:
  - Exit code: 0
  - `ls -d Sources/*/` shows 10 directories

- [ ] **Step 2: 移动 App/ 组（10 文件）— 应用生命周期与全局管理器**

Run:
```bash
cd Sources && \
git mv AppDelegate.swift App/ && \
git mv AppDelegate+MenuAndInstance.swift App/ && \
git mv AppLauncher.swift App/ && \
git mv AppLaunchStatus.swift App/ && \
git mv AppLaunchView.swift App/ && \
git mv AppVersion.swift App/ && \
git mv LaunchArguments.swift App/ && \
git mv LaunchHealthChecker.swift App/ && \
git mv LoginItemManager.swift App/ && \
git mv SoundManager.swift App/
```
Expected:
  - Exit code: 0
  - `ls Sources/App/*.swift | wc -l` outputs 10

- [ ] **Step 3: 移动 Hook/ 组（9 文件）— Claude Code Hook 集成**

Run:
```bash
cd Sources && \
git mv ClaudeHookPreferences.swift Hook/ && \
git mv ClaudeHookModels.swift Hook/ && \
git mv ClaudeHookServer.swift Hook/ && \
git mv HookEventHandler.swift Hook/ && \
git mv HookEventHandler+Remote.swift Hook/ && \
git mv HookEventHandler+WindowMove.swift Hook/ && \
git mv LANHookPreferences.swift Hook/ && \
git mv SessionWindowRegistry.swift Hook/ && \
git mv TerminalAppRegistry.swift Hook/
```
Expected:
  - Exit code: 0
  - `ls Sources/Hook/*.swift | wc -l` outputs 9

- [ ] **Step 4: 移动 HotKey/ + Overlay/ 组（11 文件）— 快捷键与屏幕序号**

Run:
```bash
cd Sources && \
git mv HotKeyConfiguration.swift HotKey/ && \
git mv HotKeyManager.swift HotKey/ && \
git mv HotKeyManager+CarbonHotKey.swift HotKey/ && \
git mv HotKeyManager+EventTap.swift HotKey/ && \
git mv HotKeyManager+Monitors.swift HotKey/ && \
git mv OverlayWindow.swift Overlay/ && \
git mv ScreenIndexPreferences.swift Overlay/ && \
git mv ScreenOverlayManager.swift Overlay/ && \
git mv ScreenOverlayManager+Display.swift Overlay/ && \
git mv ScreenOverlayManager+Signal.swift Overlay/ && \
git mv ScreenOverlayManager+SpaceIndex.swift Overlay/
```
Expected:
  - Exit code: 0
  - `ls Sources/HotKey/*.swift | wc -l` outputs 5
  - `ls Sources/Overlay/*.swift | wc -l` outputs 6

- [ ] **Step 5: 移动 Settings/ + Space/ 组（19 文件）— 设置界面与工作区**

Run:
```bash
cd Sources && \
git mv SettingsUI.swift Settings/ && \
git mv SettingsComponents.swift Settings/ && \
git mv SettingsWindowController.swift Settings/ && \
git mv SettingsView+ClaudeHookSection.swift Settings/ && \
git mv SettingsView+Helpers.swift Settings/ && \
git mv SettingsView+HotKeySection.swift Settings/ && \
git mv SettingsView+OverlaySection.swift Settings/ && \
git mv SettingsView+PermissionsSection.swift Settings/ && \
git mv SettingsView+SoundSection.swift Settings/ && \
git mv SettingsView+WorkspaceSection.swift Settings/ && \
git mv LANSettingsView.swift Settings/ && \
git mv SpaceController.swift Space/ && \
git mv SpaceController+Context.swift Space/ && \
git mv SpaceController+Move.swift Space/ && \
git mv SpaceController+Query.swift Space/ && \
git mv SpaceController+Recovery.swift Space/ && \
git mv SpaceController+Switch.swift Space/ && \
git mv NativeSpaceBridge.swift Space/ && \
git mv SpaceIndexResolver.swift Space/
```
Expected:
  - Exit code: 0
  - `ls Sources/Settings/*.swift | wc -l` outputs 11
  - `ls Sources/Space/*.swift | wc -l` outputs 8

- [ ] **Step 6: 移动 Support/ + TitleEditor/ + Toggle/ + Window/ 组（29 文件）— 工具、标题编辑、Toggle、窗口**

Run:
```bash
cd Sources && \
git mv Support.swift Support/ && \
git mv Support+Diagnostics.swift Support/ && \
git mv AuditLogger.swift Support/ && \
git mv CrashContext.swift Support/ && \
git mv CrashContextRecorder.swift Support/ && \
git mv PreferencesSync.swift Support/ && \
git mv TitleEditorPreferences.swift TitleEditor/ && \
git mv TitleEditorService.swift TitleEditor/ && \
git mv TitleEditorService+TTYWriter.swift TitleEditor/ && \
git mv ToggleEngine.swift Toggle/ && \
git mv ShutdownSnapshot.swift Toggle/ && \
git mv ShutdownSnapshotManager.swift Toggle/ && \
git mv TerminalRestoreService.swift Toggle/ && \
git mv WindowManager.swift Window/ && \
git mv WindowManager+AXHelpers.swift Window/ && \
git mv WindowManager+Finding.swift Window/ && \
git mv WindowManager+MoveWindow.swift Window/ && \
git mv WindowManager+Restore.swift Window/ && \
git mv WindowManager+ScreenPosition.swift Window/ && \
git mv WindowManager+SpaceStrategy.swift Window/ && \
git mv WindowManager+State.swift Window/ && \
git mv WindowManager+SystemEvents.swift Window/ && \
git mv WindowManager+TerminalContext.swift Window/ && \
git mv WindowManager+Toggle.swift Window/ && \
git mv WindowManager+WindowQuery.swift Window/ && \
git mv WindowStateStore.swift Window/ && \
git mv WindowStateStore+Bindings.swift Window/ && \
git mv WindowStateStore+Database.swift Window/ && \
git mv WindowStateStore+ToggleRecord.swift Window/
```
Expected:
  - Exit code: 0
  - `ls Sources/Support/*.swift | wc -l` outputs 6
  - `ls Sources/TitleEditor/*.swift | wc -l` outputs 3
  - `ls Sources/Toggle/*.swift | wc -l` outputs 4
  - `ls Sources/Window/*.swift | wc -l` outputs 16
  - `ls Sources/*.swift 2>/dev/null | wc -l` outputs 0 (no files left at root)

- [ ] **Step 7: 验证构建 — 确认所有文件移动后编译正常**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 8: 更新测试文件注释中的路径引用并提交**

Run:
```bash
sed -i '' 's|Sources/TerminalAppRegistry.swift|Sources/Hook/TerminalAppRegistry.swift|g' Tests/Standalone/TerminalAppRegistryTests.swift && \
sed -i '' 's|Sources/ShutdownSnapshot.swift|Sources/Toggle/ShutdownSnapshot.swift|g' Tests/Standalone/ShutdownSnapshotTests.swift && \
git add -A && git commit -m "$(cat <<'EOF'
refactor: organize Sources/ into feature-based subdirectories

Move 77 source files from flat Sources/ into 10 feature directories:
App/ (10), Hook/ (9), HotKey/ (5), Overlay/ (6), Settings/ (11),
Space/ (8), Support/ (6), TitleEditor/ (3), Toggle/ (4), Window/ (16).

No code changes — SPM auto-includes subdirectories.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```
Expected:
  - Exit code: 0
  - `git log --oneline -1` shows the commit

---

## Self-Review Results

| # | Check | Result | Action Taken |
|---|-------|--------|-------------|
| 1 | Header? | PASS | Goal + Architecture + Tech Stack + Risks |
| 2 | Dependencies? | PASS | Single task, no dependencies |
| 3 | File paths? | PASS | 每组列出精确文件列表 |
| 4 | 3-8 Steps/Task? | PASS | 8 steps |
| 5 | New file complete code? | N/A | 无新文件创建（只有目录） |
| 6 | Modify complete function? | N/A | 无代码修改 |
| 7 | Code block size? | N/A | 只有 bash 命令 |
| 8 | No dangling references? | PASS | 所有文件在目录树中有对应位置 |
| 9 | Validation commands? | PASS | 每步有文件计数验证 + Step 7 有 swift build |
| 10 | Coverage complete? | PASS | 77 个文件全部覆盖 |
| 11 | Independent verification? | PASS | 单 task 可独立验证 |
| 12 | No TBD/TODO? | PASS | 无占位符 |
| 13 | No vague instructions? | PASS | 每个 Step 有精确 git mv 命令 |
| 14 | Cross-task consistency? | PASS | 单 task |
| 15 | Save location? | PASS | docs/superpowers/plans/ |

**Status:** ✅ ALL PASS

---

## Execution Selection

**Tasks:** 1
**Dependencies:** None
**User Preference:** none
**Decision:** Inline
**Reasoning:** 1 个 Task，纯 git mv 操作，inline 最快

**Auto-invoking:** 直接执行
