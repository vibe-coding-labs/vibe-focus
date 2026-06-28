# Optimization: 主↔副屏双向切换性能审核与针对性优化

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 基于 2026-06-12 实测运行日志，审核主屏↔副屏**双向**切换的完整性能瓶颈，针对**可安全优化**的部分实施修复，并明确标注受安全铁律保护、无法直接优化的瓶颈供用户决策。

**Architecture:**
- 数据流（两个方向）：
  - 主屏→副屏（restore）：`toggle()` → `restore()` → `currentSpaceIndex`(fork) + `moveWindow`[fork: queryWindow + window--space + focus] + `queryWindow` + `setWindowFloat`(fork) + `apply`(AX frame) + `currentSpaceIndex`(fork)
  - 副屏→主屏（move_to_main）：`toggle()` → `moveWindowToMainScreen()` → `resolveWindow`(AX) + `frame`(AX) + `queryWindow` + `isAttributeSettable`×2(AX) + `captureSpaceContext`[fork: querySpaces] + `apply`(AX frame) + `setWindowFloat`(fork) + `focusWindow`(fork) + save(SQLite)
- 关键组件：仅修改 `Sources/Support/ShellRunner.swift`（传输层加超时保护）。**完全不触及** `ToggleEngine.restore()` 及调用链、`moveWindowToMainScreen` 的窗口移动/AX 语义、Space 移动逻辑。
- 设计理由：实测日志证明真正的卡顿 spike 源在 restore 内的 `apply(frame:)`（受 [[feedback_toggle_restore_fragility]] / [[space_switch_regression]] 铁律保护），不能动；上一轮针对 overlay SIGUSR1 风暴的优化已生效但卡顿依旧，证明 overlay 非主因。本 Plan 聚焦唯一可确定安全优化的传输层缺陷（ShellRunner 无超时），并以诊断报告形式交付完整瓶颈审核。

**Current Baseline（实测，`~/Library/Logs/VibeFocus/vibefocus.log`，2026-06-11~12）：**

| 方向 | mode | avg | spike 实测 |
|------|------|-----|-----------|
| 主屏→副屏 | restore | ~650ms | 1687ms(op=13549)、**2573ms(op=13012)** |
| 副屏→主屏 | move_to_main | ~700ms | 1101ms(op=112)、981ms(op=13053)、929ms(op=13259) |

**Target:**
- 消除因 yabai/scripting-addition fork 卡死导致的 spike 加剧（ShellRunner 超时，瓶颈 C）
- restore 内 AX frame spike（瓶颈 B，铁律保护）无法直接消除，通过诊断报告明确告知用户
- 平均 durationMs 无回退，全量 992 测试通过

**Bottleneck（实测定位，详见诊断报告）：**
- A. yabai 调用走 fork/exec Process，单次 40-130ms，串行 3-5 次（两路径共用）
- B. restore 内 `apply(frame:)` 间歇阻塞 1-2.7s（op=13012 实测 2146ms）— **铁律保护区**
- C. `ShellRunner.swift:22` `process.waitUntilExit()` 无超时，fork 抖动时无限阻塞主线程 — **本 Plan 修复**
- D. moveWindowToMainScreen 6+ AX RPC + 3 fork（分析后无安全去冗余空间）

**Tech Stack:** Swift 5（SwiftPM），macOS AppKit，yabai，@MainActor 隔离，swift-testing（992 测试）

**Scope:** Small
**Risk:** Low（仅传输层超时保护，零调用方语义变更）
**Autonomy Level:** Full

**Risks:**
- Task 1 超时后返回 nil，调用方需能处理 → 缓解：现有 `runYabai`/`runYabaiVariants`（SpaceController+Yabai.swift:88-104）已处理 `runYabai` 返回 nil（走 fallback / 报错），`YabaiClient.run` 本就有 2.0s 超时先例，行为一致
- 瓶颈 B 无法消除 → 缓解：诊断报告 + 后续决策点明确，用户可授权独立 Plan 处理

