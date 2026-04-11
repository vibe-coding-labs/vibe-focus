# 恢复窗口前自动切换副屏到原始工作区

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 恢复窗口到副屏时，如果副屏当前可见工作区不是窗口的原始工作区，先自动切换副屏到正确的工作区，再恢复窗口位置，确保窗口被精确还原到原始 space。

**Architecture:** 在 `WindowManager.applySpaceStrategyForRestore` 的 `.switchToOriginal` 分支中，在 `moveWindow` 调用之前，先调用 `SpaceController.focusSpace(sourceSpace)` 把目标 display 切换到源 space。macOS 的 space 与 display 是绑定关系——`focusSpace` 目标 space 时，拥有该 space 的 display 会切换显示。切换完成后再移动窗口和设置 AX 坐标，确保坐标被应用到正确的可见 space 上。

**Tech Stack:** Swift, yabai CLI (`yabai -m space --focus`), macOS Accessibility API (AXUIElement)

---

## 问题根因

**当前执行顺序（有问题）：**

```
1. moveWindow(windowID, toSpaceIndex: sourceSpace)   ← yabai 把窗口移到源 space
2. focusWindow(windowID)                              ← 聚焦窗口
3. （回到 restore() 主流程）
4. apply(frame: originalFrame, to: window)            ← AX 设置坐标
```

**问题：** 如果副屏当前显示 space B，但窗口原始在 space A：
- 步骤 1 通过 yabai 把窗口关联到 space A（不可见）
- 步骤 4 通过 AX API 设置坐标时，由于 space A 不可见，macOS 可能把窗口拉到当前可见 space B 上应用坐标
- 结果：窗口出现在 space B 的错误位置

**修复后执行顺序：**

```
1. focusSpace(sourceSpace)                            ← 先切副屏到源 space（使其可见）
2. usleep(150ms)                                      ← 等待切换动画完成
3. moveWindow(windowID, toSpaceIndex: sourceSpace)   ← 把窗口移到源 space（现已可见）
4. focusWindow(windowID)                              ← 聚焦窗口
5. （回到 restore() 主流程）
6. apply(frame: originalFrame, to: window)            ← AX 坐标设置在正确的可见 space 上
```

## 边界情况处理

| 场景 | 处理方式 |
|------|----------|
| yabai 未安装 | `canControlSpaces` = false，跳过 space 操作，降级为仅 frame 恢复（现有行为） |
| scripting-addition 未加载 | 已有自动恢复机制 `attemptScriptingAdditionRecovery` |
| space 索引已漂移 | 已有 `resolveSourceSpaceIndexForRestore()` 通过 display+local 索引重新解析 |
| 副屏已显示正确 space | `sourceSpace != currentSpace` 检查，如果已在正确 space 则跳过 |
| focusSpace 调用失败 | 记录 warn 日志，继续执行 moveWindow（尽力而为，不阻断恢复） |
| 窗口在主屏的另一个 space | `focusSpace` 切换主屏到正确 space，逻辑同样正确 |
| 切换动画未完成就设坐标 | `usleep(150_000)` 等待 150ms（动画通常 100-200ms） |

## 改动范围

**修改两个方法：**
1. `Sources/WindowManager.swift` 的 `applySpaceStrategyForRestore` 方法 — 添加 focusSpace 预切换 + 诊断日志
2. `Sources/WindowManager.swift` 的 `restore` 方法 — 补充关键诊断日志

**不改动的部分：**
- `.pullToCurrent` 策略 — 不需要切换空间，窗口拉到当前空间即可
- `SpaceController` — 不需要新增方法，`focusSpace` 已存在且可用
- 其他任何文件

---

## 诊断日志完整设计

**设计原则：**
1. **每个关键操作都有 before/after 状态快照** — 失败时可从日志还原完整执行路径
2. **统一前缀 + op ID** — 可用一条 grep 追踪单次操作的完整生命周期
3. **包含验证数据** — 不仅记录"做了什么"，还记录"做完后实际状态是什么"
4. **可回答的诊断问题** — 每条日志设计时都对应一个具体可回答的问题

### 完整日志链路图

