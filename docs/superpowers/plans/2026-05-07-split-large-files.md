# VibeFocus 大文件拆分重构计划

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将 4 个超过 1000 行的巨型文件按职责拆分为 300-500 行的小文件，提高可维护性。纯结构重构，不改变任何行为。

**Architecture:** 使用 Swift extension 拆分模式（项目已有 WindowManager+XXX.swift 先例）。每个 extension 文件承载 1 个内聚职责。主文件只保留属性声明、init、生命周期方法。拆分顺序：SpaceController → WindowManager → SettingsUI → ScreenOverlayManager，从底层到上层。

**Tech Stack:** Swift 5.9+, macOS 14+, yabai, SQLite

**Risks:**
- SettingsUI.swift 的 SwiftUI View 不能用 extension 拆分 body — 需要用 subview 提取模式
- 拆分后编译可能因 `@MainActor` 隔离或 `private` 访问级别报错 — 缓解：将必要的 `private` 改为 `internal`
- 大量文件移动可能产生 git 历史断裂 — 缓解：每个 Task 完成后立即编译验证 + 提交

---

### Task 1: 拆分 SpaceController.swift (1964 行 → 6 文件)

**Depends on:** None
**Files:**
- Create: `Sources/SpaceController+Query.swift`
- Create: `Sources/SpaceController+Switch.swift`
- Create: `Sources/SpaceController+Move.swift`
- Create: `Sources/SpaceController+Recovery.swift`
- Create: `Sources/SpaceController+Context.swift`
- Modify: `Sources/SpaceController.swift` (删除迁移出的代码)

- [ ] **Step 1: 创建 SpaceController+Query.swift — yabai 查询职责**

从 SpaceController.swift 提取以下方法到新文件：
- `queryFocusedSpace()` (lines 1296-1316)
- `querySpaces(caller:)` (lines 1318-1345)
- `queryWindow(windowID:)` (lines 1347-1382)
- `visibleSpaceIndex(forDisplayIndex:spaces:)` (lines 1384-1403)
- `windowSpaceIndex(windowID:)` (lines 476-492)
- `windowDisplayIndex(windowID:)` (lines 494-510)
- `currentSpaceIndex()` (lines 202-233)

新文件用 `extension SpaceController { }` 包裹，加 `@MainActor`。

- [ ] **Step 2: 创建 SpaceController+Switch.swift — Space 切换职责**

提取以下方法：
- `switchDisplayToSpace(targetSpace:operationID:)` (lines 374-474)
- `focusSpace(_:operationID:)` (lines 861-1078)
- `calculateFocusSteps(targetSpaceIndex:)` (lines 1839-1894)
- `displayCenterCG(spaceIndex:)` (lines 1808-1837)

- [ ] **Step 3: 创建 SpaceController+Move.swift — 窗口移动职责**

提取以下方法：
- `moveWindow(_:toSpaceIndex:focus:operationID:)` (lines 588-820)
- `moveWindowToSpace(windowID:targetSpace:operationID:)` (lines 248-365)
- `verifyWindowMovedToSpace(windowID:targetSpace:operationID:)` (lines 823-858)
- `verifyWindowMovedToSpaceWithRetry(windowID:targetSpace:operationID:)` (lines 842-858)
- `focusWindow(_:operationID:)` (lines 1083-1127)
- `pollUntil(condition:timeout:operationID:)` (lines 235-247)
- `displayVisibleSpace(displayIndex:)` (lines 367-369)

- [ ] **Step 4: 创建 SpaceController+Recovery.swift — SA 恢复职责**

提取以下方法：
- `requestScriptingAdditionLoad()` (lines 1129-1148)
- `checkScriptingAdditionLoaded(yabaiPath:)` (lines 1150-1175)
- `attemptSilentSARecovery(yabaiPath:)` (lines 1177-1191)
- `attemptScriptingAdditionRecovery(trigger:operationID:)` (lines 1595-1690)
- `executeWithAdminPrivileges(_:operationID:)` (lines 1547-1593)
- `locateYabai()` (lines 1193-1294)
- `getYabaiPathFromUserShell()` (lines 1251-1294)

