import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSizeE2ETests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runSizeE2E() {
    // MARK: 跨屏移动尺寸保真真机 E2E（仅 VIBEFOCUS_SIZE_E2E=1 时运行）
    // 用户主诉（2026-09-06）：移动窗口后尺寸错误。用已知尺寸的 iTerm2 窗口走
    // WindowManager.moveWindowToFrameViaYabai 跨屏移动，覆盖两条写序：
    //   Case A 放大跨屏（主→副，800x600→1500x900，旧 origin+目标尺寸在源屏可视
    //          区内 → 命中 af19b2b 新增的 resizeThenMove 先行终态路径）
    //   Case B 缩小跨屏（副→主，1500x900→800x600 → 缩小分支 resizeThenMove）
    // 断言：最终 frame 尺寸/位置与目标一致（±40 量化容差）。结束清理窗口。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_SIZE_E2E"] == "1" {
        print("\n=== 跨屏移动尺寸保真真机 E2E ===")
        SpaceController.shared.refreshAvailability(force: true)
        check("SizeE2E: yabai 可用", SpaceController.shared.isEnabled)

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
        func yabaiWindowFrame(_ id: UInt32) -> CGRect? {
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
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func yabaiPlace(_ id: UInt32, frame: CGRect) {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "size-e2e.place", operationID: "size-e2e")
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "size-e2e.place", operationID: "size-e2e")
        }
        func itermWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"com.googlecode.iterm2\" to return id of every window"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }

        guard let mainScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) == CGMainDisplayID() }),
              let secondaryScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) != CGMainDisplayID() }) else {
            check("SizeE2E: 找到主副双屏", false)
            exit(1)
        }

        let idsBefore = yabaiWindowIDs()
        // 创建 iTerm2 窗口（落点由 app 决定，随后 yabai 摆到精确初始帧）
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        guard created.count == 1, let wid = created.first else {
            check("SizeE2E: 创建 iTerm2 测试窗口", false)
            exit(1)
        }
        print("    [诊断] 测试窗口 id=\(wid)")

        func runCase(name: String, initial: CGRect, target: CGRect, sourceVisible: CGRect) {
            let placeSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                yabaiPlace(wid, frame: initial)
                placeSem.signal()
            }
            while placeSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.6)
            guard let startFrame = yabaiWindowFrame(wid) else {
                check("SizeE2E \(name): 读取初始帧", false)
                return
            }
            print("    [诊断] \(name) 初始=\(startFrame) 目标=\(target)")
            let moveSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                _ = WindowManager.shared.moveWindowToFrameViaYabai(
                    windowID: wid, frame: target, op: "size-e2e", stage: "size_e2e.\(name)",
                    sourceVisibleFrame: sourceVisible)
                moveSem.signal()
            }
            while moveSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            // 收敛观察窗：2s 内帧稳定即采样
            var final: CGRect?
            var last: CGRect?
            var stable = 0
            for _ in 0..<20 {
                let f = yabaiWindowFrame(wid)
                if let f, let last, f == last { stable += 1; if stable >= 3 { final = f; break } }
                else { stable = 0 }
                last = f
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard let final else {
                check("SizeE2E \(name): 读到稳定终帧", false)
                return
            }
            let sizeDW = abs(final.width - target.width)
            let sizeDH = abs(final.height - target.height)
            let posDX = abs(final.origin.x - target.origin.x)
            let posDY = abs(final.origin.y - target.origin.y)
            print("    [诊断] \(name) 终帧=\(final) Δsize=(\(sizeDW),\(sizeDH)) Δpos=(\(posDX),\(posDY))")
            check("SizeE2E \(name): 尺寸保真（Δ≤40，实测 Δ=(\(Int(sizeDW)),\(Int(sizeDH)))）",
                  sizeDW <= 40 && sizeDH <= 40)
            check("SizeE2E \(name): 位置保真（Δ≤80）", posDX <= 80 && posDY <= 80)
        }

        // Case A：主→副 放大（旧 origin(100,100)+目标尺寸在主屏可视区内 → 命中
        // af19b2b 放大先行 resizeThenMove 新路径）
        runCase(name: "main_to_secondary_enlarge",
                initial: CGRect(x: 100, y: 100, width: 800, height: 600),
                target: CGRect(x: 200, y: 150, width: 1500, height: 900),
                sourceVisible: mainScreen.visibleFrame)
        // Case B：副→主 缩小（缩小分支：目标 fits 源屏可视区 → resizeThenMove）
        runCase(name: "secondary_to_main_shrink",
                initial: CGRect(x: 200, y: 150, width: 1500, height: 900),
                target: CGRect(x: 100, y: 100, width: 800, height: 600),
                sourceVisible: secondaryScreen.visibleFrame)

        // Case C：完整 toggle 往返（用户真实操作路径：聚焦副屏窗口 → 热键 toggle
        // 到主屏 → 再 toggle 还原回副屏原帧）。两次 toggle 各测一次尺寸。
        // 测试初始帧从当前副屏可视区动态推导（Quartz 坐标）——历史版本硬编码
        // 旧屏布局（P40UG 时代 -814,-1415），显示器换布局后落所有屏外，
        // yabai 钳位导致还原位置断言必挂（2026-09-08 三屏布局实测）。
        let secondaryForCaseC = NSScreen.screens.first { CoordinateKit.cgDisplayID(for: $0) != CGMainDisplayID() }
        let secVisibleCocoa = secondaryForCaseC?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secPlaceFrame = CGRect(
            x: secVisibleCocoa.minX + 188,
            y: CoordinateKit.quartzY(fromCocoaY: secVisibleCocoa.maxY) + 24,
            width: 1146, height: 707)
        // 副屏归属判定（布局自适应）：窗口中心（Quartz→Cocoa）落在当前副屏 frame 内。
        // 旧断言 origin.x<0 假设副屏在主屏左侧，换布局即错。
        func isOnSecondaryScreen(_ quartzFrame: CGRect) -> Bool {
            guard let secondary = secondaryForCaseC else { return quartzFrame.origin.x < 0 }
            let centerCocoa = CGPoint(
                x: quartzFrame.midX,
                y: CoordinateKit.cocoaY(fromQuartzY: quartzFrame.midY))
            return secondary.frame.contains(centerCocoa)
        }
        let c1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(wid, frame: secPlaceFrame)
            c1Sem.signal()
        }
        while c1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        // 聚焦测试窗口（toggle 操作聚焦窗口）
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let toggle1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-1", triggerSource: "size_e2e")
            toggle1Sem.signal()
        }
        while toggle1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let afterMove = yabaiWindowFrame(wid) {
            let onMain = afterMove.origin.x >= 0
            let sizeOK = abs(afterMove.width - 1653) <= 40 && abs(afterMove.height - 1079) <= 40
            print("    [诊断] toggle1 移主屏 终帧=\(afterMove) onMain=\(onMain)")
            check("SizeE2E toggleCase: toggle 到主屏尺寸 = 主屏可视区 1653x1079（±40）", onMain && sizeOK)
        } else {
            check("SizeE2E toggleCase: 读取 toggle 后帧", false)
        }
        let toggle2Sem = DispatchSemaphore(value: 0)
        // 重聚焦后再 toggle：期间系统设置等窗口可能抢焦点（ax 引导流会开系统设置）
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.3)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-2", triggerSource: "size_e2e")
            toggle2Sem.signal()
        }
        while toggle2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let afterRestore = yabaiWindowFrame(wid) {
            print("    [诊断] toggle2 还原 终帧=\(afterRestore)（期望 \(secPlaceFrame)）")
            let backOnSecondary = isOnSecondaryScreen(afterRestore)
            let sizeOK = abs(afterRestore.width - 1146) <= 40 && abs(afterRestore.height - 707) <= 40
            check("SizeE2E toggleCase: 还原回副屏尺寸保真（±40）", backOnSecondary && sizeOK)
            check("SizeE2E toggleCase: 还原回副屏原位置（±80）",
                  abs(afterRestore.origin.x - secPlaceFrame.minX) <= 80 && abs(afterRestore.origin.y - secPlaceFrame.minY) <= 80)
        } else {
            check("SizeE2E toggleCase: 读取还原后帧", false)
        }

        // Case D：解堵路由尺寸保持。主屏上一个无 toggle 记录的窗口（新窗即满足）
        // toggle → 走 stuck 路由移副屏。修复前：目标=副屏整屏可视区（3440x1440），
        // 窗口被撑满整副屏（用户主诉「尺寸搞错」）；修复后：保持原尺寸 900x600，
        // 位置夹进副屏可视区。
        let idsBeforeD = yabaiWindowIDs()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let createdD = yabaiWindowIDs().subtracting(idsBeforeD)
        guard createdD.count == 1, let widD = createdD.first else {
            check("SizeE2E stuckCase: 创建第二测试窗口", false)
            exit(1)
        }
        let d1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(widD, frame: CGRect(x: 600, y: 300, width: 900, height: 600))
            d1Sem.signal()
        }
        while d1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(widD)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let d2Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.toggle(operationID: "size-e2e-toggle-stuck", triggerSource: "size_e2e")
            d2Sem.signal()
        }
        while d2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let stuckFrame = yabaiWindowFrame(widD) {
            print("    [诊断] stuckCase 终帧=\(stuckFrame)（期望尺寸保持 900x600、移到副屏）")
            let onSecondary = isOnSecondaryScreen(stuckFrame)
            let sizeKept = abs(stuckFrame.width - 900) <= 40 && abs(stuckFrame.height - 600) <= 40
            check("SizeE2E stuckCase: 解堵移副屏尺寸保持 900x600（±40，修复前=撑满 3440x1440）",
                  onSecondary && sizeKept)
        } else {
            check("SizeE2E stuckCase: 读取解堵后帧", false)
        }

        // Case E：restore 屏外 origFrame 保守退让（P1 修复）。合成一条 origFrame 在
        // 所有屏之外的 record（显示器配置变化后的真实场景），restore 应把原始帧夹进
        // 源屏可视区完成还原（修复前：清 record 放弃，窗口卡在原处）。期望终帧 =
        // clampFrame((5000,500,800,600), 副屏可视区) = (1826,-600,800,600)。
        let itermPID = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to return unix id"], timeout: 30)
            .flatMap { Int32($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let e1Sem = DispatchSemaphore(value: 0)
        var clampExpected = CGRect.zero
        var restoreOutcome: String = "n/a"
        Task { @MainActor in
            let spaces = SpaceController.shared.querySpaces()
            let secDisplay = spaces?.first(where: { $0.display != 1 })?.display ?? 2
            let secVisibleSpaceIdx = spaces?.first(where: { $0.display == secDisplay && $0.isVisible == true })?.index ?? 3
            ToggleEngine.shared.save(
                windowID: wid,
                pid: itermPID ?? 0,
                bundleIdentifier: "com.googlecode.iterm2",
                appName: "iTerm2",
                origFrame: CGRect(x: 5000, y: 500, width: 800, height: 600),
                sourceSpace: .yabaiIndex(secVisibleSpaceIdx),
                sourceDisplay: .yabaiIndex(Int(secDisplay)),
                sourceYabaiDisp: .yabaiIndex(Int(secDisplay)),
                sourceDispSpace: secVisibleSpaceIdx,
                targetFrame: CGRect(x: 75, y: 38, width: 1653, height: 1079),
                targetDisplay: 1,
                sessionID: nil,
                reason: .manualHotkey
            )
            if let secScreen = CoordinateKit.nsScreen(forYabaiDisplayIndex: Int(secDisplay)) {
                clampExpected = CoordinateKit.clampFrame(
                    CGRect(x: 5000, y: 500, width: 800, height: 600),
                    into: CoordinateKit.quartzVisibleFrame(of: secScreen))
            }
            let outcome = ToggleEngine.shared.restore(windowID: wid, triggerSource: "size_e2e", traceID: "size-e2e-clamp")
            restoreOutcome = outcome.outcomeLabel
            e1Sem.signal()
        }
        while e1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.0)
        print("    [诊断] clampCase 结果=\(restoreOutcome) 期望终帧=\(clampExpected)")
        if let clampedFinal = yabaiWindowFrame(wid), clampExpected != .zero {
            let sizeOK = abs(clampedFinal.width - 800) <= 40 && abs(clampedFinal.height - 600) <= 40
            let onScreen = CoordinateKit.isOnMainScreen(clampedFinal.origin)
                || clampedFinal.origin.y < 0
            check("SizeE2E clampCase: restore 上报 restored", restoreOutcome.hasPrefix("restored"))
            check("SizeE2E clampCase: 屏外 origFrame 被夹进源屏且尺寸保持（±40）",
                  sizeOK && onScreen)
            check("SizeE2E clampCase: record 已消费", ToggleEngine.shared.load(windowID: wid) == nil)
        } else {
            check("SizeE2E clampCase: 读取夹取还原后帧", false)
        }

        // Case F：move_to_main 路由直呼（P2 补用例）。副屏窗口直接调公开路由
        // moveToMainScreen（与热键同路径，区别于 Case C 的 toggle 决策入口），
        // 断言：窗口落主屏可视区（1653x1079 ±40）+ toggle record 落库（还原可用）。
        let f1Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            yabaiPlace(wid, frame: secPlaceFrame)
            f1Sem.signal()
        }
        while f1Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.6)
        _ = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "window", "\(wid)", "--focus"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        let f2Sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            WindowManager.shared.moveToMainScreen(operationID: "size-e2e-move-to-main", triggerSource: "size_e2e")
            f2Sem.signal()
        }
        while f2Sem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 1.2)
        if let movedFrame = yabaiWindowFrame(wid) {
            print("    [诊断] moveToMainCase 终帧=\(movedFrame)（期望主屏可视区 75,38 1653x1079 ±40）")
            let onMain = movedFrame.origin.x >= 0
            let sizeOK = abs(movedFrame.width - 1653) <= 40 && abs(movedFrame.height - 1079) <= 40
            check("SizeE2E moveToMainCase: 路由直呼落主屏可视区（±40）", onMain && sizeOK)
            let recordSaved = ToggleEngine.shared.load(windowID: wid) != nil
            check("SizeE2E moveToMainCase: toggle record 已落库（还原可用）", recordSaved)
        } else {
            check("SizeE2E moveToMainCase: 读取移主屏后帧", false)
        }

        // 清理：向两个测试窗口的 session 写 exit 结束 shell，窗口随会话关闭（best-effort）
        let exitScript = """
        tell application id "com.googlecode.iterm2"
            repeat with targetID in {\(wid), \(widD)}
                try
                    tell window id (targetID as integer) to tell current session to write text "exit"
                end try
            end repeat
        end tell
        """
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", exitScript], timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let leftover = yabaiWindowIDs().intersection(created)
        if leftover.isEmpty {
            check("SizeE2E: 测试窗口已关闭", true)
        } else {
            print("    [诊断] 关闭滞后（iTerm2 后台处理）：\(leftover.sorted())")
        }
    }
    }
}
