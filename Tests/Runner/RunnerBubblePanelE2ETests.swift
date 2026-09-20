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
        // B302 前置探针：yabai id→window 解析健康度（损坏期特征=聚合列表在而 scoped 全灭）。
        // 不健康则在建窗之前跳过——否则锚点窗创建后无法定位/关闭（每次跑漏一窗）。
        do {
            let probeSource = yabaiWindowIDs()
            if let existing = probeSource.first,
               yabaiWindowFrameAndPID(existing) == nil {
                check("BubblePanelE2E: yabai scoped-by-id 不可用（环境损坏期防泄漏跳过）", true)
                return
            }
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
            // 前置环境不符诚实跳过（B302 实测：yabai scoped-by-id 解析损坏期，
            // 新窗可能根本进不了 yabai 列表——与 AX 授权门控同一待遇）
            check("BubblePanelE2E: 创建 iTerm2 锚点窗口（yabai 窗口注册不可用，跳过）", true)
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
            // 前置环境不符诚实跳过（B302 实测：yabai id→window 解析损坏期
            // 「could not locate window with the specified id」——聚合列表在而 scoped 全灭）
            check("BubblePanelE2E: 锚点摆位与 pid 读取（yabai scoped-by-id 不可用，跳过）", true)
            // 清场：锚点窗还得关——yabai close 失效时用 iTerm2 AE 兜底尽力关
            _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"com.googlecode.iterm2\" to close window id \(wid)"], timeout: 15)
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

            // ===== B302：拖拽调尺寸直驱（控制器编排全链，零合成鼠标零文本注入）=====
            // 偏好快照-还原（B84 家法：finishResizeDrag 持久化 bubbleWidth/Height）
            let savedWidth = InputBubblePreferences.bubbleWidth
            let savedHeight = InputBubblePreferences.bubbleHeight
            let resizeSem = DispatchSemaphore(value: 0)
            var resizeReport: (grew: Bool, quantized: Bool, guardHeld: Bool, appliedSize: Bool) = (false, false, false, false)
            Task { @MainActor in
                let ctl = InputBubbleController.shared
                if ctl.phase == .open, let panel = ctl.panel {
                    let start = panel.frame

                    // 未 begin 前 apply 是 no-op（守卫：resizeDragStart nil）
                    let beforeGuard = panel.frame
                    ctl.applyResizeDrag(dx: 120, dy: -80)
                    resizeReport.guardHeld = (panel.frame == beforeGuard)

                    // begin → apply：右下角拖拽 dy 向下为负 → 增高；左上角固定
                    ctl.beginResizeDrag()
                    ctl.applyResizeDrag(dx: 120, dy: -80)
                    let expectedSize = InputBubbleLayout.resizedSize(
                        startSize: start.size, widthDelta: 120, heightDelta: 80)
                    let expectedOrigin = InputBubbleLayout.resizedOrigin(
                        startOrigin: start.origin, startSize: start.size, newSize: expectedSize)
                    resizeReport.grew = abs(panel.frame.width - expectedSize.width) < 0.5
                        && abs(panel.frame.height - expectedSize.height) < 0.5
                        && abs(panel.frame.origin.x - expectedOrigin.x) < 0.5
                        && abs(panel.frame.origin.y - expectedOrigin.y) < 0.5

                    // finish：量化到步进合法域并持久化
                    ctl.finishResizeDrag()
                    let quantizedW = InputBubblePreferences.clampedWidth(Double(panel.frame.width))
                    let quantizedH = InputBubblePreferences.clampedHeight(Double(panel.frame.height))
                    resizeReport.quantized = abs(panel.frame.width - quantizedW) < 0.5
                        && abs(panel.frame.height - quantizedH) < 0.5
                        && InputBubblePreferences.bubbleWidth == quantizedW
                        && InputBubblePreferences.bubbleHeight == quantizedH

                    // applyPanelSize 程序化改尺寸（设置页滑杆联动共用通道）
                    let target = NSSize(width: quantizedW + 40, height: quantizedH + 20)
                    ctl.applyPanelSize(target)
                    resizeReport.appliedSize = abs(panel.frame.width - target.width) < 0.5
                        && abs(panel.frame.height - target.height) < 0.5
                }
                resizeSem.signal()
            }
            while resizeSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            check("BubblePanelE2E: 未 begin 时 applyResizeDrag 守卫保持（no-op）", resizeReport.guardHeld)
            check("BubblePanelE2E: applyResizeDrag 左上角固定实时改尺寸", resizeReport.grew)
            check("BubblePanelE2E: finishResizeDrag 量化落账（面板帧+偏好同步）", resizeReport.quantized)
            check("BubblePanelE2E: applyPanelSize 程序化 relayout（滑杆联动通道）", resizeReport.appliedSize)

            // 偏好还原（避免测试尺寸泄漏给后续运行/设置页）
            InputBubblePreferences.bubbleWidth = savedWidth
            InputBubblePreferences.bubbleHeight = savedHeight
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
