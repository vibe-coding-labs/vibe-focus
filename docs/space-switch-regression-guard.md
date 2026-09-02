# 工作区恢复（Restore）回归防护（2026-09-02 重写，与代码同步）

> 旧版防护规则描述的是已删除机制（applySpaceStrategyForRestore /
> NativeSpaceBridge.moveWindow / CGEvent 方向键切 space），按它修代码会修错地方。
> 当前机制见 `docs/window-restore-architecture.md`，本文只列守护规则与历史教训。

## 核心语义（不可漂移）

恢复 = **切回原工作区**：窗口 frame 回到源屏 origFrame，且源屏可见 space 尽量精确
切回 sourceSpace；**用户视角不跟随窗口**（视角守卫把 focused space 切回移动前值）。

> 「拉到当前工作区」从未实现过（restoreStrategy 死设置，2658da5 下线）。
> 若未来要重新引入，必须先有可靠的原语，做不到就不要给用户选项。

## 当前机制下可用原语清单（2026-09-02 实测校准，yabai v7.1.18 / macOS 15.7）

| 原语 | 依赖 | 可用性 |
|------|------|--------|
| `yabai --move abs` / `--resize abs`（frame 直写） | 无（窗口须已 float） | ✅ 跨 display 可靠（T3 断言） |
| 聚焦窗口带动视角切换（`window --focus`） | AX 通道，不依赖 SA | ✅ 跨 display 可靠 |
| `yabai space --focus`（直接切 space，空 space 也可切） | **scripting-addition** | ⚠️ **运行时探测**：2026-09-02 E2E 实测本机 `space --focus` 报 scripting-addition = **SA 未加载**（此前据「query 含 display 字段」判 SA 已加载系误判——v7 的 query 走 CGS 内部通道不依赖 SA，该旧判据**恒真**，已重写为无副作用探针 `saProbeVerdict`，见 `SpaceController+Recovery`）。**SA 状态随环境漂移，禁止硬编码假设，一律以 `canControlSpaces` 运行时判据分流** |
| `yabai window --space` | v7 float 布局 | ❌ exit 0 但窗口不动（T3 实测） |
| SLSMoveWindowsToManagedSpace | universal owner connection | ❌ 权限不足，从未可用 |
| CGEvent ctrl+方向键切 space | separate-Spaces | ❌ 无法跨 display |

**改 restore 机制前必跑 `Tests/AXMoveValidation.swift` 断言脚本**——
历史上两次大回归（方向键法、`window --space` 法）都是选了上表里 ❌ 的原语。

## 历史回归教训（按根因归类，修 restore 前先对号）

### 教训 A：用性能优化跳过关键步骤（Bug #1，2026-05）

`focusSpaceKnownBroken` 标记曾把整个 space 策略连同 move/focus 一起跳过。
**规则**：降级只降级失败的那一层，不许跳过整个编排。当前的对应结构：
`focusSpace` 失败 → 仅降级到 `refocusWindowOnSpace`，frame 直写与结局裁决不受影响。

### 教训 B：失败被伪装成成功 + 销毁现场（2026-09-02 诚实化重构的根因）

旧代码 frame 写失败仍清 record、审计 `restore_success`、`return true`——
断显/最小化场景用户按热键毫无反馈且无法重试，日志还显示成功。
**规则**：结局由 `RestoreOutcome` 唯一定义；审计事件与 record 处置必须是结局的
派生，不许在编排中途提前写 success / 提前清 record。
Retryable（origFrame 仍在屏上）保留 record；Permanent（屏外）清 record 交 stuck 解堵。

### 教训 C：依赖静默失效的原语（yabai v7 `window --space`）

exit 0 但窗口不动。**规则**：所有 yabai 写操作必须以**读回验证**为准
（FrameConvergence 收敛循环），exit code 不可信；更换原语前跑 AXMoveValidation。

### 教训 D：space 归属判断不看坐标变换（副屏纵向排布）

Quartz 与 Cocoa 坐标系 y 轴相反，直接比较只有主屏碰巧正确（第十三刀修正）。
**规则**：屏归属判断一律走 `displayContext`/`CoordinateKit`（含 Quartz→Cocoa 变换），
禁止散落手写比较。

### 教训 E：浮窗写 frame 不等重摆（2026-09-01 尺寸错乱根因）

`--toggle float` 触发 yabai 默认重摆，写早了会被覆盖。
**规则**：settle 时长从 `WindowSettle` 常量表取；仅在真发生 float 时等待
（`FloatToggleOutcome.didToggle`），既不裸等也不跳等。

### 教训 F：能力判据靠推测不靠实测（2026-09-02 SA 判据恒真）

`checkScriptingAdditionLoaded` 旧判据「query 含 display 字段」在 yabai v7 恒真
（query 走 CGS 不依赖 SA）→ SA 未加载时 `canControlSpaces` 误报可用，
focusSpace/直切层每次白撞 SA 错误，设置面板还显示一切正常。
**规则**：能力可用性必须用**无副作用探针实测**（对当前 space 发 `space --focus`，
stderr 分类裁决），不许用间接字段推测；探针裁决走纯函数 `saProbeVerdict`（测试锁定）。

### 教训 G：等固定时长 ≠ 等状态到位（P1-2）

固定 usleep 是拍脑袋：等短了被异步重摆覆盖（教训 E 同源），等长了白耗时。
**规则**：有可观测目标态的等待一律用 `ConditionPolling.waitUntil` 有界轮询
（早满足早返回，超时如实降级）；轮询必须绕过查询缓存（`ignoreCache`——
缓存里是操作前的旧状态，读缓存恒假会让轮询白转满预算并误判失败）。
无观测信号的等待（float 重摆完成）保留固定档并写明理由。

## 防护规则（当前版）

1. **任何优化不得跳过**：源屏预切回、frame 读回验证、结局裁决、视角守卫。
2. **exit code 不是成功判据**，读回收敛才是（教训 C）。
3. **最小化窗口快检必须在源屏预切回之前**（否则白拖用户视角，2026-09-02 补）。
4. **refocus 候选偏好非最小化**（`selectRefocusCandidate`，测试锁定）。
5. **改任何 space 相关代码后**，手动闭环验证：
   1) 副屏 toggle 到主屏；2) 源屏切到别的 space 后 restore → 窗口应回 sourceSpace；
   3) 源屏 space 清空后 restore → SA 可用时应精确切回（spaceExact=true，P0-1 直切通道）；
      SA 失效时结局应如实（spaceExact=false + WARN，不得 crash/假成功）；
   4) 最小化后 restore → 快速失败且 record 保留；5) hook 自动聚焦不受影响。
6. **门禁**：`swift build` 零警告 + `bash Tests/run_all_tests.sh` 全绿 +
   `swift run VibeFocusTestRunner` 全绿（真代码直测 + `bash scripts/coverage_test_runner.sh`
   覆盖率数字；新写/重写的纯决策逻辑按 2.13 口径分支穷尽覆盖至 100%）+
   restore 机制改动必跑 `Tests/RestoreScenarioValidation.swift` 与
   `Tests/AXMoveValidation.swift`。
