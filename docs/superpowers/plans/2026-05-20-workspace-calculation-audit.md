# Research: 工作区（Space/Display）计算逻辑审计

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Question:** 当前工作区（space/display）计算逻辑是否仍存在导致错误的风险点？

**Context:** 用户反复遇到工作区索引回退错误，已有多个修复提交（accidentally-switched detector、PID fallback、hook-restore-cleanup 等）。需要全面审计计算逻辑，确认是否仍有残留风险。

**Deliverable:** 结构化审计报告 + 残留风险评估 + 行动建议

**Time Box:** 30 分钟

**Scope:** Medium

---

## 审计报告

### 1. 坐标体系概述

系统使用 **5 种坐标/索引体系**，所有 workspace 计算都是这些体系之间的转换：

| 体系 | 格式 | 用途 | 来源 |
|------|------|------|------|
| yabai global space | `Int` (1-based) | 跨 space 操作的主键 | `yabai -m query --spaces` |
| yabai display | `Int` (1-based) | 标识物理显示器 | `yabai -m query --displays` |
| display-local space | `Int` (1-based) | display 内的 space 序号 | 计算：过滤 + 排序 + offset |
| macOS CGS space ID | `Int64` | 底层 API | `NativeSpaceBridge` |
| Quartz/Cocoa 坐标 | `CGPoint` | CGEvent 操作 | `NSScreen` / yabai frame |

**关键设计决策：** 所有逻辑层使用 yabai 索引，仅在执行底层操作时转换为 macOS 原生 API。

---

### 2. 数据流：Toggle（Move to Main）路径

```
用户按热键
  → WindowManager.toggle()
    → captureSpaceContext(windowID)
      → queryWindow(windowID)                    // yabai 查询窗口
        → windowSpace = windowInfo.space         // 窗口所在 yabai global space
        → windowDisplay = windowInfo.display     // 窗口所在 yabai display
      → visibleSpace(displayIndex)               // display 当前可见 space
      → preferredSourceSpace(windowSpace, visibleSpace, nil)  // 选择准确的 source space
      → displayLocalSpaceIndex(globalSpace, display)          // 全局→局部 space 索引
    → ToggleEngine.save(sourceSpace, sourceYabaiDisp, sourceDispSpace, origFrame, ...)
```

**计算风险点：**
- [无风险] `preferredSourceSpace()` — 逻辑清晰：优先 windowSpace（窗口实际位置），其次 visibleSpace
- [无风险] `displayLocalSpaceIndex()` — 过滤 + 排序 + 枚举，算法正确
- [低风险] `queryWindow()` 依赖 yabai 实时数据 — 如果窗口刚跨 display 移动，yabai 数据可能有延迟

---

### 3. 数据流：Restore 路径

```
Hook UserPromptSubmit / 热键 toggle
  → ToggleEngine.restore(windowID, fallbackPID, ...)
    → load(windowID) 或 loadByPID(pid)           // SQLite 查询
      → record.sourceSpace                        // yabai global space index
      → record.sourceYabaiDisp                    // yabai display index
    → displayVisibleSpace(displayIndex)           // 检查目标 display 当前 space
    → if currentSpace != targetSpace:
        → switchDisplayToSpace(targetSpace)        // 切目标 display
          → Strategy 1: yabai -m space --focus    // 直接切（需要 SA）
          → Strategy 2: CGEvent Ctrl+Arrow        // 备用方案
            → calculateFocusSteps(targetSpace)     // 计算步数
            → displayCenterCG(spaceIndex)          // 获取 display 中心坐标
            → 移鼠标 + 发 CGEvent + 恢复鼠标
        → 等待 0.4s 确认 space 切换完成
        → 额外 150ms 等待动画提交
    → AX apply(origFrame)                          // 移动窗口到目标位置
    → "accidentally switched" 检测                 // 修复 CGEvent 副作用
    → RestoreWatchdog 启动                         // 监控 yabai tiling 干扰
```

---

### 4. 逐函数风险评估

#### 4.1 `switchDisplayToSpace()` — SpaceController+Switch.swift:7-127

**风险等级：中**

| 步骤 | 风险 | 说明 |
|------|------|------|
| Strategy 1: yabai space --focus | 低 | 需 SA 权限，失败时 fallback |
| Strategy 2: CGEvent | 中 | 见下方详细分析 |
| calculateFocusSteps() | 低 | 算法正确：找 targetSpace 在 display 内的偏移量，减去 currentSpace 偏移量 |
| displayCenterCG() | 低 | 使用 yabai frame 坐标系（与 CGEvent 一致），无转换错误 |

**CGEvent 策略的具体风险：**

1. **鼠标移动激活 display** — CGEvent Ctrl+Arrow 只影响鼠标所在 display。代码先移鼠标到目标 display 中心，再发 keystroke。这个逻辑正确。

2. **yabai display --focus 预激活** — 第 44-60 行先用 yabai 激活目标 display，确保 CGEvent 正确路由。如果 yabai focus 也失败，仅靠鼠标移动可能不够可靠。

3. **鼠标恢复** — 操作完成后恢复鼠标位置（第 109-112 行）。如果在恢复之前有其他事件处理，可能导致短暂的鼠标跳动。

**已知问题：** CGEvent Ctrl+Arrow 可能产生副作用，影响非目标 display。这就是 "accidentally switched" 检测器存在的原因。

#### 4.2 "accidentally switched" 检测器 — ToggleEngine.swift:430-448

**风险等级：低（已修复）**

