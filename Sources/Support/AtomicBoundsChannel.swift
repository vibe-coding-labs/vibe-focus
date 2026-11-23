// AtomicBoundsChannel.swift
// VibeFocus — iTerm2 原子 bounds 写通道（2026-11-24）
//
// ## 为什么需要它（真机探针 2026-11-23/24，4ms 帧采样实证）
// 跨屏且改尺寸的移动，历史两段路径（尺寸 AX + 位置 yabai）在 iTerm2 上有三层可见问题：
// 1. iTerm2 对 AX position/size 写一律做 ~300ms 内部渐进动画（ease-out；pos-only 也滑行）；
// 2. AX pos+size 背靠背时 iTerm2 会吞掉 position（延迟数秒才落地）——状态机可被楔死成
//    「无 session 不可关闭」的僵尸窗（探针 T7 实锤，2026-11-23 真机事故即由此产生）；
// 3. yabai --move 的三连写（size→pos→size，进程内缓存宽高）与 iTerm2 字符网格吸附叠加
//    （目标 640 落 664，旧账）。
// 用户感知即「来回跳 + 水波」的多段乱动画。
//
// AppleScript `set bounds` 是实测唯一的原子通道：一次 AppleEvent 同时写位置+尺寸，
// 双向跨屏 4ms 采样零中间态、像素级精确（偏差和 = 0）、不抢焦点、不触发内部动画。
// 语义 = 全局 quartz 坐标 {x1, y1, x2, y2}（左上原点；主屏正 y 区与副屏负 y 区双验证）。
//
// ## 适用边界（全场景自适应，失败永不硬失败）
// - 仅 iTerm2（com.googlecode.iterm2）。Terminal.app 的 set bounds 是「窗口当前屏局部
//   坐标」语义且跨屏必漂移（仓库 2026-09-04 实证 + 2026-11-24 探针复核一致），
//   Terminal 继续走历史两段路径。
// - 仅跨屏（读写前后帧所在 displayID 不同）：同屏 AX resize 快且无 fork，网格摆放等
//   同屏热路径不回退（osascript fork ~200ms）。
// - 发令失败 / 收敛不满足 → 调用方落回历史两段路径自愈，本通道只做加速不做依赖。
// - TCC：与 TerminalContext 链路同 grant（app 本就向 iTerm2 发 AppleEvents）；
//   未授权时 osascript 非零退出 → 走 fallback，功能不降级。

import Foundation

enum AtomicBoundsChannel {

    /// 允许走原子 bounds 的 app 白名单（bundle id 精确匹配）。
    static func supports(bundleID: String?) -> Bool {
        bundleID == "com.googlecode.iterm2"
    }

    /// iTerm2 原子写脚本：quartz 全局角点 {x1,y1,x2,y2}（真机实证像素精确）。
    static func iterm2Script(windowID: UInt32, frame: CGRect) -> String {
        let x1 = Int(frame.origin.x.rounded())
        let y1 = Int(frame.origin.y.rounded())
        let x2 = Int((frame.origin.x + frame.width).rounded())
        let y2 = Int((frame.origin.y + frame.height).rounded())
        return "tell application id \"com.googlecode.iterm2\" to set bounds of window id \(windowID) to {\(x1), \(y1), \(x2), \(y2)}"
    }
}