- [ ] **Step 5: 创建 SpaceController+Context.swift — Space 上下文计算职责**

提取以下方法：
- `captureSpaceContext(windowID:operationID:)` (lines 153-200)
- `captureSpaceContext(for:)` (lines 1909-1918)
- `displayLocalSpaceIndex(forGlobalSpaceIndex:displayIndex:spaces:)` (lines 549-586)
- `globalSpaceIndex(displayIndex:localSpaceIndex:)` (lines 512-547)
- `nativeSpaceID(forYabaiIndex:)` (lines 1780-1803)
- `preferredSourceSpace(windowSpace:visibleSpace:fallbackSpace:)` (lines 1405-1411)

- [ ] **Step 6: 清理 SpaceController.swift 主文件**

主文件保留：
- 类型定义 (SpaceAvailability, SpaceRestoreStrategy, SpacePreferences, SpaceContext)
- class 声明 + 属性 + init/deinit (lines 50-83)
- `refreshAvailabilityIfNeeded()` (lines 85-87)
- `refreshAvailability(force:)` (lines 89-151) — 核心生命周期
- `updateEnabledState()` (lines 77-83)
- 辅助方法: `runYabai()`, `runYabaiVariants()`, `runProcess()`, `decodeSingleOrFirst()`, `decodeArray()`, `formatErrorMessage()`, `markOperationError()`, `isScriptingAdditionError()`

从主文件删除所有已迁移到 extension 的方法。

- [ ] **Step 7: 编译验证**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 8: 提交**
Run: `git add Sources/SpaceController*.swift && git commit -m "refactor(space): split SpaceController into 6 files by responsibility"`

---

### Task 2: 拆分 WindowManager.swift (1428 行 → 5 文件)

**Depends on:** Task 1
**Files:**
- Create: `Sources/WindowManager+Toggle.swift`
- Create: `Sources/WindowManager+Restore.swift`
- Create: `Sources/WindowManager+SpaceStrategy.swift`
- Create: `Sources/WindowManager+WindowQuery.swift`
- Modify: `Sources/WindowManager.swift`

- [ ] **Step 1: 创建 WindowManager+WindowQuery.swift — AX 窗口查询职责**

提取以下方法：
- `focusedWindow(for:)` (lines 778-796)
- `validateWindowExists(windowID:)` (lines 798-823)
- `restoreWindow(using:)` (lines 825-900)
- `findWindowByPID(_:windowID:)` (lines 902-934)

- [ ] **Step 2: 创建 WindowManager+Toggle.swift — toggle 决策职责**

提取以下方法：
- `toggle(operationID:triggerSource:)` (lines 140-253)
- `shouldRestoreCurrentWindow()` (lines 652-744)
- `isSavedStateCorrupted(_:)` (lines 746-776)
- `shouldRestoreAcrossSpaces()` (lines 936-977)
- `moveToMainScreen(operationID:triggerSource:)` (lines 255-348)

- [ ] **Step 3: 创建 WindowManager+Restore.swift — restore 执行职责**

提取 `restore(operationID:triggerSource:)` (lines 350-589)

- [ ] **Step 4: 创建 WindowManager+SpaceStrategy.swift — Space 策略职责**

提取以下方法：
- `applySpaceStrategyForRestore(windowID:operationID:triggerSource:)` (lines 979-1397)
- `resolveSourceSpaceIndexForRestore()` (lines 1399-1427)

- [ ] **Step 5: 清理 WindowManager.swift 主文件**