| 检查项 | 状态 |
|--------|------|
| 记录 restore 前所有 display 的可见 space | ✅ 第 231-237 行 |
| 跳过目标 display（被故意切换的） | ✅ 第 431-433 行（commit `a6a6a2d`） |
| 检查非目标 display 的 space 变化 | ✅ 第 434-435 行 |
| 修复意外变化 | ✅ 第 442-445 行 |

**残留风险：**
- 硬编码 `for disp in 1...3` — 如果用户有超过 3 个 display，第 4+ 个 display 不会被检测。当前用户正好是 3 display，暂无影响。
- 修复操作自身没有防止无限循环 — 如果 `switchDisplayToSpace` 的修复又触发了另一个 display 变化，可能导致震荡。但由于只修复一次（不在循环内），风险低。

#### 4.3 `calculateFocusSteps()` — SpaceController+Switch.swift:350-405

**风险等级：低**

算法：
1. 查询所有 spaces
2. 找到目标 space 所在的 display
3. 获取该 display 上所有 spaces（按 index 排序）
4. 找到当前可见 space 的位置和目标 space 的位置
5. 返回差值（正数 = 向右，负数 = 向左）

**正确性分析：**
- 排序使用 `($0.index ?? 0) < ($1.index ?? 0)` — 如果某个 space 的 index 为 nil，默认为 0，可能导致排序错误。但 yabai 正常返回时 index 不为 nil。
- 查找可见 space 使用 `isVisible == true` — yabai 的这个标志应该是准确的。

#### 4.4 `displayLocalSpaceIndex()` — SpaceController+Context.swift:71-109

**风险等级：低**

算法：
1. 过滤出目标 display 上的所有 spaces
2. 按 global index 排序
3. 枚举找到匹配的 space
4. 返回 offset + 1（1-based）

**正确性分析：**
- 与 `calculateFocusSteps()` 使用相同的排序逻辑，一致性好
- 返回 1-based 索引，与 yabai 的 display-local space 索引一致

#### 4.5 RestoreWatchdog — RestoreWatchdog.swift

**风险等级：低（功能性问题，不影响 space 索引）**

| 检查项 | 当前行为 | 风险 |
|--------|---------|------|
| 检测 float 状态 | 每 200ms 检查 | 日志显示 "window not floating" 后 3 次纠正失败 |
| 纠正 frame | AX apply | 正确但 yabai 立即重新 tile |
| 纠正 space | moveWindow | 正确但很少触发 |
| 纠正 display | — | 通过 space 纠正间接处理 |

**注意：** Watchdog 的 "window not floating" 失败不会导致 space 索引错误。它只影响窗口位置（yabai tiling 改变窗口大小/位置），不影响 display 上显示哪个 space。

---

### 5. 残留风险总结

| # | 风险点 | 严重度 | 可能性 | 影响 | 状态 |
|---|--------|--------|--------|------|------|
| 1 | **accidentally-switched 未部署** | 高 | 高 | display space 被切回错误值 | ✅ 已修复（`a6a6a2d`），未部署 |
| 2 | **hook-restore-cleanup 未部署** | 中 | 中 | toggle record 残留，下次 toggle 行为异常 | ✅ 已修复，未部署 |
| 3 | **CGEvent 副作用** | 低 | 低 | 非目标 display 被意外切换 | ✅ 已有检测+修复 |
| 4 | **yabai 数据延迟** | 低 | 低 | captureSpaceContext 获取过时的 windowSpace | ⚠️ 依赖 yabai 响应速度 |
| 5 | **display 数量硬编码** | 低 | 极低 | 第 4+ 个 display 的意外切换不被检测 | ⚠️ 代码假设 3 个 display |
| 6 | **RestoreWatchdog float 失败** | 低 | 高 | 窗口被 yabai 重新 tile | ⚠️ 不影响 space 索引 |
| 7 | **CGEvent Ctrl+Arrow 路由错误** | 中 | 低 | 鼠标未到达目标 display 时 keystroke 影响错误 display | ⚠️ 有 pre-focus + 检测器缓解 |

---

### 6. 结论

**是否仍会发生工作区计算错误？**

**在当前已提交但未部署的代码基础上（commit `a6a6a2d` 及之后）：**

1. **主要 bug 已修复** — accidentally-switched detector 的目标 display 跳过逻辑已正确实现
2. **空间索引计算逻辑本身是正确的** — `calculateFocusSteps()`、`displayLocalSpaceIndex()`、`preferredSourceSpace()` 的算法均无缺陷
3. **CGEvent 副作用有双层保护** — yabai display --focus 预激活 + accidentally-switched 检测器

**仍可能出错的场景：**

| 场景 | 触发条件 | 预期表现 |
|------|---------|---------|
| yabai 响应慢 | CPU 负载高时 toggle | captureSpaceContext 获取过时数据，restore 到错误位置 |
| 超过 3 个 display | 添加第 4 个显示器 | 第 4 个 display 的意外切换不被检测和修复 |
| CGEvent 路由失败 | 鼠标移动被其他进程拦截 | Ctrl+Arrow 影响错误 display，但检测器会修复 |

**行动建议：**

1. **立即部署** — commit `a6a6a2d` 及后续修复尚未部署，当前运行的仍然是旧代码
2. **部署后验证** — 在 3-display 环境下测试跨 display toggle，确认 accidentally-switched 消息不再出现
3. **可选优化** — 将 `for disp in 1...3` 改为动态查询 display 数量（低优先级）
4. **可选优化** — RestoreWatchdog 的 float 纠正失败需要进一步分析（不影响 space 索引，但影响窗口位置）
