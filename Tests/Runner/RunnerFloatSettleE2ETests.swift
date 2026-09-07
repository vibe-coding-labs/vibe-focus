import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerFloatSettleE2ETests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runFloatSettleE2E() {
    // MARK: FloatSettle 序列原语真机 E2E（仅 VIBEFOCUS_FLOATSETTLE_E2E=1 时运行）
    // 全链路无 AX 依赖（yabai fork + CGWindowList + 内存缓存）——无辅助功能授权环境
    // 可闭环（2026-09-06 AX 授权反复被并行构建毒化期间的质量门底座）。
    //   Case 1 managed 窗 → 真 toggle：didToggle + isFloating 翻转 + 落定有界（<2s）
    //          + 等待后 frame 两读稳定（重摆确实落定，后续 frame 写不再被覆盖）；
    //   Case 2 已 float 窗再跑 → skippedNoOp：didToggle=false 且近零耗时（restore
    //          常见路径零浪费的实机证据）。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_FLOATSETTLE_E2E"] == "1" {
        print("\n=== FloatSettle 序列原语真机 E2E ===")
        SpaceController.shared.refreshAvailability(force: true)
        check("FloatSettleE2E: yabai 可用", SpaceController.shared.isEnabled)

        func yabaiWindowIDsFS() -> Set<UInt32> {
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
        func isFloatingFS(_ id: UInt32) -> Bool? {
            SpaceController.shared.queryWindow(windowID: id, ignoreCache: true)?.isFloating
        }

        let fsIdsBefore = yabaiWindowIDsFS()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 0.8)
        let fsCreated = yabaiWindowIDsFS().subtracting(fsIdsBefore)
        guard let fsWid = fsCreated.first else {
            check("FloatSettleE2E: 创建测试窗口", false)
            exit(1)
        }
        check("FloatSettleE2E: 测试窗口已创建 id=\(fsWid)", true)

        // 前置：确保 managed（若 yabai 配置 float 了 iTerm2 新窗，先拨回 tiled）
        if isFloatingFS(fsWid) == true {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(fsWid)", "--toggle", "float"],
                operation: "floatsettle-e2e.pretile", operationID: "floatsettle-e2e")
            Thread.sleep(forTimeInterval: 0.4)
        }
        check("FloatSettleE2E: 前置窗口为 managed（tiled）", isFloatingFS(fsWid) == false)

        // Case 1：真 toggle（真实等待，不注入 sleep）
        let fsT1 = Date()
        let outcome1 = FloatSettle.floatAndSettle(
            windowID: fsWid,
            operationID: "floatsettle-e2e-1",
            knownWindowInfo: nil,
            tolerance: 20,
            setFloat: { SpaceController.shared.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
            read: { cgWindowBounds(for: $0) },
            clearCache: { SpaceController.shared.clearWindowQueryCache() }
        )
        let ms1 = Int(Date().timeIntervalSince(fsT1) * 1000)
        check("FloatSettleE2E Case1: didToggle=true", outcome1.didToggle)
        check("FloatSettleE2E Case1: yabai 侧 isFloating 已翻转", isFloatingFS(fsWid) == true)
        check("FloatSettleE2E Case1: 落定等待有界（\(ms1)ms < 2000）", ms1 < 2000)
        if let f1 = cgWindowBounds(for: fsWid) {
            Thread.sleep(forTimeInterval: 0.05)
            let f2 = cgWindowBounds(for: fsWid)
            check("FloatSettleE2E Case1: 等待后 frame 两读稳定（重摆已落定）",
                  f2.map { CoordinateKit.isFrameConverged(actual: $0, target: f1, tolerance: 20) } == true)
        } else {
            check("FloatSettleE2E Case1: 读取 frame", false)
        }
        print("    [诊断] Case1 outcome=\(outcome1) 外部计时=\(ms1)ms")

        // Case 2：已 float 再跑 → skippedNoOp 零浪费
        let outcome2 = FloatSettle.floatAndSettle(
            windowID: fsWid,
            operationID: "floatsettle-e2e-2",
            knownWindowInfo: nil,
            tolerance: 20,
            setFloat: { SpaceController.shared.setWindowFloat($0, operationID: $1, knownWindowInfo: $2) },
            read: { cgWindowBounds(for: $0) },
            clearCache: { SpaceController.shared.clearWindowQueryCache() }
        )
        check("FloatSettleE2E Case2: 已 float → didToggle=false", !outcome2.didToggle)
        check("FloatSettleE2E Case2: 近零耗时（\(outcome2.durationMs)ms < 100）", outcome2.durationMs < 100)
        print("    [诊断] Case2 outcome=\(outcome2)")

        // 清理：向测试窗口 session 写 exit 关窗（best-effort，同 SizeE2E）。
        // 注意：新建即 exit 会触发 iTerm2「session ended very soon」警告框（需手动
        // 点 OK），窗口关闭可能滞后——清理非本原语契约，残余窗口如实报告不判 FAIL。
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to tell window id \(fsWid) to tell current session to write text \"exit\""], timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let fsLeftover = yabaiWindowIDsFS().intersection(fsCreated)
        if fsLeftover.isEmpty {
            check("FloatSettleE2E: 测试窗口已关闭", true)
        } else {
            print("    [诊断] 关窗滞后（iTerm2 警告框/后台处理），请手动关闭：\(fsLeftover.sorted())")
        }
    }

        // MARK: Terminal 网格真机 E2E（仅 VIBEFOCUS_GRID_E2E=1 时运行）
    // 会真实创建 Terminal 窗口、调用 osascript/yabai/claude，普通门禁不跑。
    // 前置：主屏上有若干终端窗口；其中某窗口的 tty 上有存活 claude 会话。
    if ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E"] == "1" {
        print("\n=== Terminal 网格真机 E2E ===")
        func isTmpPath(_ path: String?) -> Bool { path == "/tmp" || path == "/private/tmp" }
        // 编排目标可用 VIBEFOCUS_GRID_E2E_APP 覆盖：terminal（默认，断言含
        // tty/session——依赖 Terminal.app 特性）/ iterm2 / auto（走真实选择器，
        // 按使用量表解析，解析结果决定断言集）。
        let e2eApp = ProcessInfo.processInfo.environment["VIBEFOCUS_GRID_E2E_APP"] ?? "terminal"
        var isTerminalApp = e2eApp != "iterm2"
        switch e2eApp {
        case "iterm2": TerminalGridPreferences.appPreference = .iterm2
        case "terminal": TerminalGridPreferences.appPreference = .terminal
        case "auto": TerminalGridPreferences.appPreference = .auto
        default: break
        }
        TerminalGridPreferences.target = GridTargetCode.main.code
        TerminalGridPreferences.rows = 2
        TerminalGridPreferences.cols = 2
        TerminalGridPreferences.launchCommand = ""

        let e2eController = TerminalGridController.shared
        // auto 模式断言：使用量表（Terminal 1 次 vs iTerm2 更高）应解析出 iTerm2；
        // 解析出的 app 决定 isTerminalApp（tty/session 断言只对 Terminal 有意义）
        var resolvedSelection: TerminalSelection?
        var createResult: TerminalGridController.OperationResult?
        var captureResult: TerminalGridController.OperationResult?
        var capturedSnapshot: TerminalGridSnapshot?
        var autoRestoreResult: TerminalGridController.OperationResult?
        var restoreResult: TerminalGridController.OperationResult?
        var windowCountAfterRestore = 0
        // 自动恢复联动断言数据
        var claudePIDBefore: Int32?
        var claudePIDAfter: Int32?
        var sessionCellE2ERef: String?
        var tmpCellCWD: String?
        var gridTmpWindowID: UInt32?
        var recreatedShellCWD: String?
        var gridSnapCellCount = 0
        var gridSnapAppBundleID: String?
        let e2eSem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            // 阶段 1：解析编排目标（auto 模式走真实选择器）并创建网格
            // harness 是无 bundle id 的 CLI，UserDefaults.standard 域与 App 不同
            // （App 的历史用量读不到）——种子化用量，模拟「iTerm2 是最常用」
            TerminalUsageTracker.shared.seedUsage(
                bundleID: "com.googlecode.iterm2", count: 49, lastAt: Date())
            TerminalUsageTracker.shared.seedUsage(
                bundleID: "com.apple.Terminal", count: 1, lastAt: Date().addingTimeInterval(-3600))
            resolvedSelection = e2eController.selectionPreview()
            isTerminalApp = resolvedSelection?.bundleID == "com.apple.Terminal"
            createResult = await e2eController.createGrid()
            guard createResult?.ok == true else { e2eSem.signal(); return }
            // 阶段 2：在网格格子里现场构造多源上下文
            //   cell0 → claude（活会话）；cell1 → cd /tmp（非平凡目录）
            //   自动恢复阶段改用「网格快照」（4 格、格位唯一）——桌面级捕获在
            //   多轮叠窗后 frame 匹配不可靠（实测教训），网格快照无此问题。
            let gridSnapshot = e2eController.snapshotsForRefresh().last
            guard let gridSnap = gridSnapshot, gridSnap.cells.count == 4 else { e2eSem.signal(); return }
            gridSnapCellCount = gridSnap.cells.count
            gridSnapAppBundleID = gridSnap.appBundleID
            let enumScript = TerminalAutomationScript.terminalEnumerateWindowTTYs()
            let enumerateTTYMap = { (script: String) -> [UInt32: String] in
                guard let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 30),
                      out.exitCode == 0 else { return [:] }
                var map: [UInt32: String] = [:]
                for line in out.stdout.split(separator: "\n") {
                    let parts = line.split(separator: "|", maxSplits: 1)
                    guard parts.count == 2, let id = UInt32(parts[0]) else { continue }
                    var tty = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
                    map[id] = tty
                }
                return map
            }
            let ttyMapNow = enumerateTTYMap(enumScript)
            func windowID(forTTY tty: String?) -> UInt32? {
                guard let tty else { return nil }
                return ttyMapNow.first { $0.value == tty }?.key
            }

            // cell0: 启动 claude 并发一条消息，产生活的 session。
            // 信任对话框自动应答：首次在目录启动会弹 "Do you trust this folder"，
            // ESC[B(↓) + Return 选中 "Yes, I trust this folder"（pty 直接写，免焦点）。
            let sessionMarkerDate = Date().addingTimeInterval(-5)
            let markerFormatter = DateFormatter()
            markerFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let markerStr = markerFormatter.string(from: sessionMarkerDate)
            if isTerminalApp, let c0 = gridSnap.cells.first, let wid = windowID(forTTY: c0.ttyPath) {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "claude")], timeout: 30)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to do script (character id 27 & \"[B\") in window id \(wid)"], timeout: 30)
                try? await Task.sleep(nanoseconds: 500_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to do script \"\" in window id \(wid)"], timeout: 30)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "hi")], timeout: 30)
                // 等待【本轮】session jsonl 落盘（≤40s；-newermt 锚定启动时刻，
                // 避免 find -mmin 命中自身/他人会话文件导致假等待通过）
                let deadline = Date().addingTimeInterval(40)
                while Date() < deadline {
                    if let out = ShellRunner.run(executable: "/usr/bin/find", arguments:
                        [NSHomeDirectory() + "/.claude/projects", "-name", "*.jsonl", "-newermt", markerStr]),
                       out.exitCode == 0, !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            // cell1: shell cd 到 /tmp
            if let c1 = gridSnap.cells.dropFirst().first, let wid = windowID(forTTY: c1.ttyPath) {
                gridTmpWindowID = wid
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    TerminalAutomationScript.terminalInjectCommand(windowID: wid, command: "cd /tmp")])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // 阶段 3：捕获桌面——仅在 Terminal.app 目标时执行（iTerm2 无 tty，
            // session/cwd 捕获降级；且污染桌面上 64 格护栏会正确拒绝捕获）
            if isTerminalApp {
                captureResult = await e2eController.captureLayout(name: "E2E 捕获")
                capturedSnapshot = e2eController.snapshotsForRefresh().last { $0.name == "E2E 捕获" }
            }
            // auto 模式：用 createGrid 自产的 4 格网格快照驱动恢复（无桌面依赖）
            let capSnap = capturedSnapshot ?? gridSnap
            // 会话/目录断言基于网格格子在桌面快照中的对应条目（按 tty 关联）
            // 多个格子 ttyPath 可同为 nil（无法枚举 tty 的窗），uniquing 防崩溃
            let capByTTY = Dictionary(capSnap.cells.map { ($0.ttyPath, $0) },
                                      uniquingKeysWith: { first, _ in first })
            let gridCell0TTY = gridSnap.cells.first?.ttyPath
            let gridCell1TTY = gridSnap.cells.dropFirst().first?.ttyPath
            sessionCellE2ERef = capByTTY[gridCell0TTY ?? ""]?.sessionID
            tmpCellCWD = capByTTY[gridCell1TTY ?? ""]?.cwd

            if let wid = gridTmpWindowID {
                _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                    "tell application id \"com.apple.Terminal\" to close window id \(wid)"])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            // 阶段 4：自动恢复（用桌面捕获快照——cwd/session 数据都在这份；
            // 干净桌面无叠窗，frame 匹配确定）
            if let claudeTTY = gridCell0TTY {
                claudePIDBefore = ClaudeSessionLocator.claudePID(onTTY: claudeTTY)
            }
            autoRestoreResult = await e2eController.autoRestore(snapshot: capSnap)
            if let claudeTTY = gridCell0TTY {
                claudePIDAfter = ClaudeSessionLocator.claudePID(onTTY: claudeTTY)
            }
            // 找 cell1 格位上的 shell：并行会话在同一格位也可能有窗（同帧碰撞），
            // 语义为「该格位上存在一个 shell 处于记录 cwd」——扫描全部命中窗，
            // 任一 cwd 命中即通过。
            if let frame = gridSnap.cells.dropFirst().first?.frame {
                let map2 = enumerateTTYMap(enumScript)
                for (wid, tty) in map2 {
                    guard wid != gridTmpWindowID,
                          let boundsOut = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                          TerminalAutomationScript.terminalGetBounds(windowID: wid)], timeout: 30),
                          boundsOut.exitCode == 0,
                          let b = TerminalAutomationScript.parseBounds(boundsOut.stdout) else { continue }
                    if hypot(b.midX - frame.midX, b.midY - frame.midY) <= 30 {
                        if isTmpPath(ClaudeSessionLocator.shellWorkingDirectory(onTTY: tty)) {
                            recreatedShellCWD = "/tmp"
                            break
                        }
                    }
                }
            }

            // 阶段 5：手动恢复（cell0 注入 claude --resume）
            restoreResult = await e2eController.restoreLayout(snapshotID: capSnap.id)
            let countApp = resolvedSelection?.bundleID ?? "com.apple.Terminal"
            // 直接 osascript（不经 bash -c 转义层）， applescript 双引号在 Swift 串里转义
            if let out = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
                "tell application id \"\(countApp)\" to count windows"], timeout: 30) {
                windowCountAfterRestore = Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            e2eSem.signal()
        }
        // 泵主 runloop 等 MainActor 任务完成（assumeIsolated 域内不能直接阻塞等待）
        while e2eSem.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        check("E2E: 创建 2×2 网格成功", createResult?.ok == true)
        print("    [诊断] resolvedSelection: \(resolvedSelection.map { "\($0.bundleID) / \($0.source) / \($0.reason)" } ?? "nil")")
        print("    [诊断] tracker table: \(TerminalUsageTracker.shared.table.entries)")
        if e2eApp == "auto" {
            check("E2E(auto): 解析出编排目标 iTerm2（本机最常用）",
                  resolvedSelection?.source == .autoByUsage
                  && resolvedSelection?.bundleID == "com.googlecode.iterm2")
            check("E2E(auto): 创建的窗口确实是 iTerm2（网格快照 appBundleID 一致）",
                  gridSnapAppBundleID == "com.googlecode.iterm2")
        }
        check("E2E: 捕获布局成功", !isTerminalApp || captureResult?.ok == true)
        let e2eCells = capturedSnapshot?.cells ?? []
        check("E2E: 快照含 ≥6 个终端窗口", !isTerminalApp || e2eCells.count >= 6)
        let ttyBackfilled = e2eCells.filter { $0.ttyPath != nil }.count
        check("E2E: Terminal.app tty 回填 ≥4 格", !isTerminalApp || ttyBackfilled >= 4)
        check("E2E: TTY 兜底定位到存活 claude 会话", !isTerminalApp || sessionCellE2ERef != nil)
        // iTerm2 无 tty 通道，纯 shell 格子的 cwd 捕获结构性不可用（已知降级）
        check("E2E: 纯 shell 格子的 cwd 被捕获为 /tmp（login shell 名匹配）",
              !isTerminalApp || isTmpPath(tmpCellCWD))
        check("E2E: 自动恢复执行成功", autoRestoreResult?.ok == true)
        check("E2E: 跳过运行中的 claude（skipRunning，pid 不变）",
              !isTerminalApp || (claudePIDBefore != nil && claudePIDBefore == claudePIDAfter))
        check("E2E: 关闭的格子被重建（新窗口出现）", !isTerminalApp || recreatedShellCWD != nil)
        check("E2E: 重建格子的 shell cwd == 快照记录的 /tmp（cwd 恢复链路）", !isTerminalApp || isTmpPath(recreatedShellCWD))
        check("E2E: 恢复布局成功（含 claude --resume 注入）", restoreResult?.ok == true)
        check("E2E: 恢复后窗口数 ≥ 快照格子数", windowCountAfterRestore >= gridSnapCellCount)
        // 验证 --resume 进程真的起来了（重建的 cell0 里 claude --resume <session>）
        var resumeProcessSeen = false
        if let sessionID = sessionCellE2ERef {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                if let out = ShellRunner.run(executable: "/usr/bin/pgrep", arguments: ["-fl", "claude --resume \(sessionID)"]),
                   out.exitCode == 0, !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resumeProcessSeen = true
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        check("E2E: 检测到 claude --resume <session> 进程", !isTerminalApp || resumeProcessSeen)
    }
    }
}