主文件保留：
- 所有属性声明和嵌套类型 (WindowToken, RectPayload, SavedWindowState, ScriptWindowSnapshot)
- init + cleanupStaleStatesWithGracePeriod (lines 96-124)
- `getCurrentWindowFrame(windowID:)` (lines 126-138)
- `getMainScreen()` (lines 591-619)
- `hasAccessibilityPermission()` (lines 621-650)
- `notifyAccessibilityPermissionRequired()` (lines 632-650)

- [ ] **Step 6: 编译验证**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 7: 提交**
Run: `git add Sources/WindowManager*.swift && git commit -m "refactor(wm): split WindowManager into 5 files by responsibility"`

---

### Task 3: 拆分 SettingsUI.swift (2738 行 → 8 文件)

**Depends on:** Task 2
**Files:**
- Create: `Sources/SettingsComponents.swift`
- Create: `Sources/SettingsView+SpacePanel.swift`
- Create: `Sources/SettingsView+RestorePanel.swift`
- Create: `Sources/SettingsView+HookPanel.swift`
- Create: `Sources/SettingsView+OverlayPanel.swift`
- Create: `Sources/SettingsView+SoundPanel.swift`
- Create: `Sources/AppDelegate.swift`
- Modify: `Sources/SettingsUI.swift`

- [ ] **Step 1: 创建 SettingsComponents.swift — 可复用 UI 组件**

提取以下独立组件（它们不依赖 SettingsView 的 @State）：
- `bundledAppIconImage()` (lines 10-20)
- `AppLogoBadge` (lines 22-58)
- `ShortcutRecorderButton` (lines 60-147)
- `ShortcutRecorderView` (lines 149-164)
- `DraggableSlider` (lines 166-224)
- `SettingsCard` (lines 226-256)
- `CodeBlockView` (lines 258-328)
- `SettingsStatusPill` (lines 330-345)
- `SidebarInfoCard` (lines 347-362)
- `SettingsRow` (lines 364-384)
- `FocusableSettingsWindow` (lines 2137-2141)

- [ ] **Step 2: 创建 SettingsView+SpacePanel.swift — Space/Yabai 设置面板**

提取 Space/Yabai 相关的 ViewBuilder 方法：
- Space integration card (lines 955-1071)
- 将 SettingsView 中 Space 卡片的 body 片段提取为 `spaceCard` 计算属性或 `@ViewBuilder func`

- [ ] **Step 3: 创建 SettingsView+RestorePanel.swift — 恢复与启动设置面板**

提取：
- Login Item card (lines 843-899)
- Shutdown Snapshot card (lines 901-953)

- [ ] **Step 4: 创建 SettingsView+HookPanel.swift — Claude Hook 设置面板**

提取：
- Claude Hook Integration card (lines 1073-1331)
- Claude Hook Test Helpers (lines 1973-2135)

- [ ] **Step 5: 创建 SettingsView+OverlayPanel.swift — 屏幕索引 Overlay 面板**

提取：
- Overlay/Screen Index card (lines 1333-1612)

- [ ] **Step 6: 创建 SettingsView+SoundPanel.swift — 音效设置面板**

提取：
- Sound card (lines 1614-1771)

- [ ] **Step 7: 创建 AppDelegate.swift — 应用生命周期**

提取：
- `VibeFocusApp` @main 入口 (lines 2239-2250)
- `AppDelegate` class 所有代码 (lines 2252-2738)
- `SettingsWindowController` (lines 2143-2237)

- [ ] **Step 8: 清理 SettingsUI.swift 主文件**

主文件保留：
- `SettingsView` struct 声明 + 所有 @State/@AppStorage 属性 (lines 386-569)
- Sidebar body (lines 570-639)
- Hotkey Card (lines 642-679)
- Status/Tips Card (lines 681-704)
- Permissions Card (lines 706-841)
- Modifiers & Lifecycle (lines 1772-1865)
- Duplicate App Helpers (lines 1866-1971)

各 panel 的 body 替换为调用对应 extension 中的 `@ViewBuilder` 方法。