```
restore started                         ← Q: 初始状态是什么？
│
├─ [applySpaceStrategyForRestore]
│  ├─ restore_space_pre_focus           ← Q: focusSpace 前各 space 是什么状态？
│  ├─ restore_space_post_focus          ← Q: focusSpace 调用成功了吗？耗时？space 变了吗？
│  ├─ restore_space_post_settle         ← Q: 动画完成后 space 稳定了吗？
│  ├─ restore_space_post_move           ← Q: 窗口移动后实际在哪个 space？
│  ├─ restore_space_move_failed         ← Q: moveWindow 为什么失败？
│  └─ restore_space_result              ← Q: space 策略整体结果？
│
├─ restore_found_window                 ← Q: 找到窗口了吗？它的当前 frame/space 是什么？
├─ restore_pre_apply_frame              ← Q: 设坐标前窗口的 frame 和 space 是什么？
├─ restore_post_apply_frame             ← Q: 设坐标后窗口的 frame 和 space 是什么？
│
└─ restore finished                     ← Q: 最终结果？耗时？最终 space 验证状态？
```

### 各日志点详细设计

| # | 日志标记 | 位置 | 记录字段 | 可回答的诊断问题 |
|---|----------|------|----------|-----------------|
| 1 | `restore started` | restore() 入口 | op, source, hasToken, hasOriginalFrame, hasTargetFrame, savedStateCount | 初始状态是否完整？ |
| 2 | `restore_space_pre_focus` | focusSpace 前 | op, windowID, sourceSpace, currentSpaceAtEntry, windowActualSpace, sourceYabaiDisplay, sourceDisplaySpace | focusSpace 前各 space 是什么状态？窗口实际在哪个 space？ |
| 3 | `restore_space_post_focus` | focusSpace 后 | op, focusSucceeded, focusDurationMs, targetSpace, actualCurrentSpace, spaceChanged | focusSpace 成功了吗？耗时多久？space 真的变了吗？ |
| 4 | `restore_space_post_settle` | usleep 后 | op, targetSpace, actualCurrentSpace, settleOk | 150ms 够吗？动画完成后 space 稳定在目标值了吗？ |
| 5 | `restore_space_post_move` | moveWindow 后 | op, windowID, targetSpace, windowActualSpace, moveVerified | 窗口移动后真的在目标 space 吗？ |
| 6 | `restore_space_move_failed` | moveWindow 失败 | op, windowID, targetSpace | moveWindow 为什么失败？ |
| 7 | `restore_space_result` | 策略结束 | op, outcome, sourceSpace, focusOk, focusDurationMs | 整体结果？ |
| 8 | `restore_found_window` | restoreWindow 后 | op, windowID, currentFrame, windowActualSpace | 找到的窗口在什么位置和 space 上？ |
| 9 | `restore_pre_apply_frame` | apply(frame) 前 | op, windowID, currentFrame, targetFrame, windowActualSpace | 设坐标前窗口的实际位置和目标位置？ |
| 10 | `restore_post_apply_frame` | apply(frame) 后 | op, appliedFrame, targetFrame, windowActualSpace, frameMatched | 设坐标成功了吗？实际位置与目标位置匹配吗？窗口最终在哪个 space？ |
| 11 | `restore finished` | restore() 结束 | op, outcome, durationMs, finalSpaceVerified | 最终结果和总耗时？ |

### 故障诊断快速查询命令

