# Settings Performance Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 移除设置窗口所有无意义的视觉效果（透明背景、渐变、半透明卡片、大半径阴影），消除打开时的卡顿。

**Root Cause:** 窗口设为透明（`backgroundColor = .clear`）+ LinearGradient 背景 + 每张卡片都有半透明填充 + strokeBorder + 18pt 阴影 → macOS 需要对每个像素做 alpha compositing，导致打开时严重卡顿。

**Architecture:** 移除所有导致 GPU 合成的视觉效果：透明窗口 → 纯色窗口；LinearGradient → 纯色背景；半透明卡片 → 不透明卡片；大半径阴影 → 无阴影。数据流不变，仅移除装饰层。

**Tech Stack:** SwiftUI 5.9, macOS 14+ AppKit

**Risks:**
- 视觉外观会变化（更朴素但更快）— 这是用户明确要求的
- 无功能风险，不涉及任何逻辑代码

---

### Task 1: Remove Window-Level Transparency and Gradient Background

**Depends on:** None
**Files:**
- Modify: `Sources/Settings/SettingsWindowController.swift:23,38`
- Modify: `Sources/Settings/SettingsUI.swift:248-258`

- [ ] **Step 1: 移除透明窗口背景 — 消除窗口级 alpha compositing 开销**

文件: `Sources/Settings/SettingsWindowController.swift:38`

将：
```swift
        window.backgroundColor = .clear
```

替换为：
```swift
        window.backgroundColor = .windowBackgroundColor
```

- [ ] **Step 2: 移除 LinearGradient 背景 — 替换为纯色，消除 GPU 渐变渲染**

文件: `Sources/Settings/SettingsUI.swift:248-258`（替换整个 `var body` 中的 `ZStack` 背景）

将：
```swift
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
```

替换为：
```swift
        VStack(spacing: 0) {
```

同时将 `ZStack` 的闭合 `}` 删除（在 `tabContent` 的 `.padding(.bottom, 20)` 之后、`.padding(.horizontal, 28)` 之前）。

文件: `Sources/Settings/SettingsUI.swift:273-275`（删除 ZStack 闭合）

将：
```swift
            .padding(.horizontal, 28)
        }
        .frame(minWidth: 720, idealWidth: 720, minHeight: 680, idealHeight: 680)
```

替换为：
```swift
        .padding(.horizontal, 28)
        .frame(minWidth: 720, idealWidth: 720, minHeight: 680, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
```

- [ ] **Step 3: 移除 fullSizeContentView style mask — 不需要透明标题栏**

文件: `Sources/Settings/SettingsWindowController.swift:23`

将：
```swift
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
```

替换为：
```swift
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
```

- [ ] **Step 4: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/Settings/SettingsWindowController.swift Sources/Settings/SettingsUI.swift && git commit -m "perf(settings): remove transparent window background and gradient — eliminates alpha compositing"`

---

### Task 2: Remove Card Transparency, Borders and Shadows from Components

**Depends on:** None
**Files:**
- Modify: `Sources/Settings/SettingsComponents.swift:37-53`（AppLogoBadge 渐变+阴影）
- Modify: `Sources/Settings/SettingsComponents.swift:242-251`（SettingsCard 背景+边框+阴影）

- [ ] **Step 1: 移除 AppLogoBadge 的渐变背景和阴影 — 简化为纯色图标**

文件: `Sources/Settings/SettingsComponents.swift:29-53`（替换整个 `else` 分支 + clipShape/overlay/shadow）

将：
```swift
            } else {
                Image(systemName: "rectangle.3.group.bubble.left.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.98), Color.accentColor.opacity(0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
```

替换为：
```swift
            } else {
                Image(systemName: "rectangle.3.group.bubble.left.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
```

- [ ] **Step 2: 移除 SettingsCard 的半透明+边框+阴影 — 改为不透明纯色背景**

文件: `Sources/Settings/SettingsComponents.swift:242-251`（替换 `.padding(22)` 之后的 background block）

将：
```swift
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 18, y: 10)
```

替换为：
```swift
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
```

- [ ] **Step 3: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 4: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 5: 重启 VibeFocus 并验证设置页无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 6: 提交**
Run: `git add Sources/Settings/SettingsComponents.swift && git commit -m "perf(settings): remove card transparency, borders and shadows — eliminates per-card compositing"`
