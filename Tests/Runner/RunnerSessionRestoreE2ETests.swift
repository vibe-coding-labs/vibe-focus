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
// 后即删。
//
// 七条腿（2026-09-14 自测加压轮二）：
//   S-A 全桌面捕获完整性审计：yabai 真值逐窗对账（跨屏 × 跨工作区 × 每窗 space/display）
//   S-B 双屏恢复：主屏 + 副屏各重建一窗，验「每块屏幕」
//   S-C claude --resume 注入：sessionID 窗建出后命令行原文进 pane（假 ID 即刻报错退出，
//       不进交互——真机 2026-09-14 实探 exit=1）
//   S-D skipAlive：恢复时活窗 tty 上真有 ssh 挂线 → 「仍活着跳过」，同 CG 窗不被重建
//   S-E 远程 resume 全命令：ssh -t <target> 'cd … && claude --resume …' 原文进 pane
//   S-F 多 pane：同窗双 tab 捕获逐 pane 记忆 + 恢复（首 pane 建窗 + itermAppendTab）
//   S-G 自动恢复正式入口：偏好 → 隔离库快照 → runAutoRestoreIfEnabled 异步建窗到位
//
// 环境变量：
//   VIBEFOCUS_SESSION_RESTORE_E2E=1                    开关（必填）
//   VIBEFOCUS_SESSION_RESTORE_E2E_SSH=<user@host>      远程腿主机（免密；缺省用
//       cc11001100@192.168.1.83——本机免密清单内的固定测试机）
extension RunnerHarness {

    /// S-E/S-D 远程腿默认主机（免密 BatchMode 可用）
    private static var e2eSSHTarget: String {
        let env = ProcessInfo.processInfo.environment["VIBEFOCUS_SESSION_RESTORE_E2E_SSH"]
        return (env?.isEmpty ?? true) ? "cc11001100@192.168.1.83" : env!
    }

    func runSessionRestoreE2E() {
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_SESSION_RESTORE_E2E"] == "1" else { return }
        print("\n=== 会话恢复 v2 真机 E2E（五腿加压）===")
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
        let sshTarget = Self.e2eSSHTarget

        // 0. 前置：yabai + 主副双屏
        guard SpaceController.shared.queryAllWindows() != nil,
              let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            check("E2E前置: yabai 可用且存在主屏", false)
            sem.signal()
            return
        }
        let mainCGID = CoordinateKit.cgDisplayID(for: mainScreen) ?? 0
        guard let secondScreen = NSScreen.screens.first(where: {
            CoordinateKit.cgDisplayID(for: $0) != nil && CoordinateKit.cgDisplayID(for: $0) != mainCGID
                && $0.frame.width > 300
        }) else {
            check("E2E前置: 存在副屏（双屏恢复腿需要）", false)
            sem.signal()
            return
        }
        let secondCGID = CoordinateKit.cgDisplayID(for: secondScreen) ?? 0
        let mainYabaiDisplay = SpaceController.shared.exactYabaiDisplayIndex(for: mainScreen)
        let secondYabaiDisplay = SpaceController.shared.exactYabaiDisplayIndex(for: secondScreen)
        let visibleBeforeMain = SpaceController.shared.visibleSpaceIndex(forDisplayIndex: mainYabaiDisplay, ignoreCache: true)?.yabaiIndex
        let visibleBeforeSecond = SpaceController.shared.visibleSpaceIndex(forDisplayIndex: secondYabaiDisplay, ignoreCache: true)?.yabaiIndex

        func planningFrame(of screen: NSScreen) -> CGRect {
            let base = CoordinateKit.quartzVisibleFrame(of: screen)
            let insets = DisplayWorkArea.learnedInsets(displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0)
            return DisplayWorkArea.plannedFrame(visibleFrame: base, insets: insets)
        }
        let mainPlan = planningFrame(of: mainScreen)
        let secondPlan = planningFrame(of: secondScreen)
        func scratchFrame(_ plan: CGRect, x: CGFloat, y: CGFloat) -> CGRect {
            CGRect(x: plan.minX + x, y: plan.minY + y,
                   width: min(560, plan.width / 2), height: min(360, plan.height / 2))
        }

        // ── 1. 建 W_D（S-D skipAlive 腿）：窗内跑真 ssh 挂线 300s ─────────────
        let wdTargetFrame = scratchFrame(mainPlan, x: 20, y: 20)
        let wd = await createScratchWindow(
            command: "ssh -o BatchMode=yes -o StrictHostKeyChecking=no \(sshTarget) 'sleep 300'",
            frame: wdTargetFrame)
        check("E2E前置: W_D(活ssh腿) 已建且 CG 可定位", wd.cgID != nil)

