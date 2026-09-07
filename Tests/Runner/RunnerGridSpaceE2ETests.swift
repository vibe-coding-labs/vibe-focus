import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerGridSpaceE2ETests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runGridSpaceE2E() {
    // MARK: 网格 Space 定向真机 E2E（仅 VIBEFOCUS_GRID_SPACE_E2E=1 时运行）
    // 选「非主屏上非当前可见、且有窗口」的 Space 创建 1×2 网格，断言：每个新窗口
    // 的 yabai space == 目标 space（跨屏往返投递生效）。背景：AppleScript 建窗落点
    // 由终端 app 自己的活跃 space 决定，与系统视角脱节（2026-09-06 用户实证：视角
    // 在 5，iTerm2 把窗口全部建进不可见的 4）。结束恢复可见 space + 清理窗口/快照。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_SPACE_E2E"] == "1" {
        print("\n=== 网格 Space 定向真机 E2E ===")
        let savedTarget = TerminalGridPreferences.target
        let savedRows = TerminalGridPreferences.rows
        let savedCols = TerminalGridPreferences.cols
        let savedApp = TerminalGridPreferences.appPreference
        let savedGap = TerminalGridPreferences.gap
        let savedLaunch = TerminalGridPreferences.launchCommand

        // iTerm2：AppleScript id ≠ CGWindowNumber，用 yabai 窗口表差集追踪新窗。
        // yabai --windows 输出 JSON，按 "id":<n> 模式提取窗口 id（逗号 split 会把
        // frame 坐标等数字一并误收，差集全是噪声）
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

        var setupOK = false
        var targetSpaceIndex: Int?
        var visibleIndex: Int?
        let setupSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { setupSem.signal() }
            let mainID = CGMainDisplayID()
            guard let targetScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) != mainID }),
                  let targetDisplayID = CoordinateKit.cgDisplayID(for: targetScreen),
                  // 几何精确解析（Batch 34）：猜序版在同尺寸双副屏上反序，会去错误
                  // 显示器的 space 列表里挑目标，投递与断言错位（2026-09-08 实测）。
                  let displayIndex = SpaceController.shared.exactYabaiDisplayIndex(for: targetScreen) else {
                check("SpaceE2E: 找到非主屏", false)
                return
            }
            // Runner 进程内 SpaceController 从未刷新过 availability（默认 unknown）
            SpaceController.shared.refreshAvailability(force: true)
            guard SpaceController.shared.isEnabled else {
                check("SpaceE2E: yabai 可用", false)
                return
            }
            let spaces = SpaceController.shared.querySpaces() ?? []
            let displaySpaces = spaces.filter { $0.display == displayIndex }
            let visible = displaySpaces.first(where: { $0.isVisible == true })
            // 目标 = 非当前可见、且视角可达（refocus 后 visible 真的变成它）的 space。
            // 可达性必须实测：聚焦 iTerm2 窗口会被激活拖拽拉回 app 活跃 space（真机实证）。
            // 终端 app 的窗口聚焦会触发激活拖拽（视角被拉到 app 活跃 space），
            // 优先挑带非终端窗口的 space，保证视角切换通道稳定
            @MainActor func hasNonTerminalWindow(_ idx: Int) -> Bool {
                SpaceController.shared.queryWindowsOnSpace(idx, operationID: "space-e2e-probe")?
                    .contains { $0.app != "iTerm2" && $0.app != "Terminal" } == true
            }
            var candidate: Int?
            for pass in [0, 1] {
                for s in displaySpaces where s.isVisible != true {
                    guard let idx = s.index else { continue }
                    if pass == 0 && !hasNonTerminalWindow(idx) { continue }
                    _ = SpaceController.shared.refocusWindowOnSpace(idx, operationID: "space-e2e-probe")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if SpaceController.shared.visibleSpaceIndex(forDisplayIndex: displayIndex, spaces: nil, ignoreCache: true)?.yabaiIndex == idx {
                        candidate = idx
                        break
                    }
                }
                if candidate != nil { break }
            }
            guard let candidate, let visible, let visibleIdx = visible.index else {
                check("SpaceE2E: 找到视角可达的非可见目标 space（需要多 Space 副屏环境）", false)
                return
            }
            targetSpaceIndex = candidate
            visibleIndex = visibleIdx
            print("    [诊断] targetSpace=\(candidate) visibleSpace=\(visibleIdx)")
            TerminalGridPreferences.target = GridTargetCode.displaySpace(displayID: targetDisplayID, spaceIndex: candidate).code
            setupOK = true
        }
        while setupSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard setupOK, let targetSpaceIndex else {
            check("SpaceE2E: 环境就绪", false)
            TerminalGridPreferences.target = savedTarget
            exit(1)
        }
        TerminalGridPreferences.rows = 1
        TerminalGridPreferences.cols = 2
        TerminalGridPreferences.appPreference = .iterm2
        TerminalGridPreferences.gap = 0
        TerminalGridPreferences.launchCommand = ""

        let idsBefore = yabaiWindowIDs()
        func itermWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"com.googlecode.iterm2\" to return id of every window"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            return Set(out.stdout.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
        let itermBefore = itermWindowIDs()
        var createResult: TerminalGridController.OperationResult?
        var createdSnapshot: TerminalGridSnapshot?
        let createSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            createResult = await TerminalGridController.shared.createGrid()
            createdSnapshot = TerminalGridController.shared.snapshotsForRefresh().last
            createSem.signal()
        }
        while createSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.5)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        print("    [诊断] created diffs=\(created.sorted())")

        check("SpaceE2E: 创建 1×2 网格成功", createResult?.ok == true)
        print("    [诊断] \(createResult?.message ?? "nil")")
        check("SpaceE2E: 新建了 2 个窗口", created.count == 2)

        // 逐窗读 yabai space（MainActor Task 内采集，顶层断言）
        var windowSpaces: [UInt32: Int?] = [:]
        let probeSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            for id in created {
                windowSpaces[id] = SpaceController.shared.queryWindow(windowID: id, ignoreCache: true)?.space
            }
            probeSem.signal()
        }
        while probeSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        var spacesHit = 0
        for id in created {
            if windowSpaces[id] ?? nil == targetSpaceIndex { spacesHit += 1 }
            else { print("    [诊断] window \(id) space=\(windowSpaces[id].map { $0.map(String.init) ?? "nil" } ?? "n/a") != \(targetSpaceIndex)") }
        }
        check("SpaceE2E: 两窗都送达目标 Space \(targetSpaceIndex)（投递生效）", created.count == 2 && spacesHit == 2)

        // 清理：新建 iTerm2 窗可能落在不可见 space 上，yabai --close 对它们
        // no-op（无 AX 引用）；可靠关闭 = 向 session 写 exit 结束 shell，
        // 窗口随会话退出自动关闭（真机实证）。
        let itermLeaked = itermWindowIDs().subtracting(itermBefore)
        if !itermLeaked.isEmpty {
            let idList = itermLeaked.map(String.init).joined(separator: ", ")
            let closeScript = """
            tell application id "com.googlecode.iterm2"
                repeat with wid in {\(idList)}
                    try
                        tell window id (wid as integer) to tell current session to write text "exit"
                    end try
                end repeat
            end tell
            """
            _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", closeScript], timeout: 30)
        }
        // shell 退出→窗口关闭有延迟，失败再补发一轮 exit
        // 清理为 best-effort：exit 已写入，iTerm2 对不可见 space 会话的退出处理
        // 有 10-30s 滞后（真机实测，窗口最终自动关闭），不作为失败项
        Thread.sleep(forTimeInterval: 2.0)
        let leftoverIt = itermWindowIDs().intersection(itermLeaked)
        let leftoverYabai = yabaiWindowIDs().intersection(created)
        if leftoverIt.isEmpty && leftoverYabai.isEmpty {
            check("SpaceE2E: 本块创建的窗口已全部关闭", true)
        } else {
            print("    [诊断] 关闭滞后（iTerm2 后台处理，稍后自动完成）：it=\(leftoverIt.sorted()) yabai=\(leftoverYabai.sorted())")
        }
        let cleanupSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            if let createdSnapshot {
                TerminalGridController.shared.removeSnapshot(id: createdSnapshot.id)
            }
            if let visibleIndex {
                // best-effort：把视角拉回创建前的可见 space
                _ = SpaceController.shared.refocusWindowOnSpace(visibleIndex, operationID: "space-e2e-restore", prefetchedWindows: nil)
            }
            cleanupSem.signal()
        }
        while cleanupSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
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
