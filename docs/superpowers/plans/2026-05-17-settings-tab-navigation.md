# Settings Tab Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将设置页面从「左侧信息栏 + 右侧长滚动」改为「紧凑头部 + 顶部标签栏 + 按分类显示内容」，消除 35+ 项一条滚动的体验。

**Architecture:** 用户点击 Tab → `@State selectedTab` 更新 → `tabContent` computed property 根据选中 Tab 渲染对应 section 组合。每个 Tab 内部仍用 ScrollView 保证内容溢出时可滚动。侧边栏的静态状态信息精简为紧凑 header（Logo + 版本 + 状态 pill）。

**Tab 分组：**
- 通用（gearshape）：快捷键、权限、开机启动、关机快照
- 工作区（macwindow）：跨工作区、屏幕序号显示
- Claude 集成（link）：Claude Hook、局域网 Hook
- 外观与反馈（paintbrush）：窗口标题编辑、提示音

**Tech Stack:** SwiftUI 5.9, macOS 14+ AppKit

**Risks:**
- Claude 集成 tab 内容最长，可能仍需滚动 → 缓解：每个 tab 内保留 ScrollView，不影响体验
- 删除侧边栏后 3 个计算属性变死代码 → 缓解：Task 2 中一并清理，不影响编译

---

### Task 1: Add Tab Infrastructure to SettingsComponents.swift

**Depends on:** None
**Files:**
- Modify: `Sources/Settings/SettingsComponents.swift:381`（文件末尾追加）

- [ ] **Step 1: 添加 SettingsTab 枚举和 SettingsTabButton 组件 — 定义标签页类型和按钮样式**

文件: `Sources/Settings/SettingsComponents.swift`（在文件末尾 `}` 之后追加）

```swift
// MARK: - Tab Navigation

enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case workspace = "工作区"
    case claudeIntegration = "Claude 集成"
    case appearance = "外观与反馈"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .workspace: return "macwindow"
        case .claudeIntegration: return "link"
        case .appearance: return "paintbrush"
        }
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Settings/SettingsComponents.swift && git commit -m "feat(settings): add SettingsTab enum and SettingsTabButton component"`

---

### Task 2: Rewrite SettingsUI.swift Body — Replace Sidebar with Tab Navigation

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Settings/SettingsUI.swift:94-369`

- [ ] **Step 1: 添加 @State selectedTab — 跟踪当前选中的标签页**

文件: `Sources/Settings/SettingsUI.swift:94`（在 `@State var showFileImporter = false` 之后添加）

```swift
    @State var selectedTab: SettingsTab = .general
```

- [ ] **Step 2: 删除仅用于侧边栏的 3 个计算属性 — 清理死代码**

文件: `Sources/Settings/SettingsUI.swift`

删除以下 3 个计算属性（它们只被已移除的侧边栏使用）：

1. 删除 `loginItemSidebarValue`（第 106-114 行）
2. 删除 `spaceEffectiveEnabled`（第 132-134 行）
3. 删除 `spaceSidebarValue`（第 173-190 行）

- [ ] **Step 3: 添加 headerBar、tabBar、tabContent 计算属性 — 新布局的三个核心组件**

文件: `Sources/Settings/SettingsUI.swift:191`（在 `}` 之前、`var body` 之前添加）

```swift
    // MARK: - Tab Navigation

    private var headerBar: some View {
        HStack(spacing: 16) {
            AppLogoBadge(size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("VibeFocus")
                        .font(.system(size: 20, weight: .semibold))
                    Text(appVersionDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("菜单栏里的窗口流转工具")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SettingsStatusPill(
                title: hotKeyManager.shortcutStatusIsError ? "需要处理" : "工作正常",
                tint: hotKeyManager.shortcutStatusIsError ? .red : .green
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hotKeySection
                    permissionsSection
                    loginItemSection
                    shutdownSnapshotSection
                }
            }
            .scrollIndicators(.visible)

        case .workspace:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    workspaceSection
                    overlaySection
                }
            }
            .scrollIndicators(.visible)

        case .claudeIntegration:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    claudeHookSection
                    LANSettingsView()
                }
            }
            .scrollIndicators(.visible)

        case .appearance:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleEditorSection
                    soundSection
                }
            }
            .scrollIndicators(.visible)
        }
    }
