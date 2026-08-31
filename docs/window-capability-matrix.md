# 窗口操作能力矩阵与确定性边界

> **创建:** 2026-09-01
> **背景:** toggle 跨屏失效事故复盘（2.14/2.15）后的架构决策。VibeFocus 是通用 macOS
> 工具，不是绑定特定环境的定制品——窗口管理必须以 **macOS 原生 AX API 为基线**，
> yabai 只能是**可选增强**（不存在、损坏、任意版本都必须正确降级）。
> **方法:** 静态审查全仓调用点 → 能力矩阵 → 每条边界的可执行验证 → 分阶段重构。

---

## 一、静态审查结论：行为级依赖图谱

窗口操作的执行层有三层，调用关系自上而下：

```
业务层（Toggle/Move/Restore/Hook）
   ↓ 只应依赖抽象
能力层（应新增：WindowServicing 协议）
   ↓
┌───────────────┬──────────────────┐
│ AX 原生层      │ yabai 增强层      │
│ (公开 API)     │ (SpaceController) │
│ 无需第三方     │ 需 yabai daemon   │
└───────────────┴──────────────────┘
```

**现状问题：业务层直接穿透到 yabai**（`sc.moveWindow` / `runYabai` /
`setWindowFloat` 散布在 Toggle/MoveWindow/Restore/Hook 四个业务文件），
且"yabai 存在即假设其行为正确"——v7 float 布局 `--space` 失效事故即此假设破产。

## 二、能力矩阵（确定性边界）

判定标记：✅ 原生公开 API 完全可靠 · ⚠️ 有条件可靠（边界见注） · ❌ 无原生公开 API

| # | 能力 | 原生可行性 | 当前实现 | yabai 依赖 | 确定性边界（必须写进测试） |
|---|------|-----------|---------|-----------|--------------------------|
| 1 | 读窗口列表/frame | ✅ CGWindowList | CGWindowList + queryWindow 双路 | queryWindow 可选 | CGWindowList 在任何环境永远可用；AX 读副屏窗口可能阻塞 1-2s（禁入热路径） |
| 2 | 读窗口 AX 元素 | ✅ AXUIElement | findWindowByPID | 无 | 需辅助功能权限（启动时探针） |
| 3 | 同 display 写 frame | ✅ AX position+size | apply/writePosition/Size | 无（float 窗口/无 yabai 时） | 窗口被 yabai bsp 管理时会被 re-tile 对抗 → 写前必须确认窗口不被平铺管理 |
| 4 | 跨 display 写 frame | ⚠️ 注 4.1 | `--move abs`+`--resize abs`（2026-09-01 起） | moveWindowToFrameViaYabai | 注 4.1：yabai float 布局下裸 AX 跨屏写被 clamp 回原屏（T3 实测）；yabai 的 frame 写经 SA 可跨屏。**无 yabai 环境的裸 AX 跨屏行为 = Phase 1 探针必测项**（Rectangle 等纯 AX 工具证明可行，本实现待固化） |
| 5 | 窗口 focus | ✅ AXRaise + kAXFocused | yabai --focus 主路 + focusWindowByCGWindowID fallback | 主路径依赖 | 原生 fallback 已存在且可靠 → **应倒置：AX 为主，yabai 仅在需要跨屏 focus 时** |
| 6 | float 管理（防 re-tile） | ❌（yabai 概念） | yabai --toggle float | setWindowFloat | 仅 yabai 环境有意义；无 yabai 时不存在对抗，也无需 float。**调用前必须探测 yabai 可用** |
| 7 | space 精确寻址移动 | ❌ 无公开 API（需 SA/私有） | 无（2026-09-01 移除依赖） | 已移除 | yabai float 布局 --space 静默失效（T3 实测）；不可作为任何路径的前提 |
| 8 | 查当前 space | ❌ 私有 API | NativeSpaceBridge（SLS） | 无 | 普通 app 权限下可能失败——调用方必须接受 nil |
| 9 | 切换用户可见 space | ❌ 私有 API | yabai --space --focus 主路 | switchDisplayToSpace | yabai 环境 only；无 yabai 时功能降级为不可用（UI 需表达） |
| 10 | 窗口归属判定（在哪块屏） | ✅ CGWindowList frame ∩ display frame | isOnMainScreen/screenForRect | 无 | 用窗口**中心点**判定（现有实现正确）；坐标系统一 Quartz（左上原点，yabai 同系；NSScreen 是左下原点——转换只在边界做） |

**注 4.1（当前最大不确定点）**：无 yabai / yabai 损坏环境下，裸 AX position 写跨 display
的行为。业界纯 AX 窗口管理器（Rectangle/Magnet）证明可行，但本实现尚未用断言固化。
→ Phase 1 探针项。

## 三、yabai 可用性判定（不做"存在即可用"假设）

三层探测，全部通过才启用 yabai 增强：

```
L1 二进制存在:  /opt/homebrew/bin/yabai、/usr/local/bin/yabai 可执行
L2 daemon 响应: yabai -m query --spaces exit 0 且 JSON 可解析（2s 超时）
L3 行为健康:    space 布局 profile 已知（bsp/float），关键命令按 profile 路由
```

- L2 失败 → 纯 AX 模式（功能矩阵中 ✅ 项全部可用）
- L3 探明 float 布局 → **禁用 `--space`**（T3 实证失效），frame 直写路径
- 探测结果缓存 + 定期复探（yabai 可能中途安装/损坏/升级）

## 四、分阶段重构路线（每阶段测试门禁）

| 阶段 | 内容 | 门禁 |
|------|------|------|
| P0（本轮） | 能力矩阵固化 + SpaceLayoutProfile 探测器 + 纯函数单测 | Standalone 全绿 |
| P1 | CapabilityProbe 运行时探针：无 yabai 环境的裸 AX 跨屏写断言（夹具窗口） | 断言脚本 PASS + 探针可输出结构化报告 |
| P2 | 抽 `WindowServicing` 协议；AX 原生实现 + yabai 实现并立；业务层改依赖协议 | 现有 32 测试 + 新协议 mock 测试全绿；yabai 停用场景端到端 |
| P3 | focus 倒置（AX 主路）；Settings UI 暴露 backend 状态 | 手动矩阵过一遍（有/无 yabai × float/bsp） |

### 2.16 space 精确恢复（2026-09-01 补全）

windows 表的五列空间字段（source_space/source_display/source_yabai_disp/
source_disp_space/target_display）一直都在写，但 restore 曾只按 origFrame 坐标
直写——源屏被切到别的 space 时窗口落错 space。现 restore 前比对源屏可见 space
与 record.sourceSpace，不等则先聚焦源 space 的窗口切回源屏（refocusWindowOnSpace，
不依赖 SA），再 frame 直写，实现精确落位。视角基准必须在切换前采集（实测修正）。
极端焦点竞争（用户焦点恰在目标屏其他 space）仍可能偏差，见 commit 64abb62。

## 五、过程纪律（从事故中固化的规则）

1. **禁止无断言落码**：行为改动前必须有失败→通过的断言（夹具窗口自动化，不碰用户窗口）。
2. **环境快照先行**：排查窗口 BUG 第一步输出环境 profile（yabai 版本/space 布局/float 分布/display 拓扑）。
3. **写后必验证**：一切窗口操作读回确认，exit 0 不构成成功证据；静默失败必须 WARN 落日志。
4. **坐标系铁律**：内部统一 Quartz；NSScreen（Cocoa 左下原点）转换只允许发生在 CoordinateKit 边界函数内。
