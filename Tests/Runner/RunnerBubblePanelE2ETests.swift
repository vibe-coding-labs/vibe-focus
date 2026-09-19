import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubblePanelE2ETests.swift — B255：气泡真面板域真机 E2E。
// 单测通道结构性不可达（真面板 makeKeyAndOrderFront 抢焦点、真渲染、真 DraftStore），
// 本通道在真机上自建 iTerm2 scratch 窗作锚点，走生产 summonForMovedWindow→showPanel
// 编排，断言面板打开/在屏/锚定后生产 dismiss 收起，再 scoped 关窗盘点归零。
//
// ⚠️ 安全红线（沿用 AXWrite E2E 配方 + B176 教训）：
// - 目标窗只许是自建 scratch 窗（绝不锚用户窗）；
// - 不做任何文本注入/回车提交（合成草稿曾被 auto-show 消费误注入用户 zsh）；
// - 清场走 yabai scoped 通道（iTerm2 AppleScript id 与 yabai id 不同源）；
// - 前置：iTerm2、yabai、本机证书重签 Runner、用户偏好气泡开关为开（环境不符诚实跳过）。
// 跑法：VIBEFOCUS_BUBBLE_PANEL_E2E=1 .build/debug/VibeFocusTestRunner

extension RunnerHarness {
    func runBubblePanelE2E() {
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_BUBBLE_PANEL_E2E"] == "1" else { return }
        print("\n=== 气泡真面板域真机 E2E ===")
        guard InputBubblePreferences.isEnabled else {
            check("BubblePanelE2E: 用户偏好气泡开关关闭，环境不符诚实跳过", true)
            return
        }

        func yabaiWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "query", "--windows"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            let regex = try? NSRegularExpression(pattern: "\"id\":\\s*(\\d+)")
            let range = NSRange(out.stdout.startIndex..., in: out.stdout)
            var ids: Set<UInt32> = []
            for result in (regex ?? NSRegularExpression()).matches(in: out.stdout, range: range) {
                guard result.numberOfRanges > 1, let r = Range(result.range(at: 1), in: out.stdout),
                      let n = UInt32(out.stdout[r]) else { continue }
                ids.insert(n)
            }
            return ids
        }
        func yabaiWindowFrameAndPID(_ id: UInt32) -> (frame: CGRect, pid: Int32)? {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai",
                arguments: ["-m", "query", "--windows", "--window", "\(id)"], timeout: 30),
                out.exitCode == 0,
                let data = out.stdout.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let f = obj["frame"] as? [String: Any],
                let x = (f["x"] as? NSNumber)?.doubleValue,
                let y = (f["y"] as? NSNumber)?.doubleValue,
                let w = (f["w"] as? NSNumber)?.doubleValue,
                let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
            let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0
            return (CGRect(x: x, y: y, width: w, height: h), pid)
        }
        func yabaiPlace(_ id: UInt32, frame: CGRect) {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "bubblepanel-e2e.place", operationID: "bubblepanel-e2e")
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "bubblepanel-e2e.place", operationID: "bubblepanel-e2e")
        }
        /// scoped 关窗：只碰自建 wid（yabai close 幂等重试，失败先 focus 再试）
        func scopedCloseAndVerify(_ wid: UInt32) -> Bool {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(wid)", "--close"],
                operation: "bubblepanel-e2e.cleanup", operationID: "bubblepanel-e2e")
            var gone = !yabaiWindowIDs().contains(wid)
            for _ in 0..<6 where !gone {
                Thread.sleep(forTimeInterval: 1.0)
                gone = !yabaiWindowIDs().contains(wid)
                if !gone {
                    _ = SpaceController.shared.runYabai(
                        arguments: ["-m", "window", "\(wid)", "--focus"],
                        operation: "bubblepanel-e2e.cleanup", operationID: "bubblepanel-e2e")
                    _ = SpaceController.shared.runYabai(
                        arguments: ["-m", "window", "\(wid)", "--close"],
                        operation: "bubblepanel-e2e.cleanup", operationID: "bubblepanel-e2e")
                }
            }
            return gone
        }

        let directProbe = ShellRunner.run(executable: "/opt/homebrew/bin/yabai",
            arguments: ["-m", "query", "--windows"], timeout: 30)
        check("BubblePanelE2E: yabai 可用（直探 exit 0）",
              directProbe?.exitCode == 0 && directProbe?.stdout.isEmpty == false)

        guard let mainScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) == CGMainDisplayID() }) else {
            check("BubblePanelE2E: 主屏存在", false)
            return
        }
        let mainVisible = CoordinateKit.quartzVisibleFrame(of: mainScreen)
        let anchorFrame = CGRect(x: mainVisible.minX + 60, y: mainVisible.minY + 60, width: 900, height: 600)

        // 建窗 + 摆位 + pid（全程 yabai 通道，id 空间一致）
        let idsBefore = yabaiWindowIDs()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 1.0)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        guard created.count == 1, let wid = created.first else {
            check("BubblePanelE2E: 创建 iTerm2 锚点窗口", false)
            return
        }
        check("BubblePanelE2E: 创建 iTerm2 锚点窗口", true)

        // 清场闸门：任何出口先收面板再关窗
        defer {
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                if InputBubbleController.shared.phase != .idle {
                    InputBubbleController.shared.dismiss(reactivateTarget: false)
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 3)
            _ = scopedCloseAndVerify(wid)
        }

        yabaiPlace(wid, frame: anchorFrame)
        Thread.sleep(forTimeInterval: 0.6)
        guard let placed = yabaiWindowFrameAndPID(wid), placed.pid > 0 else {
            check("BubblePanelE2E: 锚点摆位与 pid 读取", false)
            return
        }
        check("BubblePanelE2E: 锚点摆位与 pid 读取（pid=\(placed.pid)）", true)

        // 生产通道定向 summon（目标=自建 scratch 窗，绝不锚用户窗）
        // 守卫逐项预探（B255 诊断：summonForMovedWindow 前置多，失败需定位到具体守卫）
        let summonSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let ctl = InputBubbleController.shared
            print("    [诊断] phase=\(ctl.phase) prefsEnabled=\(InputBubblePreferences.isEnabled)")
            let app = NSRunningApplication(processIdentifier: placed.pid)
            print("    [诊断] NSRunningApplication=\(app != nil) isTerminal=\(app.map { TerminalRegistry.isTerminalOrIDEApp(appName: $0.localizedName, bundleIdentifier: $0.bundleIdentifier) } ?? false)")
            let cg = cgWindowBounds(for: wid)
            print("    [诊断] cgWindowBounds=\(cg.map { NSStringFromRect($0) } ?? "nil")")
            ctl.summonForMovedWindow(
                windowID: wid, pid: placed.pid, appName: "iTerm2")
            print("    [诊断] summon 后 phase=\(ctl.phase) panelVisible=\(ctl.panel?.isVisible ?? false)")
            summonSem.signal()
        }
        while summonSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // 面板打开在 summon 的 MainActor Task 内同步捕获（⚠️主线程 sleep 阻塞期间
        // MainActor Task 无法执行——阻塞式轮询只会读到陈旧快照，B255 实测教训）
        final class PhaseBox: @unchecked Sendable {
            var phase: InputBubbleController.Phase = .idle
            var visible = false
            var frame: CGRect = .zero
        }
        var openVisible = false
        var openFrame = CGRect.zero
        for _ in 0..<10 {
            let openSem = DispatchSemaphore(value: 0)
            let box = PhaseBox()
            Task { @MainActor in
                let ctl = InputBubbleController.shared
                box.phase = ctl.phase
                if ctl.phase == .open, let p = ctl.panel, p.isVisible {
                    box.visible = true
                    box.frame = p.frame
                }
                openSem.signal()
            }
            while openSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if box.visible {
                openVisible = true
                openFrame = box.frame
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let opened = openVisible
        if opened {
            let pf = openFrame
            print("    [诊断] 面板 frame=\(pf)")
            check("BubblePanelE2E: 面板已打开且在屏可见", true)
            check("BubblePanelE2E: 面板锚定主屏（与可视区相交）",
                  pf.intersects(mainVisible) && !pf.isEmpty)
        } else {
            check("BubblePanelE2E: 面板已打开且在屏可见", false)
        }

        // 生产 dismiss 收起（不回焦 scratch 窗——避免抢用户焦点链）
        let dismissSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            InputBubbleController.shared.dismiss(reactivateTarget: false)
            dismissSem.signal()
        }
        while dismissSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        var closed = false
        for _ in 0..<8 {
            let sem = DispatchSemaphore(value: 0)
            let box = PhaseBox()
            Task { @MainActor in
                let ctl = InputBubbleController.shared
                box.phase = ctl.phase
                box.visible = ctl.panel?.isVisible ?? false
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            closed = (box.phase == .idle && !box.visible)
            if closed { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        check("BubblePanelE2E: dismiss 后面板收起归 idle", closed)
    }
}
