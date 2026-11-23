// WindowFrameCommand.swift
// VibeFocus — 窗口 frame 写入命令的唯一构造点（2026-11-21 「多段动画/卡顿」根治）
//
// ## 场景（用户主诉「窗口切换动画非常脑残，多个步骤、先怎么着再怎么着、很卡顿」）
// 用户装了 `window_animation_duration`（yabai 配置）。查 yabai 源码（window_manager.c）：
//   - `window --move abs:x:y`   → window_manager_move_window_relative → window_manager_animate_window
//   - `window --resize abs:w:h` → window_manager_resize_window_relative(animate: true) → window_manager_animate_window
// 两段各自跑一段**独立**的 proxy 动画（各自建 SLS proxy、各自 CVDisplayLink 插值、各自动画时长）。
// 旧写法把 move 与 resize 拆成两次进程调用、中间还夹一个「等第一段可观测」的轮询
// （FrameWriteExecutor.waitForPhase），于是用户看到的就是：
//   先移动 → 停 → 再变大/变小（甚至中途被源屏 clamp 再弹回），两段动画时长之和 + 段间轮询。
// 这正是「多个步骤、先怎么着再怎么着」的来源。
//
// ## 为什么这次能合成一步
// yabai 的 message 解析器（message.c handle_domain_window）是一个
//   `for (; token_is_valid(command); command = get_token(&message))`
// 循环：`yabai -m window <id> --move abs:x:y --resize abs:w:h` 会在**同一条消息**里
// 依次执行两条命令，且都作用于同一个 acting_window。合成后：
//   - 只剩一次 fork（省 ~40-90ms）；
//   - 只剩一次「等生效」的轮询（旧版段间 waitForPhase 最多再等 300ms）；
//   - 两段写入在 yabai 侧连续无间隔，视觉上是一次跳变而非两段接续动画。
// 2026-11-22 起动画本身也不再存在：YabaiAnimationGuard 把 window_animation_duration
// 断言为 0（见 Sources/Support/YabaiAnimationGuard.swift），合发只保留「省 fork/省轮询」的收益。
//
// ## 2026-11-23 降级为**回退**通道（重要）
// 合发把尺寸也交给了 yabai。yabai 在动画总闸为 0 时，`--move`/`--resize` 都落到
// `window_manager_set_window_frame()`：它「size → position → size」写三遍，且 size 用的是
// yabai 进程内缓存的宽高。对按字符网格吸附的终端窗口（iTerm2）这组写入会停在吸附值
// （目标 640 → 664，每列 ~8px）。App 直接写一次 `kAXSizeAttribute` 才是精确的。
// 因此 `moveWindowToFrameViaYabai` 现在：AX 尺寸可写时走「AX resize + yabai move」
// （FramePhase1Plan.axPrecise），**只有** AX 不可写/已证明吞写时才用本类型的合发；
// 会话恢复/终端网格投递仍用合发——它们的目标窗是新建的、AX 引用尚在懒建立期，
// 且历史实证（SpaceDelivery 头注）AX resize 会被 iTerm2 的窗口自动恢复行为吞掉。
// 命令构造收敛到本类型，两个写通道（yabai / AX）与三处调用点同源，避免再次各写一份。

// ## 语义契约（Runner FrameCommand 域锁定）
// - 参数顺序恒为 `--move` 在 `--resize` 前（与历史 move-then-resize 一致；先定位再定尺寸，
//   中间态窗口落在目标屏，VisualDirty 风险留 R5 真机定夺）；
// - 坐标/尺寸取整与历史 `Int(...)` 一致（yabai 的 abs 只接受数值，小数会解析失败）；
// - 单发入口（moveOnly / resizeOnly）供补发计划按「只缺一维」时使用，参数与合发完全同源。

import Foundation

/// 窗口 frame 写入的 yabai 参数构造器（纯函数，无 IO）。
enum WindowFrameCommand {

    /// 两段同发的参数（按写序排列）：`["-m", "window", "<id>", "--move", "abs:x:y", "--resize", "abs:w:h"]`。
    ///
    /// 单次 fork 内由 yabai 依次执行（message.c 的 window 域是
    /// `for (; token_is_valid(command); ...)` 循环），消灭段间等待与第二段动画起点偏移。
    /// 写序保留历史语义：收窄用 resizeThenMove、放大用 moveThenResize，
    /// 使中间态窗口被源屏或目标 frame 包含（见 FrameConvergence.writeOrder）。
    static func applyFrame(windowID: UInt32, frame: CGRect, order: FrameWriteOrder) -> [String] {
        let move = ["--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"]
        let resize = ["--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"]
        let segments = order == .resizeThenMove ? resize + move : move + resize
        return ["-m", "window", "\(windowID)"] + segments
    }

    /// 仅原点（补发计划只缺 origin 时单发；与合发参数逐字同源）。
    static func moveOnly(windowID: UInt32, frame: CGRect) -> [String] {
        ["-m", "window", "\(windowID)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"]
    }

    /// 仅尺寸（补发计划只缺 size 时单发；与合发参数逐字同源）。
    static func resizeOnly(windowID: UInt32, frame: CGRect) -> [String] {
        ["-m", "window", "\(windowID)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"]
    }
}