```

- [ ] **Step 4: 替换 body — 移除侧边栏 + GeometryReader，改用紧凑 VStack 布局**

文件: `Sources/Settings/SettingsUI.swift:192-369`（替换整个 `var body: some View { ... }`）

```swift
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor),
                    Color.accentColor.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.top, 20)

                tabBar
                    .padding(.top, 14)

                Divider()
                    .padding(.top, 10)

                tabContent
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 680, idealHeight: 680)
        .onAppear {
            let startedAt = Date()
            log("[Settings] view onAppear start")
            spaceController.refreshAvailability(force: true)
            hotKeyManager.refreshAccessibilityStatus()
            loginItemManager.refresh()
            refreshInstallations()
            hookToken = ClaudeHookPreferences.authToken ?? ""
            logOperationDuration(
                "[Settings] view onAppear finished",
                startedAt: startedAt,
                warnThresholdMs: 300,
                fields: [
                    "spaceAvailability": spaceController.availability.rawValue,
                    "axTrusted": String(hotKeyManager.accessibilityGranted),
                    "loginItemEnabled": String(loginItemManager.isEnabled),
                    "hookTokenLoaded": String(!hookToken.isEmpty)
                ]
            )
        }
        .onChange(of: spaceIntegrationEnabled) { newValue in
            log(
                "[Settings] space integration toggled",
                fields: [
                    "enabled": String(newValue),
                    "availability": spaceController.availability.rawValue
                ]
            )
        }
        .onChange(of: restoreStrategyRaw) { newValue in
            log(
                "[Settings] restore strategy changed",
                fields: [
                    "strategy": newValue
                ]
            )
        }
        .onChange(of: hookEnabled) { newValue in
            log(
                "[Settings] hook enabled toggled",
                fields: [
                    "enabled": String(newValue),
                    "isRunning": String(hookServer.isRunning)
                ]
            )
        }
        .onChange(of: hookPort) { newValue in
            log(
                "[Settings] hook port changed",
                fields: [
                    "port": String(newValue)
                ]
            )
        }
        .onChange(of: hookToken) { newValue in
            log(
                "[Settings] hook token changed",
                fields: [
                    "hasToken": String(!newValue.isEmpty)
                ]
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .wav, .mp3, .aiff],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let path = url.path
                    log("[Settings] selected custom sound file", fields: ["path": path])
                    soundManager.updateCustomSoundPath(path)
                }
            case .failure(let error):
                log("[Settings] file importer failed", level: .error, fields: [
                    "error": error.localizedDescription
                ])
            }
        }
    }
```

- [ ] **Step 5: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `git add Sources/Settings/SettingsUI.swift && git commit -m "feat(settings): replace sidebar with tab navigation — 4 tabs: general, workspace, claude integration, appearance"`

---

### Task 3: Update Window Size, Build, Deploy and Verify

**Depends on:** Task 2
**Files:**
- Modify: `Sources/Settings/SettingsWindowController.swift:22,29`

- [ ] **Step 1: 调整窗口初始尺寸和最小尺寸 — 适配无侧边栏布局**

文件: `Sources/Settings/SettingsWindowController.swift:22`

将：
```swift
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
```

替换为：
```swift
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
```

文件: `Sources/Settings/SettingsWindowController.swift:29`

将：
```swift
        window.minSize = NSSize(width: 820, height: 900)
```

替换为：
```swift
        window.minSize = NSSize(width: 720, height: 680)
```

- [ ] **Step 2: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 3: 重启 VibeFocus 并验证设置页无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 4: 提交**
Run: `git add Sources/Settings/SettingsWindowController.swift && git commit -m "feat(settings): adjust window size for tab-based layout (720x680)"`