```bash
# === 单次操作的完整生命周期 ===
# 替换 <OP_ID> 为实际操作 ID
grep "restore" /tmp/vibefocus-events.jsonl | grep '"op":"<OP_ID>"' | python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin]"

# === 快速定位哪个阶段失败 ===
grep "restore_space\|restore_found_window\|restore_pre_apply\|restore_post_apply\|restore finished\|restore failed" /tmp/vibefocus-events.jsonl | python3 -c "
import sys, json
for l in sys.stdin:
    d = json.loads(l)
    msg = d.get('message','')
    fields = d.get('fields',{})
    print(f\"{d.get('level','?'):5} | {msg[:60]:60} | op={fields.get('op','?')}\")
"

# === focusSpace 效果追踪 ===
# 看 focusSpace 是否真的改变了 space
grep "pre_focus\|post_focus\|post_settle" /tmp/vibefocus-events.jsonl | python3 -c "
import sys, json
for l in sys.stdin:
    d = json.loads(l)
    f = d.get('fields',{})
    msg = d.get('message','').split(']')[-1].strip()
    print(f'{msg:30} | current={f.get(\"actualCurrentSpace\",\"?\"):4} | target={f.get(\"targetSpace\",\"?\"):4} | ok={f.get(\"settleOk\",f.get(\"focusSucceeded\",\"?\"))}')
"

# === moveWindow 效果追踪 ===
# 看窗口是否真的到了目标 space
grep "post_move" /tmp/vibefocus-events.jsonl | python3 -c "
import sys, json
for l in sys.stdin:
    d = json.loads(l)
    f = d.get('fields',{})
    print(f'window={f.get(\"windowID\",\"?\")} | target={f.get(\"targetSpace\",\"?\")} | actual={f.get(\"windowActualSpace\",\"?\")} | verified={f.get(\"moveVerified\",\"?\")}')
"

# === frame 应用前后对比 ===
grep "pre_apply_frame\|post_apply_frame" /tmp/vibefocus-events.jsonl | python3 -c "
import sys, json
for l in sys.stdin:
    d = json.loads(l)
    f = d.get('fields',{})
    msg = 'BEFORE' if 'pre_apply' in d.get('message','') else 'AFTER '
    print(f'{msg} | target={f.get(\"targetFrame\",\"?\")} | actual={f.get(\"currentFrame\",f.get(\"appliedFrame\",\"?\"))} | space={f.get(\"windowActualSpace\",\"?\")}')
"

# === 总览：最近 N 次 restore 操作的结果 ===
grep "restore finished" /tmp/vibefocus-events.jsonl | tail -10 | python3 -c "
import sys, json
for l in sys.stdin:
    d = json.loads(l)
    f = d.get('fields',{})
    print(f'{d.get(\"ts\",\"?\")} | {f.get(\"outcome\",\"?\"):20} | duration={f.get(\"durationMs\",\"?\")}ms | op={f.get(\"op\",\"?\")}')
"
```

---

### Task 1: 修改 applySpaceStrategyForRestore — 添加 focusSpace 预切换 + 诊断日志

**Files:**
- Modify: `Sources/WindowManager.swift:663-693`

- [ ] **Step 1: 替换 `.switchToOriginal` 分支中的 moveWindow 调用逻辑**

将 `Sources/WindowManager.swift` 第 663 行开始的 `if spaceController.moveWindow(...)` 块替换为包含 `focusSpace` 预切换和诊断日志的新逻辑：

**旧代码（第 663-693 行）：**

```swift
            if spaceController.moveWindow(windowID, toSpaceIndex: sourceSpace, focus: false, operationID: op) {
                log(
                    "[WindowManager] moved window back to source space",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "space": String(sourceSpace)
                    ]
                )
                if !spaceController.focusWindow(windowID, operationID: op) {
                    log(
                        "[WindowManager] failed to focus restored window on source space",
                        level: .warn,
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(sourceSpace)
                        ]
                    )
                }
            } else {
                log(
                    "[WindowManager] failed to restore source space",
                    level: .error,
                    fields: [
                        "op": op,
                        "space": String(sourceSpace)
                    ]
                )
                return false
            }
            return true
```

**新代码：**