        // ── 2. 建 W1（捕获断言腿：shell + cd /tmp）──────────────────────────
        let w1Frame = scratchFrame(mainPlan, x: 640, y: 20)
        let w1 = await createScratchWindow(command: "cd /tmp", frame: w1Frame)
        check("E2E前置: W1(shell腿) 已建且 CG 可定位", w1.cgID != nil)
        let w1ActualFrame = w1.actualFrame ?? w1Frame

        // ── 2b. 建 W_T（S-F 多 pane 腿：同窗 2 个 tab，tab1=/tmp tab2=/etc）──
        let wt = await createScratchWindowWithTabs(commands: ["cd /tmp", "cd /etc"])
        check("E2E前置: W_T(多pane腿) 已建且 CG 可定位", wt.cgID != nil)
        let wtActualFrame = wt.actualFrame

        // ── 3. 全桌面捕获 + S-A 逐窗审计（只读）────────────────────────────
        // 真值先取（与捕获内部查询间隔最小化）
        let groundTruth = (SpaceController.shared.queryAllWindows() ?? []).filter {
            SessionRestoreController.isCapturableYabaiWindow($0, bundleIDOf: { pid in
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            })
        }
        let captureResult = await controller.captureCurrentLayout(name: "SR-E2E 捕获")
        check("E2E捕获: 成功", captureResult.ok)
        guard let fullSnap = controller.snapshotsForRefresh().last(where: { $0.name == "SR-E2E 捕获" }) else {
            check("E2E捕获: 快照落库", false)
            await cleanupE2E(wd: wd, restoredASIDs: [], allScratchIDs: [])
            sem.signal()
            return
        }

