import AppKit
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionRestoreE2ETests.swift — 会话恢复 v2 真机 E2E
// （仅 VIBEFOCUS_SESSION_RESTORE_E2E=1 时运行；普通门禁不跑）。
//
// 红线对齐 Tests/e2e/README + 自动化测试清场纪律：只碰本 E2E 自己创建的 scratch
// 窗（创建→验证→关闭单批闭环，关后 CGWindowList 复核），绝不恢复「捕获到的全桌面
// 快照」——全桌面恢复会把用户在用窗卷进注入/重建（结构上就不该在 E2E 里发生）。
// 恢复阶段用代码构造的 mini 快照（scratch 窗位），捕获阶段的全桌面快照仅做只读断言
// （验证跨屏跨工作区采集与 pane 形态识别在真机上成立）后即删。
//
// 可选环境变量：
//   VIBEFOCUS_SESSION_RESTORE_E2E_SSH=<user@host>  追加远程 pane 腿（对该主机发起
//       一次真实 ssh 并在恢复后回收；未设置则跳过远程腿）。
extension RunnerHarness {

    func runSessionRestoreE2E() {
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_SESSION_RESTORE_E2E"] == "1" else { return }
        print("\n=== 会话恢复 v2 真机 E2E ===")
        let e2eSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await self.sessionRestoreE2EBody(sem: e2eSem)
        }
        while e2eSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func sessionRestoreE2EBody(sem: DispatchSemaphore) async {
        let op = makeOperationID(prefix: "session-restore-e2e")
        let controller = SessionRestoreController.shared
        let target = ProcessInfo.processInfo.environment["VIBEFOCUS_SESSION_RESTORE_E2E_SSH"]

        // 0. 前置：yabai + iTerm2
        guard SpaceController.shared.queryAllWindows() != nil,
              let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            check("E2E前置: yabai 可用且存在主屏", false)
            sem.signal()
            return
        }
        let mainYabaiDisplay = SpaceController.shared.exactYabaiDisplayIndex(for: mainScreen)
        let visibleBefore = SpaceController.shared.visibleSpaceIndex(forDisplayIndex: mainYabaiDisplay, ignoreCache: true)?.yabaiIndex