**安全铁律（不可违反，来自记忆）：**
1. **禁止修改** `ToggleEngine.restore()` 及调用链（`moveWindow`/`focusWindow`/`setWindowFloat`/`queryWindow`/`currentSpaceIndex`/`checkScriptingAdditionLoaded`）的执行逻辑（[[feedback_toggle_restore_fragility]]）
2. **禁止** 在 restore 路径添加坐标验证 guard（[[feedback_toggle_restore_fragility]]，几十次误杀历史）
3. **禁止** 跳过 Space 移动（[[space_switch_regression]]）
4. restore 执行逻辑只能存在于 `ToggleEngine.restore()`，`WindowManager+Restore` 仅委托（[[feedback_single_restore_path]]）
5. **只优化** 传输层（`ShellRunner`）的超时保护，不改任何 yabai 调用的语义、顺序、参数

---

## 诊断报告（用户要求的"审核整个性能问题主要存在哪些方面"）

### 实测数据（2026-06-11~12，新部署 pid=69662 + 历史 pid=2203）

**双向耗时对比（最近 40 条 `toggle finished`）：**
- restore（主→副）：avg ~650ms，spike 1687/2573ms
- move_to_main（副→主）：avg ~700ms（**更高**），spike 1101/981/929/883/848ms

**关键反证 —— 上一轮"SIGUSR1 风暴是主因"诊断错误：**
1. move_to_main **不走 restore、不触发 SIGUSR1 风暴**，但平均更慢（~700ms vs ~650ms）→ fork/AX 本身是瓶颈，不是 overlay 刷新
2. 上一轮 `suspend/resume` 优化已生效（日志 `[INFO] Suspended/Resumed ... toggle_in_progress/complete` 成对出现，pid=69662），但 toggle 仍 400-1100ms → overlay 刷新非主因

### 瓶颈 A：yabai 调用走 fork/exec Process（确定性，两路径共用）

- `ShellRunner.run()`（`Sources/Support/ShellRunner.swift:6-32`）每次 `Process()` + `process.waitUntilExit()`
- 实测单次 fork 耗时（日志 `[SpaceController] yabai command result`）：
  - `window --space`：正常 40ms，抖动时 130ms（op=13012）
  - `window --focus`：正常 69ms
- restore 路径串行 ~4 fork（currentSpaceIndex + window--space + focus + setWindowFloat），move_to_main ~3 fork
- **根因**：macOS `Process` fork/exec 启动开销 ~20-30ms + yabai argv 解析 + scripting-addition 加载，每次调用都重复支付
- **本 Plan 不直接修复 A**（socket 复用连接是解法，但协议未确认，见"探索过的方法"）

### 瓶颈 B：restore 内 AX frame apply 间歇 spike（铁律保护区，无法直接优化）

op=13012 时间线（restore 2573ms）：
```
43.264  yabai "window --space 4" fork done (130ms，本身已慢)
43.310  yabai "window --focus" fork done (42ms)
43.313  restore: space move result moved=true
45.459  restore: completed                 ← 此段 2146ms
```

- 该段（`ToggleEngine+Restore.swift:78-106`）只有：`queryWindow`(缓存命中，0 fork) + `setWindowFloat`(早退，无 fork 日志) + **`apply(frame:)` line 84** + `!moved` 块(moved=true 跳过)
- → 2146ms 几乎全在 `apply(frame:)` = `AXUIElementSetAttributeValue(kAXFrameAttribute)`
- 正常 op=217 同段仅 214ms（**10× 差异**）
- **根因**：yabai `window --space` 触发 macOS space 切换动画，期间对该窗口的 AX frame 设置被内核序列化阻塞，直到动画完成 + 窗口在新 space 就绪
- **铁律限制**：`apply(frame:)` 在 `restore()` 内部，[[feedback_toggle_restore_fragility]] 禁止改动 restore 路径。**本 Plan 不优化此瓶颈**。若用户愿放宽铁律，见"后续决策点"

### 瓶颈 C：ShellRunner 无超时（稳健性缺陷，spike 嫌疑）— 本 Plan 修复

