import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerGridTargetE2ETests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runGridTargetE2E() {
    // MARK: 网格目标屏 + 无缝铺排真机 E2E（仅 VIBEFOCUS_GRID_TARGET_E2E=1 时运行）
    // 在「非主屏」（单屏机退主屏）上建 1×2 Terminal 网格，断言：两窗都落在目标屏、
    // 相邻格共边（缝 ≤2px）、贴可视区左右缘、快照 displayID == 目标屏。
    // 结束只关闭本块创建的窗口（按 Terminal window id 差集，不动用户窗口）。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_TARGET_E2E"] == "1" {
        print("\n=== 网格目标屏 + 无缝铺排真机 E2E ===")
        let savedTarget = TerminalGridPreferences.target
        let savedRows = TerminalGridPreferences.rows
        let savedCols = TerminalGridPreferences.cols
        let savedApp = TerminalGridPreferences.appPreference
        let savedGap = TerminalGridPreferences.gap
        let savedLaunch = TerminalGridPreferences.launchCommand

        let mainID = CGMainDisplayID()
        let targetScreen = NSScreen.screens.first { CoordinateKit.cgDisplayID(for: $0) != mainID } ?? NSScreen.screens.first
        if let targetScreen, let targetDisplayID = CoordinateKit.cgDisplayID(for: targetScreen) {
            let isNonMain = targetDisplayID != mainID
            print("    目标屏: \(targetScreen.localizedName) displayID=\(targetDisplayID) nonMain=\(isNonMain) screens=\(NSScreen.screens.count)")
            TerminalGridPreferences.target = GridTargetCode.display(displayID: targetDisplayID).code
            TerminalGridPreferences.rows = 1
            TerminalGridPreferences.cols = 2
            TerminalGridPreferences.appPreference = .terminal
            TerminalGridPreferences.gap = 0
            TerminalGridPreferences.launchCommand = ""

            func terminalWindowIDs() -> Set<UInt32> {
                guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to return id of every window"], timeout: 30),
                      out.exitCode == 0 else { return [] }
                return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            }
            let idsBefore = terminalWindowIDs()

            var createResult: TerminalGridController.OperationResult?
            var createdSnapshot: TerminalGridSnapshot?
            let targetSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                createResult = await TerminalGridController.shared.createGrid()
                createdSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
                targetSem.signal()
            }
            while targetSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.5)
            let created = terminalWindowIDs().subtracting(idsBefore)

            check("目标E2E: 创建 1×2 网格成功", createResult?.ok == true)
            print("    [诊断] \(createResult?.message ?? "nil")")
            check("目标E2E: 新建了 2 个 Terminal 窗口", created.count == 2)
            check("目标E2E: 快照 displayID == 目标屏", createdSnapshot?.displayID == targetDisplayID)

            let visible = CoordinateKit.quartzVisibleFrame(of: targetScreen)
            // 学习后的保留区（副屏菜单栏等隐形钳制，P40UG 顶部 25px）：expected
            // 按规划同源计算（visibleFrame 扣 insets），否则首跑必判 FAIL
            let learnedInsets = DisplayWorkArea.learnedInsets(displayID: targetDisplayID)
            let planFrame = DisplayWorkArea.plannedFrame(visibleFrame: visible, insets: learnedInsets)
            let expected = TerminalGridPlanner.cells(visibleFrame: planFrame, spec: .init(rows: 1, cols: 2, gap: 0))
            let actualFrames = cgWindowListAll()
                .filter { created.contains($0.windowID) }
                .compactMap { $0.bounds }
                .sorted { $0.minX < $1.minX }
            print("    [诊断] visible=\(QuartzRect(visible).description) insets(top=\(learnedInsets.top)) plan=\(QuartzRect(planFrame).description)")
            print("    [诊断] expected=\(expected.map { QuartzRect($0).description })")
            print("    [诊断] actual=\(actualFrames.map { QuartzRect($0).description })")
            check("目标E2E: 两窗都落在目标屏规划区内",
                  actualFrames.count == 2 && actualFrames.allSatisfy { planFrame.insetBy(dx: -4, dy: -4).contains($0) })
            if actualFrames.count == 2 {
                let seam = abs(actualFrames[1].minX - actualFrames[0].maxX)
                print("    [诊断] seam=\(seam)px")
                check("目标E2E: 相邻格共边（缝 ≤ 2px，无空隙）", seam <= 2)
                check("目标E2E: 左格贴规划区左缘", abs(actualFrames[0].minX - planFrame.minX) <= 2)
                check("目标E2E: 右格贴规划区右缘", abs(actualFrames[1].maxX - planFrame.maxX) <= 2)
                check("目标E2E: 两格与规划 frame 收敛（≤4px）",
                      zip(expected, actualFrames).allSatisfy { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: 4) })
                check("目标E2E: 顶行不被隐形保留区推离（学习后 top 缝 ≤2px）",
                      abs(actualFrames[0].minY - planFrame.minY) <= 2)
            }
            check("目标E2E: 多屏机上定向到了非主屏", NSScreen.screens.count < 2 || isNonMain)

            // 二次创建：保留区已学习缓存，规划即落点（不再需要保留区重排）
            var secondSnapshot: TerminalGridSnapshot?
            var secondCreate: TerminalGridController.OperationResult?
            let secondSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                secondCreate = await TerminalGridController.shared.createGrid()
                secondSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
                secondSem.signal()
            }
            while secondSem.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            Thread.sleep(forTimeInterval: 0.5)
            let createdSecond = terminalWindowIDs().subtracting(idsBefore).subtracting(created)
            check("目标E2E: 二次创建成功", secondCreate?.ok == true && createdSecond.count == 2)
            if let snap2 = secondSnapshot, createdSecond.count == 2 {
                let actualSecond = cgWindowListAll()
                    .filter { createdSecond.contains($0.windowID) }
                    .compactMap { $0.bounds }
                    .sorted { $0.minX < $1.minX }
                let expectedSecond = snap2.cells.map { $0.frame }.sorted { $0.minX < $1.minX }
                check("目标E2E: 二次创建快照 frame 即实际落点（规划直中，无重排）",
                      actualSecond.count == 2
                      && zip(expectedSecond, actualSecond).allSatisfy { CoordinateKit.isFrameConverged(actual: $1, target: $0, tolerance: 3) })
            }
            for id in created.union(createdSecond) {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to close window id \(id)"], timeout: 30)
            }
            if let createdSnapshot {
                TerminalGridController.shared.removeSnapshot(id: createdSnapshot.id)
            }
            if let secondSnapshot {
                TerminalGridController.shared.removeSnapshot(id: secondSnapshot.id)
            }
            Thread.sleep(forTimeInterval: 0.8)
            check("目标E2E: 本块创建的窗口已全部关闭", terminalWindowIDs().intersection(created.union(createdSecond)).isEmpty)
        } else {
            check("目标E2E: 找到目标屏", false)
        }

        TerminalGridPreferences.target = savedTarget
        TerminalGridPreferences.rows = savedRows
        TerminalGridPreferences.cols = savedCols
        TerminalGridPreferences.appPreference = savedApp
        TerminalGridPreferences.gap = savedGap
        TerminalGridPreferences.launchCommand = savedLaunch
    }
    }
}