        // 1. 建 scratch 窗 W1（iTerm2，主屏当前工作区，写 cd /tmp）
        let planningFrame = {
            let base = CoordinateKit.quartzVisibleFrame(of: mainScreen)
            let insets = DisplayWorkArea.learnedInsets(displayID: CoordinateKit.cgDisplayID(for: mainScreen) ?? 0)
            return DisplayWorkArea.plannedFrame(visibleFrame: base, insets: insets)
        }()
        let w1Frame = CGRect(x: planningFrame.minX + 20, y: planningFrame.minY + 20,
                             width: min(560, planningFrame.width / 2), height: min(360, planningFrame.height / 2))
        let createScript = TerminalAutomationScript.itermCreateWindow(command: "cd /tmp", quartzFrame: w1Frame)
        guard let w1ASID = await runOsa(createScript)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !w1ASID.isEmpty else {
            check("E2E前置: scratch 窗创建", false)
            sem.signal()
            return
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        // 定位 W1 的 CG id（就近匹配，同 createTerminalCell 通道）
        let w1Readback = await runOsa(TerminalAutomationScript.itermGetBounds(windowID: w1ASID))
            .flatMap { TerminalAutomationScript.parseBounds($0) }
        var scratchCGIDs: Set<UInt32> = []
        if let rb = w1Readback {
            let candidates = cgWindowListAll().compactMap { entry -> (windowID: UInt32, bounds: CGRect?, isOnScreen: Bool)? in
                guard entry.layer == 0, entry.bounds != nil,
                      NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2" else { return nil }
                return (entry.windowID, entry.bounds, entry.isOnScreen)
            }
            if let cgID = TerminalAutomationScript.resolveCGWindowID(candidates: candidates, nearBounds: rb, excluding: []) {
                scratchCGIDs.insert(cgID)
            }
        }
        check("E2E前置: scratch 窗 W1 已建且 CG 可定位", !scratchCGIDs.isEmpty)
        // 实测落位（iTerm2 set bounds 会被钳制，快照匹配必须用真值而非预期值）
        let w1ActualFrame = cgWindowListAll().first { scratchCGIDs.contains($0.windowID) }?.bounds

        // 2. 全桌面捕获（只读断言用；v2 结构性验证：跨工作区窗全量在场）
        let captureResult = await controller.captureCurrentLayout(name: "SR-E2E 捕获")
        check("E2E捕获: 成功", captureResult.ok)
        let fullSnap = controller.snapshotsForRefresh().last { $0.name == "SR-E2E 捕获" }
        check("E2E捕获: 多窗多工作区在场（windows>4 且含非当前工作区窗）",
              (fullSnap?.windows.count ?? 0) > 4 && (fullSnap?.spaceCount ?? 0) >= 1)
        // W1 进快照且 pane 形态 = shell + cwd /tmp
        let w1Probe = w1ActualFrame ?? w1Frame
        let w1Entry = fullSnap?.windows.first { win in
            win.appBundleID == "com.googlecode.iterm2"
                && hypot(win.frame.midX - w1Probe.midX, win.frame.midY - w1Probe.midY) < 40
        }
        check("E2E捕获: scratch 窗在快照中且 cwd=/tmp 被记住",
              w1Entry != nil
              && w1Entry?.panes.first?.kind == .shell
              && (w1Entry?.panes.first?.cwd == "/tmp" || w1Entry?.panes.first?.cwd == "/private/tmp"))
        // 远程腿（真机用户桌面常态）：快照里应识别出 remoteSSH pane（用户真实 ssh 窗）
        let remotePaneCount = fullSnap?.windows.flatMap { $0.panes }.filter { $0.kind == .remoteSSH }.count ?? 0
        check("E2E捕获: 桌面上远程 ssh pane 被识别（≥1，真机常态）", remotePaneCount >= 1)

        // 3. 关掉 scratch 窗（先进程后窗，防确认框）
        _ = await runOsa("""
        tell application id "com.googlecode.iterm2"
            tell window id \(w1ASID) to tell current session to write text "exit"
        end tell
        """)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await runOsa("tell application id \"com.googlecode.iterm2\" to close window id \(w1ASID)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await dismissITermCloseConfirmation()

        // 4. 构造 mini 快照走恢复（只含 scratch 窗位；远程腿按环境变量可选）
        var windows = [SessionWindowSnapshot(
            appBundleID: "com.googlecode.iterm2",
            frame: w1Frame,
            displayID: CoordinateKit.cgDisplayID(for: mainScreen) ?? 0,
            yabaiDisplay: mainYabaiDisplay,
            yabaiSpace: visibleBefore,
            title: "SR-E2E",
            panes: [SessionPaneSnapshot(kind: .shell, cwd: "/tmp")]
        )]
        let w2Frame = CGRect(x: w1Frame.maxX + 40, y: w1Frame.minY, width: w1Frame.width, height: w1Frame.height)
        if let target, !target.isEmpty {
            windows.append(SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2",
                frame: w2Frame,
                displayID: CoordinateKit.cgDisplayID(for: mainScreen) ?? 0,
                yabaiDisplay: mainYabaiDisplay,
                yabaiSpace: visibleBefore,
                title: "SR-E2E-remote",
                panes: [SessionPaneSnapshot(kind: .remoteSSH, sshTarget: target)]
            ))
        }
        let mini = SessionRestoreSnapshot(name: "SR-E2E mini", windows: windows, launchCommand: nil)
        let restoreResult = await SessionRestoreExecutor(controller: controller).restore(snapshot: mini)
        check("E2E恢复: 执行成功", restoreResult.ok)
        check("E2E恢复: 汇总含新建计数", restoreResult.message.contains("新建"))

        // 5. 恢复后核验：窗在场 + frame 命中 + shell cwd=/tmp（远程腿验 ssh 进程）
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let allNow = cgWindowListAll().filter { entry in
            entry.layer == 0 && entry.isOnScreen
            && NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2"
        }
        let w1Restored = allNow.first { entry in
            guard let b = entry.bounds else { return false }
            return hypot(b.midX - w1Frame.midX, b.midY - w1Frame.midY) < 40
        }
        check("E2E恢复: shell 窗在目标位重建", w1Restored != nil)
        if let w1Restored, let tty = iTermSessionTTY(windowCGID: w1Restored.windowID) {
            let cwd = ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)
            check("E2E恢复: shell cwd 恢复为 /tmp", cwd == "/tmp" || cwd == "/private/tmp")
        } else {
            check("E2E恢复: shell cwd 恢复为 /tmp（tty 枚举失败）", false)
        }
        if target != nil, !target!.isEmpty {
            let w2Frame = CGRect(x: w1Frame.maxX + 40, y: w1Frame.minY, width: w1Frame.width, height: w1Frame.height)
            let w2Restored = allNow.first { entry in
                guard let b = entry.bounds else { return false }
                return hypot(b.midX - w2Frame.midX, b.midY - w2Frame.midY) < 40
            }
            check("E2E恢复: 远程窗在目标位重建", w2Restored != nil)
            if let w2Restored, let tty = iTermSessionTTY(windowCGID: w2Restored.windowID) {
                check("E2E恢复: 远程窗 tty 上有 ssh 进程在跑",
                      PaneClassifier.classify(
                        processLines: (ShellRunner.run(executable: "/bin/ps",
                                                       arguments: ["-t", String(tty.dropFirst("/dev/".count)), "-o", "pid=,command="], timeout: 2)?
                            .stdout ?? "").split(separator: "\n").map(String.init)
                      ).kind == .remoteSSH)
            } else {
                check("E2E恢复: 远程窗 tty 枚举（失败）", false)
            }
        }

