# Performance Instrumentation Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 在 toggle / restore / move_to_main / apply / setWindowFloat 五条性能热路径补充 sub-stage 耗时埋点，让单条日志即可定位"哪一段慢"，为后续性能优化提供量化数据支撑（当前只有 top-level `durationMs`，子阶段不可见）。

**Architecture:**
- 数据怎么流：每条热路径在关键 sub-stage 前后用 `Date()` 戳记 → `elapsedMilliseconds(since:)` 计算分段耗时 → 拼入现有 `log(fields:)` 的 `[String:String]` 字段，与 `op`/`windowID` 关联。不引入新日志通道，复用 `~/Library/Logs/VibeFocus/vibefocus.log`。
- 关键组件：`apply(frame:)`（Phase1/Phase2 分解）、`setWindowFloat`（补盲区）、`moveWindowToMainScreen`（4 段分解）、`ToggleEngine.restore`（6 段分解，唯一 restore 执行入口）、`toggle`（coreOpMs 汇总）。
- 为什么这样做：历史 spike 根因（apply Phase2 跨屏 position 阻塞、restore 的 moveWindow+apply、setWindowFloat 完全无 log）都藏在 top-level 总耗时之下，无法从单行日志定位。分段埋点是最小侵入（纯计时，零新 AX/fork）的可观测性补齐。

**Tech Stack:** Swift 5（SwiftPM, macOS 13, AppKit），yabai v7.1.18，现有 `log(_:level:fields:)` / `elapsedMilliseconds(since:)` / `logOperationDuration`（Sources/Support/Support.swift）。

**Scope:** Medium（5 个热路径文件，跨 Toggle/Window/Space 三模块）
**Risk:** Low（纯增量计时 + log 字段，不改任何控制流；但 Task 4 触碰 restore 执行入口需严守铁律）
**Autonomy Level:** Full

**Risks:**
- Task 4 改 `ToggleEngine.restore()`，触碰 restore 执行逻辑 → 缓解：**仅**插入 `Date()` 戳记与 log 字段，不加任何 guard/return/坐标验证（严守 [[feedback-toggle-restore-fragility]] / [[feedback-single-restore-path]]），编译 + 全量回归验证。
- 埋点可能引入新 AX/fork 开销 → 缓解：全部用 `Date()`+`elapsedMilliseconds`，**复用现有调用结果**，不新增 `frame(of:)`/`cgWindowList`/yabai fork（严守 [[feedback-toggle-ctxms-cgwindowlist]]）。
- 日志量增加 → 缓解：新埋点 info/debug 级，复用现有 slow 阈值（runYabai 180ms）；apply 分解字段并入既有 `[apply] done`（debug，默认输出）不新增日志行。
- Task 2 改 setWindowFloat 多 early-return 路径 → 缓解：用 `defer` 统一汇总日志 + `outcome` 变量，确保所有退出路径（含 skip）都记录耗时。

---