- `ShellRunner.swift:22` `process.waitUntilExit()` **无超时**（对比 `YabaiClient.run:121` 有 `sem.wait(timeout: 2.0)`）
- SpaceController 全部 yabai 调用走 ShellRunner（`runYabai` → `runProcess` → `ShellRunner.run`）
- 若 yabai/scripting-addition 抖动卡住，主线程**无限阻塞** → 放大瓶颈 B 的 spike，也可能独立造成卡死
- **可修复**（Task 1）：加 2.0s 超时，与 `YabaiClient.run` 行为一致

### 瓶颈 D：moveWindowToMainScreen 多 AX RPC（副屏→主屏，平均最慢）

- `WindowManager+MoveWindow.swift:47-173`：resolveWindow(AX 遍历) + frame(AX) + isAttributeSettable×2(AX) + captureSpaceContext[querySpaces cold fork] + apply(AX) + setWindowFloat(fork) + frame(AX 读回) + windowHandle×2(AX/CG) + save(SQLite)
- 6+ AX 跨进程 RPC（每次 ~10-20ms）+ 3 fork
- **经分析，各调用均有语义用途**（save 准确性需 frame 读回、焦点保留需 focusWindow、windowID 重映射需两次 windowHandle），**无安全去冗余空间**（去任一项都触及 toggle/restore fragility 边界）
- → 本 Plan 不优化 D（避免 fragility 风险）

### 探索过的方法：yabai messaging socket（瓶颈 A 的潜在解法，协议未确认）

- `/tmp/yabai_cc11001100.socket` 存在（`srw-------`），yabai pid 1343 运行中
- Plan 编写期测试 4 种 framing（`<hex-len>:<msg>` / binary LE uint32 前缀 / `<decimal-len>:<msg>` / +换行）**均连接成功但收 0 字节响应**，status byte 0x07（解析失败）
- 协议非平凡，需读 yabai 源码 `src/messaging.c` 的 `messaging_send_to_daemon` / `messaging_send_to_client` 确认确切 framing（可能含握手或不同 socket 路径）
- **不在本 Plan 实施**（无法写出无 TODO 的代码，违反 Plan 铁律）。列为"后续决策点"独立处理

---

### Task 1: ShellRunner 加 2.0s 超时保护 — 防止 fork 卡死放大 spike

**Depends on:** None
**Files:**
- Modify: `Sources/Support/ShellRunner.swift:4`（添加 commandTimeout 常量）
- Modify: `Sources/Support/ShellRunner.swift:6-32`（`run(executable:arguments:)` 加超时）
- Modify: `Sources/Support/ShellRunner.swift:35-68`（`run(executable:arguments:stdin:)` 加超时）

最高优先、确定安全：给 ShellRunner 两个 `run` overload 加 `DispatchSemaphore` 超时（2.0s，与 `YabaiClient.commandTimeout` 对齐）。fork 抖动时不再无限阻塞主线程，直接缓解瓶颈 C。零调用方语义变更（现有 `runYabai`/`runYabaiVariants` 已处理 nil 返回 → fallback）。

- [ ] **Step 1: 添加 commandTimeout 常量 — 与 YabaiClient 对齐**

文件: `Sources/Support/ShellRunner.swift:4`（`enum ShellRunner {` 之后第一行）

```swift
enum ShellRunner {
    /// 子进程超时（与 YabaiClient.commandTimeout 对齐）。
    /// yabai / scripting-addition 抖动时防止 waitUntilExit 无限阻塞主线程
    /// （2026-06-12 性能审核瓶颈 C，toggle 间歇 spike 嫌疑之一）。
    static let commandTimeout: TimeInterval = 2.0

```

- [ ] **Step 2: 修改 run(executable:arguments:) — 用 DispatchSemaphore 超时替代 waitUntilExit**

文件: `Sources/Support/ShellRunner.swift:6-32`（替换整个 `run(executable:arguments:)` 函数）

