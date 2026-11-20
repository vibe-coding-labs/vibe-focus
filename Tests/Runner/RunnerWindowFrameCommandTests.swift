import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerWindowFrameCommandTests.swift
// 靶：WindowFrameCommand 参数构造（2026-11-21 原子合发）——两段合发成单条 yabai
// 消息、写序保留、补发单发与合发逐字同源。合发的根因与语义见
// Sources/Support/WindowFrameCommand.swift 头注（yabai window_animation_duration
// 下每个写原语各跑一段独立动画 = 用户主诉的「多步骤、先怎么着再怎么着」）。

extension RunnerHarness {
    func runWindowFrameCommandTests() {
        let frame = CGRect(x: 100, y: 200, width: 1653, height: 1079)
        let wid: UInt32 = 4242

        // A. 合发：单条消息含 move + resize，前缀顺序固定
        do {
            let resizeThenMove = WindowFrameCommand.applyFrame(windowID: wid, frame: frame, order: .resizeThenMove)
            check("frameCommand A1: 合发前缀 = -m window <id>",
                  Array(resizeThenMove.prefix(3)) == ["-m", "window", "\(wid)"])
            check("frameCommand A2: 收窄序合发 = resize 在 move 前",
                  resizeThenMove == ["-m", "window", "\(wid)",
                                     "--resize", "abs:1653:1079",
                                     "--move", "abs:100:200"])
            let moveThenResize = WindowFrameCommand.applyFrame(windowID: wid, frame: frame, order: .moveThenResize)
            check("frameCommand A3: 放大序合发 = move 在 resize 前（写序不丢）",
                  moveThenResize == ["-m", "window", "\(wid)",
                                     "--move", "abs:100:200",
                                     "--resize", "abs:1653:1079"])
            check("frameCommand A4: 两种写序都是单条消息（每个动作只出现一次）",
                  resizeThenMove.count == 7 && moveThenResize.count == 7
                  && resizeThenMove.filter { $0 == "--move" }.count == 1
                  && resizeThenMove.filter { $0 == "--resize" }.count == 1)
        }

        // B. 坐标取整语义（yabai abs 只认数值，小数会解析失败 → 整段丢弃）
        do {
            let fractional = CGRect(x: 100.7, y: 199.2, width: 1653.9, height: 1078.4)
            let args = WindowFrameCommand.applyFrame(windowID: wid, frame: fractional, order: .moveThenResize)
            check("frameCommand B1: 小数坐标按 Int 截断（历史一致）",
                  args == ["-m", "window", "\(wid)",
                           "--move", "abs:100:199",
                           "--resize", "abs:1653:1078"])
            let negative = CGRect(x: -120.5, y: -33.9, width: 800, height: 600)
            check("frameCommand B2: 负坐标取整与历史 Int(...) 一致（向零截断）",
                  WindowFrameCommand.moveOnly(windowID: wid, frame: negative)
                  == ["-m", "window", "\(wid)", "--move", "abs:-120:-33"])
        }

        // C. 单发与合发逐字同源（补发计划只缺一维时不得漂移出另一份字面量）
        do {
            let moveOnly = WindowFrameCommand.moveOnly(windowID: wid, frame: frame)
            let resizeOnly = WindowFrameCommand.resizeOnly(windowID: wid, frame: frame)
            check("frameCommand C1: moveOnly = 合发中的 move 两元组",
                  moveOnly.count == 5 && Array(moveOnly.suffix(2)) == ["--move", "abs:100:200"])
            check("frameCommand C2: resizeOnly = 合发中的 resize 两元组",
                  resizeOnly.count == 5 && Array(resizeOnly.suffix(2)) == ["--resize", "abs:1653:1079"])
            for order in [FrameWriteOrder.resizeThenMove, .moveThenResize] {
                let combined = WindowFrameCommand.applyFrame(windowID: wid, frame: frame, order: order)
                check("frameCommand C3: 合发完整包含 moveOnly 与 resizeOnly 的尾段（\(order)）",
                      combined.contains(moveOnly[3]) && combined.contains(moveOnly[4])
                      && combined.contains(resizeOnly[3]) && combined.contains(resizeOnly[4]))
            }
        }

        // D. 零尺寸/零原点不产生空参数（yabai 会拒收缺值，命令必须恒为定长）
        do {
            // 元数：-m / window / <id> / 动作 / 值 / 动作 / 值 = 7
            check("frameCommand D1: 全零 frame 仍产出完整 7 元参数（无空值项）",
                  WindowFrameCommand.applyFrame(windowID: 0, frame: CGRect.zero, order: .moveThenResize)
                  == ["-m", "window", "0",
                      "--move", "abs:0:0",
                      "--resize", "abs:0:0"])
        }
    }
}