### Task 1: apply(frame:) 增加 Phase1/Phase2 耗时分解与 size retry 计数

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:61-161`（`apply` 函数整体替换）

**Why:** `[apply] done` 当前只 log 总 `durationMs`。Phase 2 跨屏 position write 的 WindowServer 阻塞是历史 move_to_main 1300ms+ spike 主因，但与 Phase 1 size readback 循环开销无法区分。`sizeAttempts`（实际重试次数）和 `sizeReadbackMatched`（readback 是否命中）能定位 size 写入是否可靠生效。

- [ ] **Step 1: 替换 apply 函数 — 在 Phase1/Phase2 边界戳记并扩展 done 日志**
文件: `Sources/Window/WindowManager+AXHelpers.swift:61-161`（替换整个 `apply` 函数）

```swift
func apply(
    frame targetFrame: CGRect,
    to window: AXUIElement,
    operationID: String? = nil,
    stage: String = "apply_frame",
    maxAttempts: Int = 3
) -> Bool {
    let op = operationID ?? "none"
    let startedAt = Date()
    let attempts = max(1, maxAttempts)
    let settleDelayMicros: useconds_t = 25_000

    // Phase 1/Phase 2 耗时分解埋点：定位 size readback 循环开销 vs 跨屏 position 阻塞（历史 spike 主因）。
    let phase1Start = Date()
    var sizeAttemptsUsed = 0
    var sizeReadbackMatched = false

    // Phase 1: size write + readback retry。
    // 关键优化：size write 不触发跨屏移动，readback 在 Phase 2 的 position write 之前进行，
    // 不被 WindowServer 跨屏阻塞。旧实现 size+position 在同一循环，position 跨屏阻塞拖累
    // 每次循环的 size readback，3 次累积 1300ms+（move_to_main spike 主因）。分离后 size 验证
    // 仍用 maxAttempts 次确保 height 可靠生效（maxAttempts≠1 的核心目的），position 跨屏阻塞只发生一次。
    for attempt in 1...attempts {
        sizeAttemptsUsed = attempt
        var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
        guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
            log(
                "[apply] AXValueCreate for size returned nil",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "targetWidth": "\(targetFrame.width)",
                    "targetHeight": "\(targetFrame.height)"
                ]
            )
            return false
        }

        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        guard sizeResult == .success else {
            log(
                "[apply] AXUIElementSetAttributeValue for size failed",
                level: .error,
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "sizeResult": String(sizeResult.rawValue)
                ]
            )
            return false
        }

        // 单次模式（restore）：跳过 size readback，直接进 Phase 2 position write。
        if attempts == 1 { break }

        usleep(settleDelayMicros)

        // size readback：窗口此时未跨屏移动（position write 在 Phase 2），readback 不被阻塞。
        if let appliedFrame = frame(of: window),
           abs(appliedFrame.width - targetFrame.width) <= frameTolerance,
           abs(appliedFrame.height - targetFrame.height) <= frameTolerance {
            sizeReadbackMatched = true
            break  // size 已生效
        }
        // size 未生效，retry（attempt < attempts）
    }
    let phase1Ms = elapsedMilliseconds(since: phase1Start)

    // Phase 2: position write — 单次。
    // 跨屏移动的 WindowServer 阻塞只发生这一次（旧实现因 position 在循环内阻塞 maxAttempts 次）。
    // size 已在 Phase 1 验证生效（maxAttempts>1）或单次写入（maxAttempts=1），position 单次 write 即可。
    let phase2Start = Date()
    var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
    guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
        log(
            "[apply] AXValueCreate for position returned nil",
            level: .error,
            fields: [
                "op": op,
                "stage": stage,
                "targetX": "\(targetFrame.origin.x)",
                "targetY": "\(targetFrame.origin.y)"
            ]
        )
        return false
    }

    let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
    guard positionResult == .success else {
        log(
            "[apply] AXUIElementSetAttributeValue for position failed",
            level: .error,
            fields: [
                "op": op,
                "stage": stage,
                "positionResult": String(positionResult.rawValue)
            ]
        )
        return false
    }
    let phase2Ms = elapsedMilliseconds(since: phase2Start)

    log("[apply] done", level: .debug, fields: [
        "op": op, "stage": stage, "attempts": String(attempts),
        "durationMs": String(elapsedMilliseconds(since: startedAt)),
        "phase1Ms": String(phase1Ms),
        "phase2Ms": String(phase2Ms),
        "sizeAttempts": String(sizeAttemptsUsed),
        "sizeReadbackMatched": String(sizeReadbackMatched)
    ])
    return true
}
```

- [ ] **Step 2: 编译验证**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!" 或无 error

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+AXHelpers.swift && git commit -m "perf(log): split apply(frame:) durationMs into phase1Ms/phase2Ms + sizeAttempts/sizeReadbackMatched"`

---