```swift
    @discardableResult
    static func run(executable: String, arguments: [String]) -> YabaiClient.YabaiResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 超时保护：yabai / scripting-addition 抖动时 waitUntilExit() 会无限阻塞主线程，
        // 是 toggle 间歇性 spike（实测 1-2.7s）的嫌疑之一（见 2026-06-12 审核瓶颈 C）。
        // 与 YabaiClient.commandTimeout(2.0s) 对齐：超时后 terminate 并返回 nil，调用方走 fallback。
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
```

- [ ] **Step 3: 修改 run(executable:arguments:stdin:) — 同样加超时**

文件: `Sources/Support/ShellRunner.swift:35-68`（替换 `process.waitUntilExit()` 为超时等待，替换整个函数）

```swift
    @discardableResult
    static func run(executable: String, arguments: [String], stdin: String) -> YabaiClient.YabaiResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        if let data = stdin.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()

        // 超时保护（同 run(executable:arguments:)，见瓶颈 C 说明）
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
```

- [ ] **Step 4: 编译验证**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: 质量门禁 — 编译 + 全量回归 + 整洁检查**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - swift test: 无 FAIL，测试数 ≥ 992（与基线一致）
  - `grep -n "waitUntilExit" Sources/Support/ShellRunner.swift` 返回 **0 行**（两个 overload 的 waitUntilExit 已全部替换）

**手工检查（AI 自行验证）：**
- [ ] 两个 `run` overload 都加了超时（无残留 `waitUntilExit`）
- [ ] `commandTimeout` 常量定义在 `enum ShellRunner` 内
- [ ] 未修改任何调用方（`runYabai`/`runYabaiVariants`/`WindowManager` 调用点签名不变）
- [ ] 未修改 `runShell(_:)`（line 70-74，它调用 `run(executable:arguments:)`，自动获得超时，无需改动）
- [ ] 无遗留 debug 语句

- [ ] **Step 6: 提交**

Run: `git add Sources/Support/ShellRunner.swift && git commit -m "perf(shell): add 2.0s timeout to ShellRunner to prevent fork stalls amplifying toggle spike

ShellRunner.run 用 waitUntilExit() 无超时，yabai/scripting-addition 抖动时会
无限阻塞主线程，是 toggle 间歇性 spike（实测 1-2.7s）的嫌疑之一（2026-06-12
性能审核瓶颈 C）。改为 DispatchSemaphore 2.0s 超时（与 YabaiClient.commandTimeout
对齐），超时 terminate 返回 nil，调用方走现有 fallback。零调用方语义变更。"`
Expire

---

### Task 2: 部署 + benchmark 对比 + 诊断报告交付

**Depends on:** Task 1
**Files:**
- Deploy: `/Applications/VibeFocus.app`

- [ ] **Step 1: 部署（完整 app bundle + code signing）**

Run: `bash scripts/package_release.sh 2>&1 | tail -5 && ditto dist/VibeFocus.app /Applications/VibeFocus.app && open /Applications/VibeFocus.app`
Expected:
  - release build 成功（[[vibefocus_deploy_workflow]]：禁止 swift build + cp 热部署）
  - ditto 部署 OK
  - open 启动应用（[[vibefocus_deploy_restart]]：不让应用处于关闭状态）
  - `tail -n 20 ~/Library/Logs/VibeFocus/vibefocus.log` 包含 "ScreenOverlayManager initialized"

- [ ] **Step 2: 部署后验证 hook-forwarder + 应用运行**

Run: `pgrep -fl VibeFocus && cat ~/.vibefocus/hook-forwarder.sh 2>/dev/null | grep -iE "url|http" | head -3`
Expected:
  - VibeFocus 进程存在（[[feedback_hook_forwarder_verification]]）
  - hook-forwarder.sh URL 正确（Swift 字符串插值可能丢失反斜杠）

- [ ] **Step 3: benchmark 实测对比（部署前后）**

部署后请用户按热键测试双向切换（主→副、副→主各 5 次），然后提取耗时：