```swift
            // === Phase 1: focusSpace 预切换 ===
            // 先切换目标 display 到源 space，确保 space 可见后再移动窗口
            // 这解决了副屏当前显示不同 space 时 AX 坐标被应用到错误 space 的问题

            let preFocusCurrentSpace = currentSpace
            let windowSpaceBefore = spaceController.windowSpaceIndex(windowID: windowID)
            log(
                "[WindowManager] restore_space_pre_focus",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "sourceSpace": String(sourceSpace),
                    "currentSpaceAtEntry": String(preFocusCurrentSpace),
                    "windowActualSpace": String(describing: windowSpaceBefore),
                    "sourceYabaiDisplay": String(describing: lastSourceYabaiDisplayIndex),
                    "sourceDisplaySpace": String(describing: lastSourceDisplaySpaceIndex)
                ]
            )

            let focusStartedAt = Date()
            let focusSucceeded = spaceController.focusSpace(sourceSpace, operationID: op)
            let focusDurationMs = elapsedMilliseconds(since: focusStartedAt)
            let postFocusSpace = spaceController.currentSpaceIndex()

            log(
                "[WindowManager] restore_space_post_focus",
                fields: [
                    "op": op,
                    "focusSucceeded": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs),
                    "targetSpace": String(sourceSpace),
                    "actualCurrentSpace": String(describing: postFocusSpace),
                    "spaceChanged": String(postFocusSpace != preFocusCurrentSpace)
                ]
            )

            if focusSucceeded {
                // 等待 space 切换动画完成（动画通常需要 100-200ms）
                usleep(150_000)

                let postSettleSpace = spaceController.currentSpaceIndex()
                log(
                    "[WindowManager] restore_space_post_settle",
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "actualCurrentSpace": String(describing: postSettleSpace),
                        "settleOk": String(postSettleSpace == sourceSpace)
                    ]
                )
            } else {
                log(
                    "[WindowManager] restore_space_focus_failed_continuing",
                    level: .warn,
                    fields: [
                        "op": op,
                        "targetSpace": String(sourceSpace),
                        "focusDurationMs": String(focusDurationMs)
                    ]
                )
            }

            // === Phase 2: moveWindow ===
            if spaceController.moveWindow(windowID, toSpaceIndex: sourceSpace, focus: false, operationID: op) {
                let windowSpaceAfterMove = spaceController.windowSpaceIndex(windowID: windowID)
                log(
                    "[WindowManager] restore_space_post_move",
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace),
                        "windowActualSpace": String(describing: windowSpaceAfterMove),
                        "moveVerified": String(windowSpaceAfterMove == sourceSpace)
                    ]
                )
                if !spaceController.focusWindow(windowID, operationID: op) {
                    log(
                        "[WindowManager] failed to focus restored window on source space",
                        level: .warn,
                        fields: [
                            "op": op,
                            "windowID": String(windowID),
                            "space": String(sourceSpace)
                        ]
                    )
                }
            } else {
                log(
                    "[WindowManager] restore_space_move_failed",
                    level: .error,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(sourceSpace)
                    ]
                )
                return false
            }

            log(
                "[WindowManager] restore_space_result",
                fields: [
                    "op": op,
                    "outcome": "success",
                    "sourceSpace": String(sourceSpace),
                    "focusOk": String(focusSucceeded),
                    "focusDurationMs": String(focusDurationMs)
                ]
            )
            return true
```

---

### Task 2: 修改 restore() 主流程 — 补充关键诊断日志

**Files:**
- Modify: `Sources/WindowManager.swift:287-399`（restore 方法中 applySpaceStrategyForRestore 之后的逻辑）

- [ ] **Step 2: 在 restoreWindow 找到窗口后添加状态快照日志**

在 `Sources/WindowManager.swift` 的 `restore()` 方法中，找到第 298-309 行的 `guard let window = restoreWindow(using: token)` 块。在该 guard 的成功分支后（第 309 行之后，第 311 行之前）插入：

**在以下代码之后插入：**
```swift
        guard let window = restoreWindow(using: token) else {
            ...
            return
        }
```

**插入新代码：**

```swift
        // 诊断日志：记录找到的窗口的当前状态
        let restoredWindowFrame = self.frame(of: window)
        let restoredWindowID = windowHandle(for: window)
        let restoredWindowSpace = restoredWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_found_window",
            fields: [
                "op": op,
                "windowID": String(describing: restoredWindowID),
                "currentFrame": String(describing: restoredWindowFrame),
                "windowActualSpace": String(describing: restoredWindowSpace),
                "spacePrepared": String(spacePrepared)
            ]
        )
```

- [ ] **Step 3: 在 apply(frame) 前后添加诊断日志**

在 `restore()` 方法中，找到第 335-341 行的 `"restoring frame"` 日志。替换为更详细的版本：

**旧代码（第 335-341 行）：**
```swift
        log(
            "[WindowManager] restoring frame",
            fields: [
                "op": op,
                "targetFrame": String(describing: frame)
            ]
        )
```