### Task 2: setWindowFloat 补充 durationMs + outcome 汇总日志

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift:61-88`（`setWindowFloat` 函数整体替换）

**Why:** `setWindowFloat` 调用的是 `runYabai`（非 `runYabaiVariants`），不传 `logSuccess` → 成功且 <180ms 时**完全不 log**，是 move/restore 共用关键步骤的耗时盲区。补一条带 `outcome` 的汇总日志，覆盖所有退出路径（含 skip）。

- [ ] **Step 1: 替换 setWindowFloat — 用 defer 统一汇总耗时与 outcome**
文件: `Sources/Space/SpaceController+Move.swift:61-88`（替换整个 `setWindowFloat` 函数）

```swift
func setWindowFloat(_ windowID: UInt32, operationID: String? = nil, knownWindowInfo: YabaiWindowInfo? = nil) {
    let op = operationID ?? "none"
    let startedAt = Date()
    var outcome = "unknown"
    // defer 汇总：所有退出路径（含各 skip）都记录耗时，消除 setWindowFloat 耗时盲区。
    defer {
        log("[SpaceController] setWindowFloat", fields: [
            "op": op,
            "windowID": String(windowID),
            "outcome": outcome,
            "durationMs": String(elapsedMilliseconds(since: startedAt))
        ])
    }

    guard isEnabled else {
        outcome = "skipped_disabled"
        return
    }

    // 使用传入的窗口信息或查询缓存
    let info = knownWindowInfo ?? queryWindow(windowID: windowID)
    if let info {
        if info.isFloating {
            outcome = "skipped_already_floating"
            return
        }
        // yabai 无法管理此窗口时，float 切换无意义且必定失败
        if !info.isManageableByYabai {
            outcome = "skipped_unmanaged"
            log("setWindowFloat: skipping (no AX ref, yabai can't manage)", level: .info, fields: [
                "op": op, "windowID": String(windowID)
            ])
            return
        }
    } else {
        outcome = "skipped_query_nil"
        log("setWindowFloat: queryWindow returned nil, skipping toggle", level: .warn, fields: [
            "op": op, "windowID": String(windowID)
        ])
        return
    }

    _ = runYabai(
        arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
        operation: "setWindowFloat",
        operationID: op
    )
    outcome = "toggled"
}
```

- [ ] **Step 2: 编译验证**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift && git commit -m "perf(log): add durationMs+outcome summary to setWindowFloat (closes blind spot)"`

---