Run: `grep "toggle finished" ~/Library/Logs/VibeFocus/vibefocus.log | tail -20 | grep -oE '(mode=[a-z_]+|durationMs=[0-9]+)' | paste - -`
Expected:
  - **无因 fork 卡死导致的 > 2s spike**（瓶颈 C 消除 —— 超时保护让卡死的 fork 在 2s 内被 terminate，不再无限拖长）
  - 平均 durationMs 无回退
  - restore AX spike（瓶颈 B，铁律保护）仍可能偶发 1-2s — **这是预期**，诊断报告已说明

**Benchmark 前后对比表：**

| 指标 | 优化前（基线） | Task 1 后 |
|------|--------------|-----------|
| fork 卡死导致的 spike（>2s 且无 AX 阻塞特征） | 偶发（瓶颈 C） | 消除（2s 超时 terminate） |
| restore 平均 | ~650ms | ~650ms（不变，瓶颈 A/B 未触） |
| move_to_main 平均 | ~700ms | ~700ms（不变） |
| restore AX spike（瓶颈 B，space 动画阻塞） | 偶发 1-2.7s | 偶发 1-2s（铁律保护，未优化） |

- [ ] **Step 4: 提交（若有 package_release 或脚本改动）**

Run: `git status --short && git log --oneline -3`
Expected:
  - Task 1 提交在 main 上（[[project_maintenance]]：直接 main 开发）
  - 无未提交改动（或仅有已记录的脚本改动，单独提交）

---

## 后续决策点（需用户确认，本 Plan 不自动执行）

### 决策点 1：瓶颈 B（restore AX frame spike）是否放宽铁律

诊断确认：toggle 最严重的卡顿 spike（1-2.7s）来自 restore 内 `apply(frame:)` 在 macOS space 切换动画期间被阻塞。受 [[feedback_toggle_restore_fragility]] 铁律保护，本 Plan 不优化。

**若用户愿放宽铁律，可选方案（需独立 Plan + 明确授权）：**
- 方案 1：`apply(frame:)` 异步化 —— 在 background queue 设置 frame，不阻塞主线程 toggle 返回（用户感知立即响应，窗口延迟 ~200ms 到位）
- 方案 2：`apply(frame:)` 前等待 space 切换动画完成 —— 检测动画结束后再 set frame（避免阻塞但增加延迟）
- 方案 3：保持铁律，接受偶发 spike（**本 Plan 选择**）

**风险：** 方案 1/2 都改 restore 路径执行逻辑，有 fragility 误杀历史。需用户明确授权才能开独立 Plan。

### 决策点 2：yabai socket 传输层（瓶颈 A 解法）是否投入

socket 复用持久连接可省去每次 Process fork 启动开销（~20-30ms/次），单次调用 40-130ms → ~5-10ms，双向 toggle 预计省 ~150-250ms。但 Plan 编写期测试 4 种 framing 均失败，协议需读 yabai 源码 `src/messaging.c` 确认。

**若用户愿投入，后续 Plan 应：**
1. 读 yabai `src/messaging.c` 确认 `messaging_send_to_daemon` / `messaging_send_to_client` 的确切 framing（含长度前缀格式、是否有握手、响应 status/length 编码）
2. 实现 `YabaiSocketClient`（持久连接 + 自动重连 + Process fallback）
3. 集成到 `SpaceController.runProcess`（socket 优先，fallback 到 ShellRunner）

**风险：** 协议若与版本强绑定，yabai 升级可能失效；需 fallback 保护。投入产出比需用户判断（~150-250ms 收益 vs 协议逆向成本）。

---

**部署后用户验证清单：**
1. 按热键测试主→副、副→主各 5 次，观察是否仍有 > 2s 卡死（瓶颈 C 应消除）
2. `grep "toggle finished" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10` → durationMs 应无 > 2s 的 fork 卡死 spike
3. 若仍有偶发 1-2s spike（瓶颈 B，space 动画期间 AX 阻塞）→ 这是铁律保护区的已知限制，见决策点 1