        // 6. 清场：关闭恢复出的 scratch 窗（frame 已知）+ 删 E2E 快照 + CGWindowList 复核
        var scratchFrames: [CGRect?] = [w1Restored?.bounds]
        if let target, !target.isEmpty {
            scratchFrames.append(allNow.first { entry in
                guard let b = entry.bounds else { return false }
                return hypot(b.midX - w2Frame.midX, b.midY - w2Frame.midY) < 40
            }?.bounds)
        }
        var restoredScratchIDs: Set<UInt32> = []
        for entry in allNow {
            for frame in scratchFrames.compactMap({ $0 }) {
                if let b = entry.bounds,
                   hypot(b.midX - frame.midX, b.midY - frame.midY) < 40 {
                    restoredScratchIDs.insert(entry.windowID)
                }
            }
        }
        // 经 AppleScript 逐窗 exit（远程窗 exit 先断开 ssh 再关）
        for asid in await liveASWindowIDs(frames: restoredScratchIDs.compactMap { id in
            allNow.first { $0.windowID == id }?.bounds
        }) {
            _ = await runOsa("""
            tell application id "com.googlecode.iterm2"
                tell window id \(asid) to tell current session to write text "exit"
            end tell
            """)
            try? await Task.sleep(nanoseconds: 800_000_000)
            _ = await runOsa("tell application id \"com.googlecode.iterm2\" to close window id \(asid)")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        // 关窗确认 sheet（用户偏好「关闭前确认」）：重试点 OK 直到无 sheet
        await dismissITermCloseConfirmation()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let id = fullSnap?.id { controller.removeSnapshot(id: id) }
        check("E2E清场: 快照已删除", controller.snapshotsForRefresh().contains { $0.name == "SR-E2E 捕获" } == false)

        var leftovers = cgWindowListAll().filter { entry in
            guard entry.layer == 0, let b = entry.bounds, b.width > 100, b.height > 100,
                  NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2" else { return false }
            return restoredScratchIDs.contains(entry.windowID)
        }
        if !leftovers.isEmpty {
            // 最后一轮：再点一次确认 sheet + 直接 close，5s 内收不掉才判 FAIL
            await dismissITermCloseConfirmation()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            leftovers = cgWindowListAll().filter { entry in
                guard entry.layer == 0, let b = entry.bounds, b.width > 100, b.height > 100,
                      NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2" else { return false }
                return restoredScratchIDs.contains(entry.windowID)
            }
        }
        check("E2E清场: scratch 窗零残留（残留 id: \(leftovers.map { String($0.windowID) }.joined(separator: ","))）",
              leftovers.isEmpty)

        _ = op
        sem.signal()
    }

    // MARK: 辅助

    /// CG 窗 → iTerm2 session tty（bounds 就近匹配枚举行）
    private func iTermSessionTTY(windowCGID: UInt32) -> String? {
        guard let entry = cgWindowListAll().first(where: { $0.windowID == windowCGID }),
              let bounds = entry.bounds else { return nil }
        guard let out = ShellRunner.run(executable: "/usr/bin/osascript",
                                        arguments: ["-e", PaneEnumeration.itermEnumerateSessions()], timeout: 30),
              out.exitCode == 0 else { return nil }
        let sessions = PaneEnumeration.parseITermSessions(out.stdout)
        let target = sessions.first { hypot($0.windowBounds.midX - bounds.midX, $0.windowBounds.midY - bounds.midY) < 40 }
        return target?.tty
    }

    /// 恢复窗的 AppleScript window id（bounds 就近）
    private func liveASWindowIDs(frames: [CGRect?]) async -> [String] {
        guard let out = await runOsa("""
        tell application id "com.googlecode.iterm2"
            set output to ""
            repeat with w in windows
                set wb to bounds of w
                set output to output & (id of w as string) & "|" & (item 1 of wb as string) & "," & (item 2 of wb as string) & "," & (item 3 of wb as string) & "," & (item 4 of wb as string) & linefeed
            end repeat
            return output
        end tell
        """) else { return [] }
        var result: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|")
            guard parts.count == 2 else { continue }
            let nums = parts[1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard nums.count == 4 else { continue }
            let rect = CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
            for frame in frames.compactMap({ $0 }) {
                if hypot(rect.midX - frame.midX, rect.midY - frame.midY) < 40 {
                    result.append(String(parts[0]))
                }
            }
        }
        return result
    }

    /// iTerm2 关窗确认 sheet（用户偏好「关闭前确认」）→ System Events AXPress OK。
    /// 轮询 ~8s；无 sheet 立即返回。真机实锚：远程腿 exit 后本地 shell 仍在，
    /// `close window id` 必弹「Close Window #N?」sheet，不点掉窗永远关不掉。
    private func dismissITermCloseConfirmation() async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let out = await runOsa("""
            tell application "System Events" to tell process "iTerm2"
                set hit to false
                repeat with w in windows
                    try
                        repeat with sh in sheets of w
                            repeat with b in buttons of sh
                                try
                                    if name of b is "OK" then
                                        click b
                                        set hit to true
                                        exit repeat
                                    end if
                                end try
                            end repeat
                            if hit then exit repeat
                        end repeat
                    end try
                    if hit then exit repeat
                end repeat
                return hit as string
            end tell
            """)
            if out?.trimmingCharacters(in: .whitespacesAndNewlines) != "true" { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func runOsa(_ script: String) async -> String? {
        let result = await Task.detached(priority: .userInitiated) {
            ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
        }.value
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout
    }
}