### Task 3: moveWindowToMainScreen 拆分 float/apply/postMoveCheck/save 四段耗时

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:116-220`（`setWindowFloat` 调用到 `finished` 日志区间）

**Why:** `moveWindowToMainScreen finished` 只有总 `durationMs`。drift case 的 post-move check（usleep 30ms × 最多 3 次 + 重写）多耗 ~85ms，但当前不可见。拆 4 段后单行日志即可判断是 float/apply/postMoveCheck/save 哪段慢。

- [ ] **Step 1: 在 setWindowFloat/apply/postMoveCheck/save 前后戳记**
文件: `Sources/Window/WindowManager+MoveWindow.swift`（修改 `let effectiveWindowID = ...` 到 `return true` 区间，约 126-221 行）

替换从 `let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID`（约 line 126）到函数末尾 `return true`（line 221）的区间：

```swift
        // 先 float 脱离 yabai 管理，再 apply 设全屏 size —— 顺序关键。
        // （原注释保留：若窗口被 yabai 管理 tiled，apply 的 AX size write 会被 yabai re-tile 覆盖，
        // 导致 move_to_main 后窗口 height 不全屏。先 toggle float 让窗口脱离 yabai，apply 的 size 才能可靠生效。）
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        let floatKnownInfo = (effectiveWindowID == identity.windowID) ? windowInfo : nil
        let floatStart = Date()
        spaceController.setWindowFloat(effectiveWindowID, operationID: op, knownWindowInfo: floatKnownInfo)
        let floatMs = elapsedMilliseconds(since: floatStart)

        // AX apply: move window to main screen + set fullscreen size
        // maxAttempts: 3 —— move_to_main 不切 space（AX 跨屏 move 不触发 space 动画），AX write 通常快；
        // 3 次重试 + 回读验证确保 size 可靠生效，避免单次模式下异步窗口（Electron 等）size 未应用就返回。
        let applyStart = Date()
        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main", maxAttempts: 3) else {
            log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                "op": op, "targetFrame": String(describing: targetFrame)
            ])
            return false
        }
        let applyMs = elapsedMilliseconds(since: applyStart)

        // Post-move 一致性验证（observation 22047：yabai re-tile 覆盖 AX size write → 半屏高 bug）。
        // （原注释保留：apply 两阶段重构后 Phase 2 跨屏 position write 不再回读验证最终 frame；
        // setWindowFloat 的 toggle float 是异步 fork，时序竞争或跨屏 re-tile 可能在 apply 返回后
        // 覆盖 Phase 1 写入的 height。等 yabai 异步 tiling 稳定后读最终 frame：若 size drift 超阈值
        // 则重写 size。幂等单次，不进循环；始终 log finalFrame 供取证。）
        let postMoveCheckStart = Date()
        usleep(30_000)
        if let finalFrame = frame(of: windowAX) {
            let sizeDrift = abs(finalFrame.height - targetFrame.height) + abs(finalFrame.width - targetFrame.width)
            log("[WindowManager] moveWindowToMainScreen: post-move frame check", fields: [
                "op": op,
                "windowID": String(effectiveWindowID),
                "finalFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                "targetSize": "\(Int(targetFrame.width))x\(Int(targetFrame.height))",
                "sizeDrift": String(Int(sizeDrift))
            ])
            if sizeDrift > frameTolerance {
                log("[WindowManager] moveWindowToMainScreen: size drifted after move — rewriting size", level: .warn, fields: [
                    "op": op, "windowID": String(effectiveWindowID), "sizeDrift": String(Int(sizeDrift))
                ])
                for rewriteAttempt in 1...2 {
                    var rewriteSize = CGSize(width: targetFrame.width, height: targetFrame.height)
                    if let rewriteValue = AXValueCreate(.cgSize, &rewriteSize) {
                        _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, rewriteValue)
                    }
                    usleep(30_000)
                    guard let postRewriteFrame = frame(of: windowAX) else { break }
                    let postDrift = abs(postRewriteFrame.height - targetFrame.height) + abs(postRewriteFrame.width - targetFrame.width)
                    log("[WindowManager] moveWindowToMainScreen: post-rewrite check", fields: [
                        "op": op, "windowID": String(effectiveWindowID),
                        "rewriteAttempt": String(rewriteAttempt),
                        "postRewriteFrame": "\(Int(postRewriteFrame.width))x\(Int(postRewriteFrame.height))",
                        "postDrift": String(Int(postDrift))
                    ])
                    if postDrift <= frameTolerance { break }
                }
            }
        }
        let postMoveCheckMs = elapsedMilliseconds(since: postMoveCheckStart)

        // Save toggle record — always save, even when yabai can't determine space
        // (sourceSpace=0 signals "no space info, skip yabai space move on restore")
        let actualTargetFrame = targetFrame
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        let postMoveWindowID = effectiveWindowID
        let saveStart = Date()
        ToggleEngine.shared.save(
            windowID: postMoveWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: teSourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )
        let saveMs = elapsedMilliseconds(since: saveStart)

        log("[WindowManager] moveWindowToMainScreen: ToggleRecord saved", fields: [
            "op": op,
            "windowID": String(postMoveWindowID),
            "sourceSpace": String(describing: sourceSpaceIndex),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
            "targetFrame": "\(Int(actualTargetFrame.origin.x)),\(Int(actualTargetFrame.origin.y))",
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        log("[WindowManager] moveWindowToMainScreen finished", fields: [
            "op": op,
            "windowID": String(effectiveWindowID),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "floatMs": String(floatMs),
            "applyMs": String(applyMs),
            "postMoveCheckMs": String(postMoveCheckMs),
            "saveMs": String(saveMs)
        ])
        return true
```

- [ ] **Step 2: 编译验证**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+MoveWindow.swift && git commit -m "perf(log): split moveWindowToMainScreen into floatMs/applyMs/postMoveCheckMs/saveMs"`

---

### Task 4: ToggleEngine.restore 拆分 lookup/query/move/float/apply/focusSpace 六段耗时

**Depends on:** None
**Files:**
- Modify: `Sources/Toggle/ToggleEngine+Restore.swift:24-140`（`restore` 函数整体替换）

**Why:** `restore: completed` 只有总耗时。restore 历史 spike 主因（moveWindow space move + apply space 动画期 AX write + 条件 focusSpace）全部藏在总耗时下。拆 6 段即可定位。**严守铁律：仅计时+log 字段，不加 guard/return/坐标验证，不改执行流。**

- [ ] **Step 1: 替换 restore 函数 — 在各 sub-stage 戳记，completed 日志扩展（不改执行流）**
文件: `Sources/Toggle/ToggleEngine+Restore.swift:24-140`（替换整个 `restore` 函数，仅新增 Date 戳记与 log 字段，逻辑分支保持原样）

```swift
    @discardableResult
    func restore(windowID: UInt32, triggerSource: String, traceID: String? = nil) -> Bool {
        let trace = traceID ?? makeOperationID(prefix: "te")

        // 1. Load record — windowID only, no PID fallback
        guard let record = load(windowID: windowID) else {
            log("[ToggleEngine] restore: no toggle record", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
            return false
        }

        let wm = WindowManager.shared
        let sc = SpaceController.shared

        // 3. Resolve AX window
        let lookupStart = Date()
        let axLookupID = (record.windowID != windowID) ? windowID : record.windowID
        guard let windowAX = wm.findWindowByPID(record.pid, windowID: axLookupID) else {
            log("[ToggleEngine] restore: AX window not found", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID), "pid": String(record.pid)
            ])
            return false
        }
        let lookupMs = elapsedMilliseconds(since: lookupStart)

        log("[ToggleEngine] restore: starting", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "recordWindowID": String(record.windowID),
            "pid": String(record.pid),
            "sourceSpace": String(record.sourceSpace),
            "triggerSource": triggerSource,
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y)) \(Int(record.origFrame.width))x\(Int(record.origFrame.height))",
            "targetFrame": "\(Int(record.targetFrame.origin.x)),\(Int(record.targetFrame.origin.y)) \(Int(record.targetFrame.width))x\(Int(record.targetFrame.height))"
        ])

        // 4. Move to original space via yabai (skip if sourceSpace=0 — no space info available)
        var moved = false
        // 记录 AX frame set 前的 focused space — 用于检测 macOS 是否自动切换了 space
        // queryMs 覆盖 currentSpaceIndex + queryWindow（移动前查询，命中缓存 ~0ms）。
        let queryStart = Date()
        let preMoveSpace = sc.currentSpaceIndex()
        // 移动前查询一次窗口信息（toggle 开始已查询并缓存，此处命中缓存 ~0ms），
        // 复用给 moveWindow 和 setWindowFloat，避免空间移动后再 queryWindow。
        // （原注释保留：space 切换后 yabai 卡顿，移动后 queryWindow 实测 ~1s fork。）
        let windowInfo = sc.queryWindow(windowID: axLookupID)
        let queryMs = elapsedMilliseconds(since: queryStart)

        var moveMs = 0
        if record.sourceSpace > 0 {
            // focus=false：restore 是"把窗口送回原位"，用户视角留主屏继续工作。
            // （原注释保留：moveWindow 内部的 focusWindow 会切换用户 space 触发 macOS 动画 + SA 阻塞 ~1s；
            //  SLS move 只移窗口不切用户视角。）
            let moveStart = Date()
            moved = sc.moveWindow(
                axLookupID,
                toSpace: .yabai(record.sourceSpace),
                focus: false,
                operationID: trace,
                knownWindowInfo: windowInfo
            )
            moveMs = elapsedMilliseconds(since: moveStart)
            log("[ToggleEngine] restore: space move result", fields: [
                "traceID": trace, "moved": String(moved), "sourceSpace": String(record.sourceSpace)
            ])
        } else {
            log("[ToggleEngine] restore: sourceSpace=0, skipping yabai space move (no space info)", fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }

        // 5. Float on target space — prevents yabai from tiling
        let floatStart = Date()
        sc.setWindowFloat(axLookupID, operationID: trace, knownWindowInfo: windowInfo)
        let floatMs = elapsedMilliseconds(since: floatStart)

        // 6. Apply original frame via AX
        // 单次模式：restore 前已 setWindowFloat，yabai 不会 re-tile，无需重试验证。
        let applyStart = Date()
        if !wm.apply(frame: record.origFrame, to: windowAX, operationID: trace, stage: "restore", maxAttempts: 1) {
            log("[ToggleEngine] restore: AX frame apply failed", level: .warn, fields: [
                "traceID": trace, "windowID": String(windowID)
            ])
        }
        let applyMs = elapsedMilliseconds(since: applyStart)

        // 6b. 检测 macOS 自动切换 space（AX frame set 把焦点窗口移到了其他 display）
        var focusSpaceMs = 0
        if !moved, let preMoveSpace {
            let postMoveSpace = sc.currentSpaceIndex()
            if let postMoveSpace, postMoveSpace != preMoveSpace {
                let steps = preMoveSpace - postMoveSpace
                log("[ToggleEngine] restore: macOS auto-switched space, switching back", level: .info, fields: [
                    "traceID": trace, "preSpace": String(preMoveSpace),
                    "postSpace": String(postMoveSpace), "steps": String(steps)
                ])
                let focusSpaceStart = Date()
                if NativeSpaceBridge.focusSpace(steps: steps, operationID: trace) {
                    // 清除 queryWindow 缓存，因为 space 切换后窗口位置可能已变
                    sc.clearQueryCache()
                }
                focusSpaceMs = elapsedMilliseconds(since: focusSpaceStart)
            }
        }

        // 7. Clear record
        clear(windowID: record.windowID)

        log("[ToggleEngine] restore: completed", fields: [
            "traceID": trace,
            "windowID": String(windowID),
            "targetSpace": String(record.sourceSpace),
            "spaceMoveResult": String(moved),
            "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))",
            "lookupMs": String(lookupMs),
            "queryMs": String(queryMs),
            "moveMs": String(moveMs),
            "floatMs": String(floatMs),
            "applyMs": String(applyMs),
            "focusSpaceMs": String(focusSpaceMs)
        ])

        AuditLogger.shared.record(
            eventType: "restore_success",
            windowID: windowID,
            pid: record.pid,
            details: ["triggerSource": triggerSource, "targetSpace": String(record.sourceSpace)]
        )

        return true
    }
```

- [ ] **Step 2: 编译验证**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 全量回归 — 确认未破坏 restore 执行逻辑**
Run: `swift test 2>&1 | tail -15`
Expected:
  - Exit code: 0
  - 全部测试通过（含 restore 相关测试），无新 FAIL

- [ ] **Step 4: 提交**
Run: `git add Sources/Toggle/ToggleEngine+Restore.swift && git commit -m "perf(log): split ToggleEngine.restore into lookupMs/queryMs/moveMs/floatMs/applyMs/focusSpaceMs"`

---

### Task 5: toggle finished 增加 coreOpMs（核心操作净耗时）

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Toggle.swift:103-153`（restore/move 分支块 + finished 日志）

**Why:** `toggle finished` 已有 `mode` + 总 `durationMs`，但核心操作（restore / moveToMainScreen / moveStuck）的净耗时需单独可见，才能与 `snapshotMs`/`ctxMs`（决策前置开销）区分，单行诊断"是决策慢还是操作慢"。

- [ ] **Step 1: 在 if/else 分支块前后包 coreOpStart 戳记，finished 加 coreOpMs 字段**
文件: `Sources/Window/WindowManager+Toggle.swift`（修改 `if shouldRestore {` 到 finished `logOperationDuration` 调用区间，约 103-153 行）

替换从 `if shouldRestore {`（约 line 103）到 `let durationMs = logOperationDuration(...)` 调用结束（约 line 153）的区间：

```swift
        // coreOpMs：核心操作（restore / moveToMain / moveStuck）净耗时，与 snapshotMs/ctxMs（决策前置）区分。
        let coreOpStart = Date()
        if shouldRestore {
            restore(operationID: op, triggerSource: triggerSource)
            // 设置冷却期：防止 Stop 事件立即把刚恢复的窗口再次拉到主屏
            if let winID = resolvedWindowID {
                HookEventHandler.shared.setMoveCooldown(windowID: winID)
                AuditLogger.shared.record(
                    eventType: "toggle_restore",
                    windowID: winID,
                    details: ["mode": "restore", "source": triggerSource]
                )
            }
        } else if toggleContext["onMainScreen"] == "true" {
            // Window is on main screen but has no valid toggle record → stuck state.
            // Move to secondary screen to unblock the toggle cycle.
            log(
                "[WindowManager] toggle: window stuck on main screen with no toggle record, moving to secondary",
                level: .info,
                fields: ["op": op, "windowID": toggleContext["windowID"] ?? "nil"]
            )
            moveStuckWindowToSecondaryScreen(operationID: op, triggerSource: triggerSource)
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_secondary",
                    windowID: winID,
                    details: ["mode": "move_to_secondary_stuck", "source": triggerSource]
                )
            }
        } else {
            moveToMainScreen(operationID: op, triggerSource: triggerSource)
            if let winID = resolvedWindowID {
                AuditLogger.shared.record(
                    eventType: "toggle_move_to_main",
                    windowID: winID,
                    details: ["mode": "move_to_main", "source": triggerSource]
                )
            }
        }
        let coreOpMs = elapsedMilliseconds(since: coreOpStart)

        let frontAfter = frontmostAppDescriptor()
        let durationMs = logOperationDuration(
            "[WindowManager] toggle finished",
            startedAt: startedAt,
            operationID: op,
            warnThresholdMs: 650,
            fields: [
                "source": triggerSource,
                "mode": mode,
                "frontBefore": frontBefore,
                "frontAfter": frontAfter,
                "coreOpMs": String(coreOpMs)
            ]
        )
```

- [ ] **Step 2: 编译验证**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0

- [ ] **Step 3: 提交**
Run: `git add Sources/Window/WindowManager+Toggle.swift && git commit -m "perf(log): add coreOpMs to toggle finished (net core-op duration vs snapshot/ctx overhead)"`

---

### Task 6: 部署验证 — 全量回归 + 打包部署 + 日志字段确认

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5
**Files:** 无代码修改（验证 + 部署）

**Why:** 日志埋点无直接单元测试，验证靠"编译 + 全量回归不破坏 + 部署后实际 toggle 触发 + grep 新字段"。必须用完整 app bundle + code signing 部署（[[vibefocus-deploy-workflow]]），部署后 open 启动（[[vibefocus-deploy-restart]]）。

- [ ] **Step 1: 全量编译 + 回归**
Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - 编译 "Build complete!"
  - 全部测试通过，无新 FAIL

- [ ] **Step 2: 完整 app bundle 打包 + code signing 部署**
Run: `./scripts/dev-build.sh 2>&1 | tail -15`（或项目既有的打包脚本）
Expected:
  - Exit code: 0
  - 输出含签名验证成功 + 安装到 /Applications/VibeFocus.app
  - **不**使用 `swift build` + `cp` 热部署（违反 deploy workflow）

- [ ] **Step 3: open 启动应用（不留关闭状态）**
Run: `open /Applications/VibeFocus.app`
Expected:
  - 应用启动，日志初始化

- [ ] **Step 4: 实际触发 toggle 后 grep 新字段（人工触发 ⌃Q 2-3 次后执行）**
Run: `grep -E "phase1Ms|phase2Ms|coreOpMs|postMoveCheckMs|floatMs" ~/Library/Logs/VibeFocus/vibefocus.log | tail -20`
Expected:
  - 能看到新埋点字段出现在 `[apply] done` / `toggle finished` / `moveWindowToMainScreen finished` / `restore: completed` / `setWindowFloat` 日志行中
  - 各 sub-stage 字段值合理（phase1Ms 通常 < phase2Ms；floatMs 通常 <50ms；moveMs 在 restore focus=false 时 ~29ms）

---

## Commit 策略

每个 Task 单独提交（Task 1-5），Task 6 为验证+部署无代码提交。提交信息统一 `perf(log):` 前缀，明确说明新增的可观测字段。每次提交前编译通过。

## 自主执行边界

- Task 1-5：纯代码编辑 + 编译验证，AI 全自主 inline 执行（文件少、改动精确、低风险，inline 优于 subagent）。
- Task 6 Step 1-3：编译/测试/打包/open，AI 自主执行。
- Task 6 Step 4：需用户实际按 ⌃Q 触发 toggle（AI 无法模拟物理快捷键），AI 提供 grep 命令并待用户触发后验证字段。

## 质量门禁（每 Task 提交前）

1. **编译**：`swift build` 零 error。
2. **回归**：Task 4/Task 6 跑 `swift test` 全绿（restore 路径必须回归）。
3. **整洁**：无遗留 print/debug，无 TODO，无不用的变量（每段 Date 戳记都被 elapsedMilliseconds 消费进 log）。
4. **集成**：新字段并入既有 `log(fields:)`，不破坏现有字段（op/windowID/traceID 等保持）。
5. **铁律**：零新 AX `frame(of:)`/`cgWindowList`/yabai fork（[[feedback-toggle-ctxms-cgwindowlist]]）；restore 仅计时无 guard（[[feedback-toggle-restore-fragility]]）；不碰配置/init/save（[[feedback-prefs-persistence-fix]]）。
6. **注释保留**：执行替换时**必须保留文件中现有的所有注释**（尤其 apply 两阶段解释、moveWindowToMainScreen 的 setWindowFloat 顺序铁律、post-move 验证结构性教训、restore 的 focus=false 原因）。Plan 代码块中标注"（原注释保留）"的位置以现有文件注释为准，**仅新增** `Date()` 戳记与 log 字段。inline 执行时优先用多个小锚点 Edit（精确匹配）而非整函数替换，避免 old_string 不匹配。