        // S-A：真值逐窗对账（frame 中心 <40 + 同 display + 同 space 唯一命中）
        var missing: [String] = []
        var mismatched: [String] = []
        for gt in groundTruth {
            guard let f = gt.frame else { continue }
            let rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            guard let hit = fullSnap.windows.first(where: { w in
                hypot(w.frame.midX - rect.midX, w.frame.midY - rect.midY) < 40
                    && w.yabaiDisplay == gt.display && w.yabaiSpace == gt.space
            }) else {
                missing.append("id\(gt.id ?? -1)@d\(gt.display ?? -1)s\(gt.space ?? -1)")
                continue
            }
            if hit.panes.isEmpty { mismatched.append("id\(gt.id ?? -1):panes空") }
        }
        check("S-A审计: 真值 \(groundTruth.count) 窗全部入快照（缺: \(missing.prefix(6).joined(separator: ","))）",
              missing.isEmpty && fullSnap.windows.count == groundTruth.count)
        check("S-A审计: 每窗 pane 形态齐全（异常 \(mismatched.count)）", mismatched.isEmpty)
        let gtSpaces = Set(groundTruth.compactMap(\.space))
        let gtDisplays = Set(groundTruth.compactMap(\.display))
        check("S-A审计: 工作区覆盖 \(gtSpaces.count) 个 / 屏幕 \(gtDisplays.count) 块（快照 spaceCount=\(fullSnap.spaceCount) displayCount=\(fullSnap.displayCount)）",
              fullSnap.spaceCount == gtSpaces.count && fullSnap.displayCount == gtDisplays.count)
        // W1：shell + cwd /tmp 被记住
        let w1Entry = fullSnap.windows.first { win in
            win.appBundleID == "com.googlecode.iterm2"
                && hypot(win.frame.midX - w1ActualFrame.midX, win.frame.midY - w1ActualFrame.midY) < 40
        }
        check("S-A审计: W1 shell 窗 cwd=/tmp 被记住",
              w1Entry?.panes.first?.kind == .shell
              && (w1Entry?.panes.first?.cwd == "/tmp" || w1Entry?.panes.first?.cwd == "/private/tmp"))
        // S-F：多 tab 窗逐 pane 记忆（tab 序 = pane 序）
        if let wtActualFrame {
            let wtEntry = fullSnap.windows.first { win in
                win.appBundleID == "com.googlecode.iterm2"
                    && hypot(win.frame.midX - wtActualFrame.midX, win.frame.midY - wtActualFrame.midY) < 40
            }
            let panes = wtEntry?.panes ?? []
            check("S-F捕获: 多 tab 窗记到 2 个 pane（实得 \(panes.count)）", panes.count == 2)
            check("S-F捕获: tab1 cwd=/tmp 被记住",
                  panes.first?.cwd == "/tmp" || panes.first?.cwd == "/private/tmp")
            check("S-F捕获: tab2 cwd=/etc 被记住",
                  panes.last?.cwd == "/etc" || panes.last?.cwd == "/private/etc")
        } else {
            check("S-F捕获: 多 tab 窗记到 2 个 pane（W_T 未定位，跳过）", false)
            check("S-F捕获: tab1 cwd=/tmp 被记住（跳过）", false)
            check("S-F捕获: tab2 cwd=/etc 被记住（跳过）", false)
        }
        // W_D：远程 ssh 活形态被识别
        let wdEntry = fullSnap.windows.first { win in
            win.appBundleID == "com.googlecode.iterm2"
                && hypot(win.frame.midX - (wd.actualFrame ?? wdTargetFrame).midX,
                         win.frame.midY - (wd.actualFrame ?? wdTargetFrame).midY) < 40
        }
        // W_D 的「探活」断言不设硬门：wasRemoteSessionLive 依赖 ssh 传输层健康，
        // 而本机 TUN 代理（fake-IP 198.18.x）对 LAN ssh 有间歇病态（2026-09-14 实锤
        // 秒断 255 / banner 超时 / 静默挂死，与代码路径无关、argv 字节级一致仍复现）。
        // 产品契约 = 分类与目的地解析确定性正确 + 探活失败诚实降级（captured live
        // 与否只进台账）。探针语义本身由 Runner 注入直测锁定。
        check("S-A审计: W_D pane 识别为 remoteSSH 且目的地解析正确",
              wdEntry?.panes.first?.kind == .remoteSSH
              && wdEntry?.panes.first?.sshTarget == sshTarget)
        // [DIAG] 探针归因（原始 ssh 形态 + API 探针 + W_D pane 全字段）
        let rawProbe = ShellRunner.run(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=no",
                        sshTarget, RemoteSessionProbe.remoteCommand],
            timeout: 6)
        let rawEntries = rawProbe.flatMap { RemoteSessionProbe.parseProbeOutput($0.stdout) } ?? []
        print("    [DIAG] 原始探针: hasResult=\(rawProbe != nil) exit=\(rawProbe?.exitCode ?? -999) stdoutLines=\(rawProbe?.stdout.split(separator: "\n").count ?? -1) stderrHead=\(rawProbe?.stderr.prefix(160) ?? "nil") entries=\(rawEntries.count)")
        let apiEntries = RemoteSessionProbe.probe(target: sshTarget, port: nil, runner: { exe, args, timeout in
            let t0 = Date()
            let r = ShellRunner.run(executable: exe, arguments: args, timeout: timeout)
            print("    [DIAG] API runner: dt=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s nil=\(r == nil) exit=\(r?.exitCode ?? -999) lines=\((r?.stdout ?? "").split(separator: "\n").count) stderrHead=\((r?.stderr ?? "").prefix(120)) argvCount=\(args.count) argvTailHead=\(args.last?.prefix(30) ?? "nil")")
            return r
        })
        print("    [DIAG] API探针: entries=\(apiEntries.count)")
        if let wdPane = wdEntry?.panes.first {
            print("    [DIAG] W_D pane: kind=\(wdPane.kind.rawValue) live=\(wdPane.wasRemoteSessionLive) target=\(wdPane.sshTarget ?? "nil") tty=\(wdPane.tty ?? "nil") title=\(wdPane.title ?? "nil") cmd=\(wdPane.sshCommand?.prefix(120) ?? "nil")")
        } else {
            print("    [DIAG] W_D pane: wdEntry 未命中（frame 匹配失败）")
        }
        // 桌面原生远程窗（用户常态）与 session 覆盖——信息性输出
        let remotePaneCount = fullSnap.windows.flatMap { $0.panes }.filter { $0.kind == .remoteSSH }.count
        let sessionPaneCount = fullSnap.windows.flatMap { $0.panes }.filter { $0.sessionID != nil }.count
        print("    [S-A] 桌面实况：\(fullSnap.windows.count) 窗 / \(fullSnap.spaceCount) 工作区 / \(fullSnap.displayCount) 屏；remoteSSH pane=\(remotePaneCount)，session pane=\(sessionPaneCount)")
        check("S-A审计: 桌面远程 ssh pane 被识别（≥1，含 W_D）", remotePaneCount >= 1)

        // ── 4. 关 W1 与 W_T（先进程后窗，防确认框；W_T 关窗会连 tab2 的活壳一起
        // 关，确认 sheet 必弹）──────────────────────────────────────────────
        await closeScratchWindow(asid: w1.asid)
        await closeScratchWindow(asid: wt.asid)
        await dismissITermCloseConfirmation()

        // ── 5. mini 快照构造（S-B/C/D/E 腿；碰撞守卫后落位）────────────────
        // 恢复时活窗 frame 中心 15px 内会被匹配/注入——create 目标位必须离一切
        // 现存窗 ≥60px，绝不碰用户在用窗。
        let liveFrames = cgWindowListAll().filter { entry in
            entry.layer == 0 && entry.isOnScreen && entry.bounds != nil
                && NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2"
        }.compactMap { $0.bounds }
        func collideFree(_ candidate: CGRect) -> CGRect {
            var frame = candidate
            while liveFrames.contains(where: { hypot($0.midX - frame.midX, $0.midY - frame.midY) < 60 }) {
                frame.origin.x += 40
                if frame.maxX > mainPlan.maxX || frame.maxX > secondPlan.maxX {
                    frame.origin.x = candidate.minX
                    frame.origin.y += 40
                }
            }
            return frame
        }
        let wAFrame = collideFree(scratchFrame(mainPlan, x: 20, y: 440))      // S-B 主屏 shell /tmp
        let wCFrame = collideFree(scratchFrame(mainPlan, x: 640, y: 440))     // S-C claude 注入
        let wEFrame = collideFree(scratchFrame(mainPlan, x: 20, y: 20))       // S-E 远程 resume
        let wTFrame = collideFree(scratchFrame(mainPlan, x: 640, y: 20))      // S-F 多 pane（2 tab）
        let wBFrame = collideFree(scratchFrame(secondPlan, x: 20, y: 20))     // S-B 副屏 shell /

        var miniWindows = [
            SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wAFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-A",
                panes: [SessionPaneSnapshot(kind: .shell, cwd: "/tmp")]),
            SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wCFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-C",
                panes: [SessionPaneSnapshot(kind: .localClaude, sessionID: "e2e-fake-session", cwd: "/tmp")]),
            SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wEFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-E",
                panes: [SessionPaneSnapshot(kind: .remoteSSH, sessionID: "e2e-remote-fake", cwd: "/tmp",
                                            sshTarget: sshTarget)]),
            SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wTFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-T",
                panes: [SessionPaneSnapshot(kind: .shell, cwd: "/tmp"),
                        SessionPaneSnapshot(kind: .shell, cwd: "/etc")]),
            SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wBFrame,
                displayID: secondCGID, yabaiDisplay: secondYabaiDisplay, yabaiSpace: visibleBeforeSecond,
                title: "SR-E2E-B",
                panes: [SessionPaneSnapshot(kind: .shell, cwd: "/")])
        ]
        // W_D：用实测 frame 精确录入（15px 匹配容差要求）；恢复时应被 skipAlive。
        // 未建成则不录入——否则恢复会在其 frame 上重复建一窗（2026-09-16 级联教训）
        let wdLegArmed = wd.cgID != nil && (wd.actualFrame ?? wdTargetFrame) != .zero
        if wdLegArmed {
            miniWindows.append(SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: wd.actualFrame ?? wdTargetFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-D",
                panes: [SessionPaneSnapshot(kind: .remoteSSH, sshTarget: sshTarget,
                                            wasRemoteSessionLive: true)]))
        }
        let mini = SessionRestoreSnapshot(name: "SR-E2E mini", windows: miniWindows, launchCommand: nil)

        // ── 6. 恢复前 CG id 基线 → 执行恢复 ────────────────────────────────
        func currentItermCGIDs() -> Set<UInt32> {
            Set(cgWindowListAll().filter { entry in
                entry.layer == 0
                    && NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2"
            }.map(\.windowID))
        }
        let preIDs = currentItermCGIDs()
        let restoreResult = await SessionRestoreExecutor(controller: controller).restore(snapshot: mini)
        check("E2E恢复: 执行成功（\(restoreResult.message)）", restoreResult.ok)
        check("E2E恢复: 汇总含新建 5 窗", restoreResult.message.contains("新建 5 窗"))
        if wdLegArmed {
            check("E2E恢复: 汇总含仍活着跳过 1 窗（S-D skipAlive）", restoreResult.message.contains("仍活着跳过 1 窗"))
        } else {
            check("S-D: W_D 未建成，本轮跳过 skipAlive 腿（防级联，见前置 DIAG）", true)
        }

        // ── 7. 恢复后核验 ──────────────────────────────────────────────────
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let newIDs = currentItermCGIDs().subtracting(preIDs)
        func newWindow(near frame: CGRect, tolerance: CGFloat = 48) -> (windowID: UInt32, bounds: CGRect?)? {
            let hits = cgWindowListAll().filter { entry in
                newIDs.contains(entry.windowID)
                    && entry.bounds.map { hypot($0.midX - frame.midX, $0.midY - frame.midY) < tolerance } == true
            }
            return hits.count == 1 ? (hits[0].windowID, hits[0].bounds) : nil
        }
        // S-B 主屏 shell 窗
        if let wARestored = newWindow(near: wAFrame) {
            check("S-B: 主屏 shell 窗在目标位重建", true)
            if let tty = iTermSessionTTY(windowCGID: wARestored.windowID) {
                let cwd = ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)
                check("S-B: 主屏 shell cwd 恢复为 /tmp", cwd == "/tmp" || cwd == "/private/tmp")
            } else { check("S-B: 主屏 shell tty 枚举", false) }
        } else {
            check("S-B: 主屏 shell 窗在目标位重建", false)
        }
        // S-B 副屏 shell 窗（跨屏投递）
        if let wBRestored = newWindow(near: wBFrame) {
            check("S-B: 副屏 shell 窗跨屏投递到位", true)
            if let tty = iTermSessionTTY(windowCGID: wBRestored.windowID) {
                let cwd = ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)
                check("S-B: 副屏 shell cwd 恢复为 /", cwd == "/")
            } else { check("S-B: 副屏 shell tty 枚举", false) }
        } else {
            check("S-B: 副屏 shell 窗跨屏投递到位（位 \(wBFrame) 未找到新窗）", false)
        }
        // S-C claude --resume 注入
        if let wCRestored = newWindow(near: wCFrame) {
            check("S-C: claude 注入窗在目标位重建", true)
            let content = await itermWindowContents(frame: wCRestored.bounds ?? wCFrame)
            check("S-C: pane 含 claude --resume e2e-fake-session 原文",
                  content.contains("claude --resume e2e-fake-session"))
        } else {
            check("S-C: claude 注入窗在目标位重建", false)
        }
        // S-E 远程 resume 全命令
        if let wERestored = newWindow(near: wEFrame) {
            check("S-E: 远程 resume 窗在目标位重建", true)
            let content = await itermWindowContents(frame: wERestored.bounds ?? wEFrame)
            check("S-E: pane 含 ssh -t 与 claude --resume e2e-remote-fake",
                  content.contains("claude --resume e2e-remote-fake") && content.contains("ssh"))
            if let tty = iTermSessionTTY(windowCGID: wERestored.windowID) {
                // claude 假 ID 报错退出后 ssh 断开 → 回本地 shell；此窗仍算重建成功
                check("S-E: 远程窗 tty 在案", !tty.isEmpty)
            } else { check("S-E: 远程窗 tty 枚举", false) }
        } else {
            check("S-E: 远程 resume 窗在目标位重建", false)
        }
        // S-F：多 pane 恢复（首 pane 建窗 + itermAppendTab 追加 tab2）
        if let wTRestored = newWindow(near: wTFrame) {
            check("S-F恢复: 多 pane 窗在目标位重建", true)
            let ttys = iTermSessionTTYs(windowCGID: wTRestored.windowID)
            check("S-F恢复: 重建窗含 2 个 tab（实得 \(ttys.count)）", ttys.count == 2)
            let cwds = ttys.map { ClaudeSessionLocator.shellWorkingDirectory(onTTY: $0) }
            check("S-F恢复: tab1 cwd=/tmp", cwds.first == "/tmp" || cwds.first == "/private/tmp")
            check("S-F恢复: tab2 cwd=/etc", cwds.last == "/etc" || cwds.last == "/private/etc")
        } else {
            check("S-F恢复: 多 pane 窗在目标位重建", false)
            check("S-F恢复: 重建窗含 2 个 tab（窗未建，跳过）", false)
            check("S-F恢复: tab1 cwd=/tmp（跳过）", false)
            check("S-F恢复: tab2 cwd=/etc（跳过）", false)
        }
        // S-D：W_D 未被重建——同一 CG id 仍在、不在新窗集、未被注入
        if wdLegArmed {
            let wdID = wd.cgID
            let wdStillThere = wdID.map { id in cgWindowListAll().contains { $0.windowID == id } } ?? false
            check("S-D: 活 ssh 窗未被重建（同 CG id \(wdID.map(String.init) ?? "?") 仍在原位）",
                  wdStillThere && !(wdID.map { newIDs.contains($0) } ?? true))
            let wdContent = await itermWindowContents(frame: wd.actualFrame ?? wdTargetFrame)
            check("S-D: 活 ssh 窗未被注入 e2e 命令", !wdContent.contains("e2e-remote-fake") && !wdContent.contains("e2e-fake-session"))
        }

        // ── 8. 清场：新窗逐个回收 + W_D 强收 + 快照删除 ────────────────────
        var allScratchIDs = newIDs
        if let wdID = wd.cgID { allScratchIDs.insert(wdID) }
        let restoredASIDs = await liveASWindowIDs(frames: cgWindowListAll().compactMap { entry in
            allScratchIDs.contains(entry.windowID) ? entry.bounds : nil
        })
        await cleanupE2E(wd: wd, restoredASIDs: restoredASIDs, allScratchIDs: Array(allScratchIDs))
        controller.removeSnapshot(id: fullSnap.id)
        check("E2E清场: 快照已删除", controller.snapshotsForRefresh().contains { $0.name == "SR-E2E 捕获" } == false)

        // ── 9. S-G 自动恢复正式入口（设置页勾选后的生产链路：偏好 → 快照定位 →
        // runAutoRestoreIfEnabled → 异步恢复）。min 快照落隔离库 + 偏好写 runner
        // 自有 domain（与装机 app 的 com.openai.vibe-focus 域无关）────────────
        let sgFrame = collideFree(scratchFrame(mainPlan, x: 640, y: 440))
        let sgMini = SessionRestoreSnapshot(
            name: "SR-E2E mini-auto",
            windows: [SessionWindowSnapshot(
                appBundleID: "com.googlecode.iterm2", frame: sgFrame,
                displayID: mainCGID, yabaiDisplay: mainYabaiDisplay, yabaiSpace: visibleBeforeMain,
                title: "SR-E2E-G",
                panes: [SessionPaneSnapshot(kind: .shell, cwd: "/tmp")])],
            launchCommand: nil)
        controller.store.upsert(sgMini)
        TerminalGridPreferences.autoRestoreEnabled = true
        TerminalGridPreferences.autoRestoreSnapshotID = sgMini.id
        let preGIDs = currentItermCGIDs()
        controller.runAutoRestoreIfEnabled()
        check("S-G: 入口幂等门翻转 hasRunAutoRestoreThisLaunch", controller.hasRunAutoRestoreThisLaunch)
        // 恢复是 fire-and-forget Task：轮询新窗到位（预算 45s）
        var sgRestored: (windowID: UInt32, bounds: CGRect?)? = nil
        let sgDeadline = Date().addingTimeInterval(45)
        while Date() < sgDeadline && sgRestored == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let nowG = currentItermCGIDs().subtracting(preGIDs)
            if let hit = cgWindowListAll().first(where: {
                nowG.contains($0.windowID)
                    && $0.bounds.map { hypot($0.midX - sgFrame.midX, $0.midY - sgFrame.midY) < 48 } == true
            }) {
                sgRestored = (hit.windowID, hit.bounds)
            }
        }
        check("S-G: 偏好+快照入口自动建窗到位", sgRestored != nil)
        if let sgRestored, let tty = iTermSessionTTY(windowCGID: sgRestored.windowID) {
            let cwd = ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)
            check("S-G: 自动恢复 cwd=/tmp", cwd == "/tmp" || cwd == "/private/tmp")
        } else if sgRestored == nil {
            check("S-G: 自动恢复 cwd=/tmp（未建窗，跳过）", false)
        }
        // S-G 清场：新窗（含断言未命中但确实建出的）逐个回收 + 删快照 + 偏好复位
        let sgLeftNew = currentItermCGIDs().subtracting(preGIDs)
        for id in sgLeftNew { allScratchIDs.insert(id) }
        let sgASIDs = await liveASWindowIDs(frames: cgWindowListAll().compactMap { entry in
            sgLeftNew.contains(entry.windowID) ? entry.bounds : nil
        })
        for asid in sgASIDs { await closeScratchWindow(asid: asid) }
        await dismissITermCloseConfirmation()
        controller.removeSnapshot(id: sgMini.id)
        check("S-G清场: mini 快照已删除", controller.snapshotsForRefresh().contains { $0.name == "SR-E2E mini-auto" } == false)
        TerminalGridPreferences.autoRestoreEnabled = false
        TerminalGridPreferences.autoRestoreSnapshotID = nil
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // ── 10. 零残留终检（全部腿的 scratch id 并集）──────────────────────
        var leftovers = cgWindowListAll().filter { entry in
            allScratchIDs.contains(entry.windowID)
        }
        if !leftovers.isEmpty {
            await dismissITermCloseConfirmation()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            leftovers = cgWindowListAll().filter { allScratchIDs.contains($0.windowID) }
        }
        check("E2E清场: scratch 窗零残留（残留 id: \(leftovers.map { String($0.windowID) }.joined(separator: ","))）",
              leftovers.isEmpty)

        _ = op
        sem.signal()
    }

    // MARK: 辅助

    private struct ScratchWindow {
        let asid: String
        let cgID: UInt32?
        let actualFrame: CGRect?
    }

    /// 建 scratch 窗并定位 CG id / 实测 frame（iTerm2 set bounds 会被钳制，一切
    /// 断言以实测为准）。建窗失败带一次重试 + stderr 诊断（2026-09-16 真机实测
    /// 出现过一次无征兆建窗失败，级联出重复建窗）
    private func createScratchWindow(command: String, frame: CGRect) async -> ScratchWindow {
        var lastDiag = "nil(osascript 超时或启动失败)"
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
            let script = TerminalAutomationScript.itermCreateWindow(command: command, quartzFrame: frame)
            let result = await Task.detached(priority: .userInitiated) {
                ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
            }.value
            let asid = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard result?.exitCode == 0, !asid.isEmpty else {
                lastDiag = "exit=\(result?.exitCode ?? -999) stderr=\(result?.stderr.prefix(120) ?? "nil")"
                continue
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let readback = await runOsa(TerminalAutomationScript.itermGetBounds(windowID: asid))
                .flatMap { TerminalAutomationScript.parseBounds($0) }
            var cgID: UInt32?
            if let rb = readback {
                let candidates = cgWindowListAll().compactMap { entry -> (windowID: UInt32, bounds: CGRect?, isOnScreen: Bool)? in
                    guard entry.layer == 0, entry.bounds != nil,
                          NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2" else { return nil }
                    return (entry.windowID, entry.bounds, entry.isOnScreen)
                }
                cgID = TerminalAutomationScript.resolveCGWindowID(candidates: candidates, nearBounds: rb, excluding: [])
            }
            if cgID == nil { lastDiag = "AS id=\(asid) 但 CG 定位失败（readback=\(readback.map { "\($0)" } ?? "nil")）" }
            if let cgID {
                let actual = cgWindowListAll().first { $0.windowID == cgID }?.bounds
                return ScratchWindow(asid: asid, cgID: cgID, actualFrame: actual)
            }
        }
        print("    [DIAG] createScratchWindow 失败: \(lastDiag)")
        return ScratchWindow(asid: "", cgID: nil, actualFrame: nil)
    }

    /// 建带多个 tab 的 scratch 窗（S-F 多 pane 腿）：第 1 条命令进 tab1，其余逐个
    /// create tab + 写入
    private func createScratchWindowWithTabs(commands: [String]) async -> ScratchWindow {
        guard let first = commands.first else {
            return ScratchWindow(asid: "", cgID: nil, actualFrame: nil)
        }
        let escapedFirst = first.replacingOccurrences(of: "\"", with: "\\\"")
        var script = """
        tell application id "com.googlecode.iterm2"
            set w to (create window with default profile)
            tell current session of w to write text "\(escapedFirst)"
        """
        for command in commands.dropFirst() {
            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            script += "\n    tell w to create tab with default profile"
            script += "\n    tell current session of w to write text \"\(escaped)\""
        }
        script += "\n    return id of w\nend tell"
        guard let asid = await runOsa(script)?.trimmingCharacters(in: .whitespacesAndNewlines), !asid.isEmpty else {
            return ScratchWindow(asid: "", cgID: nil, actualFrame: nil)
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        let readback = await runOsa(TerminalAutomationScript.itermGetBounds(windowID: asid))
            .flatMap { TerminalAutomationScript.parseBounds($0) }
        var cgID: UInt32?
        if let rb = readback {
            let candidates = cgWindowListAll().compactMap { entry -> (windowID: UInt32, bounds: CGRect?, isOnScreen: Bool)? in
                guard entry.layer == 0, entry.bounds != nil,
                      NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier == "com.googlecode.iterm2" else { return nil }
                return (entry.windowID, entry.bounds, entry.isOnScreen)
            }
            cgID = TerminalAutomationScript.resolveCGWindowID(candidates: candidates, nearBounds: rb, excluding: [])
        }
        let actual = cgID.flatMap { id in cgWindowListAll().first { $0.windowID == id }?.bounds }
        return ScratchWindow(asid: asid, cgID: cgID, actualFrame: actual)
    }

    /// 关 scratch 窗：先杀 pane 进程（清场纪律=先杀后台进程再关窗：防确认框、
    /// 断远程 ssh/claude；2026-09-16 实测 iTerm2 关窗确认 sheet 在部分 app 状态下
    /// 无法渲染=close 永久挂起）→ Ctrl+C/exit 保险 → close → sheet 点掉兜底
    private func closeScratchWindow(asid: String) async {
        guard !asid.isEmpty else { return }
        let ttyList = await runOsa(
            "tell application id \"com.googlecode.iterm2\" to get tty of sessions of tabs of window id \(asid)")
        let ttys = (ttyList ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        for tty in ttys {
            let base = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
            if let out = ShellRunner.run(executable: "/bin/ps", arguments: ["-t", base, "-o", "pid="], timeout: 2) {
                for line in out.stdout.split(separator: "\n") {
                    if let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                        _ = ShellRunner.run(executable: "/bin/kill", arguments: ["-9", String(pid)], timeout: 2)
                    }
                }
            }
        }
        _ = await runOsa("""
        tell application id "com.googlecode.iterm2"
            tell window id \(asid) to tell current session to write text (ASCII character 3)
        end tell
        """)
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = await runOsa("""
        tell application id "com.googlecode.iterm2"
            tell window id \(asid) to tell current session to write text "exit"
        end tell
        """)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await runOsa("tell application id \"com.googlecode.iterm2\" to close window id \(asid)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// 清场：恢复出的新窗逐个回收；W_D 内有活 ssh（exit 要等 sleep 完）→ 直接
    /// close + 确认 sheet 点掉，pty 关闭即 SIGHUP 掉远程
    private func cleanupE2E(wd: ScratchWindow, restoredASIDs: [String], allScratchIDs: [UInt32]) async {
        for asid in restoredASIDs where !asid.isEmpty {
            await closeScratchWindow(asid: asid)
        }
        if !restoredASIDs.isEmpty || !allScratchIDs.isEmpty {
            // 没拿到 AS id 的新窗兜底：按 frame 再扫一轮
            let known = Set(restoredASIDs)
            let frames = cgWindowListAll().compactMap { entry -> CGRect? in
                guard allScratchIDs.contains(entry.windowID) else { return nil }
                return entry.bounds
            }
            for asid in await liveASWindowIDs(frames: frames) where !known.contains(asid) {
                await closeScratchWindow(asid: asid)
            }
            if let wdASID = await liveASWindowIDs(frames: [wd.actualFrame].compactMap { $0 }).first {
                _ = await runOsa("tell application id \"com.googlecode.iterm2\" to close window id \(wdASID)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await dismissITermCloseConfirmation()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

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

    /// CG 窗 → 该窗全部 tab 的 tty（tab 序；S-F 多 pane 断言用）
    private func iTermSessionTTYs(windowCGID: UInt32) -> [String] {
        guard let entry = cgWindowListAll().first(where: { $0.windowID == windowCGID }),
              let bounds = entry.bounds else { return [] }
        guard let out = ShellRunner.run(executable: "/usr/bin/osascript",
                                        arguments: ["-e", PaneEnumeration.itermEnumerateSessions()], timeout: 30),
              out.exitCode == 0 else { return [] }
        return PaneEnumeration.parseITermSessions(out.stdout)
            .filter { hypot($0.windowBounds.midX - bounds.midX, $0.windowBounds.midY - bounds.midY) < 40 }
            .sorted { ($0.tabIndex, $0.sessionIndex) < ($1.tabIndex, $1.sessionIndex) }
            .map(\.tty)
    }

    /// 读 iTerm2 窗（frame 就近）当前 session 屏幕文本（命令行回显断言用）
    private func itermWindowContents(frame: CGRect) async -> String {
        guard let asid = await liveASWindowIDs(frames: [frame]).first else { return "" }
        return await runOsa("""
        tell application id "com.googlecode.iterm2"
            tell window id \(asid) to tell current session to get contents
        end tell
        """) ?? ""
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