**新代码：**
```swift
        let preApplyFrame = self.frame(of: window)
        let preApplyWindowID = windowHandle(for: window)
        let preApplySpace = preApplyWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_pre_apply_frame",
            fields: [
                "op": op,
                "windowID": String(describing: preApplyWindowID),
                "currentFrame": String(describing: preApplyFrame),
                "targetFrame": String(describing: frame),
                "windowActualSpace": String(describing: preApplySpace)
            ]
        )
```

- [ ] **Step 4: 在 frame readback 后添加 space 验证日志**

在 `restore()` 方法中，找到第 367-373 行的 `"restore frame readback"` 日志。替换为更详细的版本：

**旧代码（第 367-373 行）：**
```swift
        log(
            "[WindowManager] restore frame readback",
            fields: [
                "op": op,
                "frame": String(describing: restoredFrame)
            ]
        )
```

**新代码：**
```swift
        let readbackWindowID = windowHandle(for: window)
        let readbackSpace = readbackWindowID.flatMap { spaceController.windowSpaceIndex(windowID: $0) }
        log(
            "[WindowManager] restore_post_apply_frame",
            fields: [
                "op": op,
                "appliedFrame": String(describing: restoredFrame),
                "targetFrame": String(describing: frame),
                "frameMatched": String(framesMatch(restoredFrame, frame)),
                "windowActualSpace": String(describing: readbackSpace)
            ]
        )
```

- [ ] **Step 5: 在 restore finished 中添加最终验证状态**

在 `restore()` 方法中，找到第 389-399 行的 `"restore finished"` 日志。替换为更详细的版本：

**旧代码（第 389-399 行）：**
```swift
        resetActiveWindowContext(removeState: true)
        let outcome = spacePrepared ? "restored" : "restored_frame_only"
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": outcome,
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=\(outcome)")
```

**新代码：**
```swift
        resetActiveWindowContext(removeState: true)
        let outcome = spacePrepared ? "restored" : "restored_frame_only"
        let finalDurationMs = elapsedMilliseconds(since: startedAt)
        log(
            "[WindowManager] restore finished",
            fields: [
                "op": op,
                "outcome": outcome,
                "durationMs": String(finalDurationMs),
                "spacePrepared": String(spacePrepared)
            ]
        )
        CrashContextRecorder.shared.record("restore_success op=\(op) outcome=\(outcome) durationMs=\(finalDurationMs)")
```

- [ ] **Step 6: 编译验证**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected: `Build complete!` 无错误输出

- [ ] **Step 7: 手动测试 — 基本场景**

测试步骤：
1. 确保双屏环境，副屏有 >= 2 个工作区（space A 和 space B）
2. 在副屏 space A 打开一个终端窗口，记录其位置
3. 按快捷键将窗口移到主屏（窗口最大化到主屏）
4. 切换副屏到 space B（副屏现在显示 space B，不是 space A）
5. 按快捷键恢复窗口
6. **预期结果：** 副屏自动切换回 space A，窗口精确恢复到 space A 的原始位置和大小

- [ ] **Step 8: 检查日志验证完整流程**

Run: `grep "restore" /tmp/vibefocus-events.jsonl | tail -30 | python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin]"`
Expected: 应看到以下完整日志序列（通过相同 op ID 串联）：
1. `restore started` — 初始状态
2. `restore_space_pre_focus` — focusSpace 前状态快照
3. `restore_space_post_focus` — focusSpace 结果
4. `restore_space_post_settle` — 动画完成验证
5. `restore_space_post_move` — 窗口移动验证
6. `restore_space_result` — space 策略结果
7. `restore_found_window` — 找到的窗口状态
8. `restore_pre_apply_frame` — 设坐标前状态
9. `restore_post_apply_frame` — 设坐标后验证
10. `restore finished` — 最终结果

- [ ] **Step 9: 手动测试 — 边界场景**

9a. **副屏已在正确 space：**
- 不切换副屏 space，直接按快捷键恢复
- 预期：不触发 focusSpace（`sourceSpace == currentSpace` 时已被 guard 跳过），日志中不出现 `restore_space_pre_focus`

9b. **多次移动恢复：**
- 移动 → 恢复 → 再移动 → 切换副屏 space → 再恢复
- 预期：每次日志都完整，每次都正确恢复

- [ ] **Step 10: 提交**