- [ ] **Step 9: 编译验证**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 10: 提交**
Run: `git add Sources/SettingsComponents.swift Sources/SettingsView+*.swift Sources/AppDelegate.swift Sources/SettingsUI.swift && git commit -m "refactor(ui): split SettingsUI into 8 files by responsibility"`

---

### Task 4: 拆分 ScreenOverlayManager.swift (1010 行 → 3 文件)

**Depends on:** Task 3
**Files:**
- Create: `Sources/ScreenOverlayManager+Signal.swift`
- Create: `Sources/ScreenOverlayManager+Display.swift`
- Modify: `Sources/ScreenOverlayManager.swift`

- [ ] **Step 1: 创建 ScreenOverlayManager+Signal.swift — yabai 信号处理**

提取：
- `setupSignalHandler()` (lines 58-75)
- `clearSpaceIndexCache()` (lines 77-85)
- `cancelPendingSignalRefreshes()` (lines 86-93)
- `scheduleSignalFollowUpRefreshes()` (lines 95-111)
- `triggerForceRefresh(reason:)` (lines 113-131)
- `registerYabaiSignals()` (lines 134-181)

- [ ] **Step 2: 创建 ScreenOverlayManager+Display.swift — overlay 显示逻辑**

提取：
- `showOverlays()` (lines 318-338)
- `hideOverlays()` (lines 474-482)
- `updateOverlayPositions()` (lines 484-498)
- `updateOverlaysInPlace()` (lines 437-472)
- `schedulePreferenceSave()` (lines 340-368)
- `schedulePreferenceRefresh()` (lines 370-390)
- `applyPreferenceRefresh(signature:)` (lines 392-435)
- `preferenceSignature(_:)` (lines 500+)
- `uuidForScreen(_:)` (lines 300-316)

- [ ] **Step 3: 清理 ScreenOverlayManager.swift 主文件**

主文件保留：
- class 声明 + 所有 @Published 属性 + init
- `setEnabled(_:)` (lines 237-249)
- `updatePosition(_:)` (lines 250-255)
- `refreshOverlays()` (lines 257-265)
- `suspendAutomaticRefreshes(reason:)` (lines 267-278)
- `resumeAutomaticRefreshes(reason:)` (lines 279-289)
- `flushPendingPreferenceSave(reason:)` (lines 290-297)
- `setupScreenNotifications()` (lines 184-210)
- `startRefreshTimer()` (lines 212-227)
- `handleScreenChange()` (lines 229-234)

- [ ] **Step 4: 编译验证**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 部署验证 — 确保功能不变**
Run: `APP_NAME="VibeFocus" && BUILD_PATH=".build/release/VibeFocusHotkeys" && APP_BUNDLE="$HOME/Applications/$APP_NAME.app" && cp "$BUILD_PATH" "$APP_BUNDLE/Contents/MacOS/VibeFocus" && codesign --force --sign "VibeFocus Local Code Signing" "$APP_BUNDLE" && killall VibeFocus 2>/dev/null; sleep 1 && open ~/Applications/VibeFocus.app && sleep 5 && pgrep -x VibeFocus`
Expected:
  - Exit code: 0
  - VibeFocus 进程正在运行

- [ ] **Step 6: 提交**
Run: `git add Sources/ScreenOverlayManager*.swift && git commit -m "refactor(overlay): split ScreenOverlayManager into 3 files by responsibility"`

---

### Task 5: 最终验证与行数审计

**Depends on:** Task 4
**Files:** None (验证 only)

- [ ] **Step 1: 确认所有文件在 300-500 行范围内**
Run: `cd Sources && wc -l *.swift | sort -rn | head -20`
Expected:
  - 所有文件 <= 500 行
  - 无文件 > 600 行

- [ ] **Step 2: 确认构建和运行正常**
Run: `swift build -c release 2>&1 | tail -3`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: 提交总结**
Run: `git log --oneline -4`
Expected:
  - 4 个 refactor 提交，每个对应一个文件的拆分
