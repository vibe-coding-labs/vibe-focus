import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionRestoreExecutorSeamTests.swift
// 靶：SessionRestoreExecutor.restore 全链编排——实例守卫放行、环境真值采集、
// 活窗观测（iTerm/Terminal pane 枚举 + tty 分类）、create 分组切视角与附加 pane、
// 跨 Space 投递（直落 / 泊靠写回 / AX 未就绪跳过）、活窗注入四形态、归还原视角、
// 汇总记账（送达/注入失败计数）。
// 纪律：全部宿主依赖经 SessionRestoreEnvironment 注入——零建窗、零 AppleEvent、
// 零真实等待（虚拟时钟 + 零延迟睡眠）。

/// 用例状态盒（闭包共享可变状态；单线程 MainActor 驱动）
final class RestoreSeamState: @unchecked Sendable {
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    var focusCalls: [Int] = []
    var createCalls: [(app: String, command: String?, frame: CGRect, excluding: Set<UInt32>)] = []
    var yabaiCalls: [[String]] = []
    /// `env.runYabai` 收到的 operation 标签（A15~A17 断言合发写回与泊靠的归因串）。
    /// 只覆盖 runYabai 通道——setWindowFloat 走独立闭包，不并入本表。
    var yabaiOperations: [String] = []
    var scripts: [String] = []
    var windowSpace: [UInt32: Int] = [:]
    var windowDisplay: [UInt32: Int] = [:]
    var manageable: Set<UInt32> = []
    var queryCount: [UInt32: Int] = [:]
    var createResults: [(UInt32?, String?)] = []
    var spaceQueryCount = 0
}

extension RunnerHarness {
    func runSessionRestoreExecutorSeamTests() {
        guard let screen = NSScreen.screens.first else {
            check("srSeam A0: 无 NSScreen 环境（CI 正常有虚拟屏），跳过实屏映射用例", true)
            return
        }
        let state = RestoreSeamState()

        // MARK: 快照（7 窗：2 create@space2 + 1 create@space3 + 3 inject + 2 skipAlive）
        func win(_ bundle: String, _ x: CGFloat, space: Int?, panes: [SessionPaneSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                appBundleID: bundle,
                frame: CGRect(x: x, y: 0, width: 800, height: 600),
                displayID: 1, yabaiDisplay: 1, yabaiSpace: space,
                title: nil, wasMinimized: false, panes: panes)
        }
        let iterm = "com.googlecode.iterm2"
        let term = "com.apple.Terminal"
        let claudePane = SessionPaneSnapshot(kind: .localClaude, sessionID: "abc-123", cwd: "/tmp/a")
        let shellPaneB = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/b")
        let shellPaneC = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/c")
        let shellPaneD = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/d")
        let snapshot = SessionRestoreSnapshot(
            id: "ut-seam", name: "seam",
            windows: [
                win(iterm, 0, space: 2, panes: [claudePane, shellPaneB, shellPaneC]),
                win(term, 1000, space: 2, panes: [shellPaneD]),
                win(iterm, 2000, space: 2, panes: [shellPaneB, shellPaneC]),
                win(term, 3000, space: 2, panes: [shellPaneD]),
                win(iterm, 4000, space: 2, panes: [shellPaneB]),
                win(iterm, 5000, space: 2, panes: [shellPaneB]),
                win(term, 6000, space: 2, panes: [shellPaneD]),
                win(iterm, 7000, space: 3, panes: [shellPaneB]),
            ],
            launchCommand: nil)

        // MARK: 注入环境
        var env = SessionRestoreEnvironment()
        env.automationInstanceRefusal = { _, _ in nil }
        env.ensureTerminalRunning = { _, _ in true }
        env.screens = { [screen] }
        env.exactYabaiDisplayIndex = { _ in 1 }
        env.cgDisplayID = { _ in 1 }
        env.primaryDisplayID = { 1 }
        env.querySpaces = {
            state.spaceQueryCount += 1
            switch state.spaceQueryCount {
            case 1:
                // 采集：display 1 当前可见 space 1；目标 space 2/3 均隐藏
                return [
                    YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true),
                    YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: false),
                    YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
                ]
            case 2:
                // settle(space 2)：切视角后可见 → 立即命中
                return [
                    YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: true),
                    YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
                ]
            default:
                // settle(space 3)：始终不可见 → 走满预算超时
                return [
                    YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: true),
                    YabaiSpaceInfo(id: 3, index: 3, display: 1, isVisible: false),
                ]
            }
        }
        env.focusSpace = { space, _ in
            switch space {
            case .yabaiIndex(let index):
                state.focusCalls.append(index)
            case .nativeID:
                break
            }
            return true
        }
        env.createTerminalCell = { app, command, frame, _, excluding in
            state.createCalls.append((app, command, frame, excluding))
            let next: (UInt32?, String?) = state.createResults.isEmpty
                ? (nil, nil)
                : state.createResults.removeFirst()
            return (cgWindowID: next.0, corrected: false, appleScriptID: next.1)
        }
        env.queryWindow = { id in
            state.queryCount[id, default: 0] += 1
            var space = state.windowSpace[id] ?? 1
            if id == 9002, state.queryCount[id, default: 0] >= 3 { space = 2 }
            return YabaiWindowInfo(
                id: Int(id), pid: 1, app: "iTerm2", title: nil,
                space: space, display: state.windowDisplay[id] ?? 1,
                frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 100, h: 100),
                isFloatingRaw: false,
                hasAXReferenceRaw: state.manageable.contains(id))
        }
        env.setWindowFloat = { id, _ in state.yabaiCalls.append(["--float", String(id)]) }
        env.parkingScreen = { _ in NSScreen.screens.first }
        env.quartzVisibleFrame = { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) }
        env.runYabai = { args, operation, _ in
            state.yabaiCalls.append(args)
            state.yabaiOperations.append(operation)
        }
        env.sleepNanos = { nanos in
            state.clock = state.clock.addingTimeInterval(Double(nanos) / 1_000_000_000)
        }
        env.now = { state.clock }
        env.runAppleScript = { script in
            state.scripts.append(script)
            // 两个枚举脚本都含 "repeat with w in windows" 与 "repeat with t in tabs of w"，
            // 必须用各自独有的字段访问区分——否则 Terminal 枚举会吃到 iTerm 会话行，
            // parseTerminalTabTTYs 因首列非数字整行丢弃，Terminal 窗被判无 pane（CI 实测假红）。
            if script.contains("sessions of t") {
                // iTerm2 枚举：502 与 505 各匹配 2/1 个 session；504 故意不匹配
                return """
                asid-502|1|1|/dev/ttys010|2000,0,2800,600|tab-a
                asid-502|1|2|/dev/ttys011|2000,0,2800,600|tab-b
                asid-505|1|1|/dev/ttys020|5000,0,5800,600|busy
                """
            }
            if script.contains("tty of t") {
                // Terminal 枚举：503 两 tab；506 一个 tty
                return "503|/dev/ttys001\n503|/dev/ttys002\n506|/dev/ttys003"
            }
            if script.contains("do script") {
                // Terminal 注入：模拟脚本失败（计入注入失败）
                return nil
            }
            return "ok"
        }

        // 活窗观测：iTerm 502/504/505 + Terminal 503/506 + Safari 噪音窗
        // yabai 的 app 字段是显示名（"iTerm2"/"Terminal"），
        // observeLiveWindows 以此判定是否需要跑对应 AppleScript 枚举——填 bundle id 会让
        // 枚举分支直接跳过，pane 坐标缺失使会话级注入退化为窗口级（CI 实测假红来源）。
        let liveApps: [(UInt32, String, CGFloat, Int?)] = [
            (502, "iTerm2", 2000, 1111),
            (503, "Terminal", 3000, 1112),
            (504, "iTerm2", 4000, 1113),
            (505, "iTerm2", 5000, 1114),
            (506, "Terminal", 6000, 1115),
            (507, "Safari", 9000, 1116),
        ]
        env.queryAllWindows = {
            liveApps.map { id, app, x, pid in
                YabaiWindowInfo(
                    id: Int(id), pid: pid, app: app, title: "t",
                    space: 2, display: 1,
                    frame: YabaiWindowInfo.Frame(x: Double(x), y: 0, w: 800, h: 600),
                    isFloatingRaw: false, hasAXReferenceRaw: true)
            }
        }
        env.bundleIdentifierOfPID = { pid in
            pid == 1116 ? "com.apple.Safari" : (pid == 1112 || pid == 1115 ? term : iterm)
        }
        env.classifyTTY = { tty in
            if tty.contains("ttys003") {
                return PaneClassifier.Classification(kind: .remoteSSH, pid: 9001,
                                                     sshCommand: "ssh user@host", sshTarget: "user@host")
            }
            if tty.contains("ttys020") {
                return PaneClassifier.Classification(kind: .localClaude, pid: 9002,
                                                     sshCommand: nil, sshTarget: nil)
            }
            return PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil)
        }

        // create 返回：9001 iTerm 带 ASID / 9002 Terminal / 9003 目标 space3（AX 未就绪）
        state.createResults = [(9001, "asid-501"), (9002, nil), (9003, "asid-503")]
        state.windowSpace = [9001: 2, 9002: 5, 9003: 5]
        state.windowDisplay = [9001: 1, 9002: 1, 9003: 1]
        state.manageable = [9002]

        let dir = NSTemporaryDirectory() + "ut-seam-restore-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/seam.db"))
        let controller = SessionRestoreController(store: store)
        let executor = SessionRestoreExecutor(controller: controller, environment: env)

        let result = runRestoreSeamAsync { await executor.restore(snapshot: snapshot) }

        check("srSeam A0: restore 返回 ok（全链跑完）", result?.ok == true)
        check("srSeam A1: 新建 3 窗（两组 create 全建）", state.createCalls.count == 3)
        check("srSeam A2: 首窗命令带 claude --resume（localClaude pane）",
              state.createCalls.first?.command?.contains("claude --resume abc-123") == true)
        check("srSeam A3: 附加 pane 走 iTerm 追加 tab 脚本",
              state.scripts.contains { $0.contains("create tab with default profile") })
        check("srSeam A4: iTerm 多 pane 用会话坐标注入（tab/session 定位）",
              state.scripts.contains { $0.contains("session 1 of tab 1 of window id") })
        check("srSeam A5: iTerm 活窗按 pane 逐条注入（两条 tab/session 坐标脚本）",
              state.scripts.filter { $0.contains("of window id asid-502") }.count == 2)
        check("srSeam A6: Terminal 注入走 do script in window 语义",
              state.scripts.contains { $0.contains("do script") })
        check("srSeam A7: 切视角逆序归还原可见 space（[2,3] 切 + [1,1] 还原）",
              state.focusCalls == [2, 3, 1, 1])
        check("srSeam A8: 已在对的 space 直落（不 float）",
              !state.yabaiCalls.contains { $0.first == "--float" && $0.last == "9001" })
        check("srSeam A9: 同屏错位走泊靠往返（float + park + 写回合发单条消息）",
              state.yabaiCalls.contains { $0.count > 2 && $0[2] == "9002" && $0.contains("--move") }
              && state.yabaiCalls.contains {
                  $0.count > 2 && $0[2] == "9002" && $0.contains("--move") && $0.contains("--resize")
              })
        check("srSeam A10: AX 未就绪窗跳过投递（计入送达失败）",
              state.yabaiCalls.contains { $0.first == "--float" && $0.last == "9003" } == false)
        let summary = result?.message ?? "nil"
        check("srSeam A11: 汇总消息含新建/注入/跳过三类去处（实际：\(summary)）",
              result?.message.contains("新建 3 窗") == true
              && result?.message.contains("注入 3 窗") == true
              && result?.message.contains("仍活着跳过 2 窗") == true)
        check("srSeam A12: 汇总消息如实记账失败数（1 送达 + 2 注入）（实际：\(summary)）",
              result?.message.contains("1 窗未能送达目标工作区") == true
              && result?.message.contains("2 条注入命令执行失败") == true)
        check("srSeam A13: 活窗观测排除了非终端窗（Safari 不参与匹配）",
              !state.scripts.contains { $0.contains("com.apple.Safari") })
        check("srSeam A14: 虚拟时钟推进未触发真实等待（脚本数有限、流程结束）",
              state.scripts.count < 20)
        // A15/A16（2026-11-23）：写回与泊靠的 operation 标签——日志归因唯一来源，
        // 之前只断言了参数形状、标签写错（例如仍留 move/resize 两条旧串）不会被发现。
        check("srSeam A15: 错位窗的泊靠与合发写回各留一条归因标签",
              state.yabaiOperations.contains { $0.hasPrefix("session-delivery.park(windowID=") }
              && state.yabaiOperations.contains { $0.hasPrefix("session-delivery.writeback.apply(windowID=") })
        let writebackIdx = state.yabaiOperations.firstIndex { $0.hasPrefix("session-delivery.writeback.apply") }
        let parkIdx = state.yabaiOperations.firstIndex { $0.hasPrefix("session-delivery.park") }
        check("srSeam A16: 泊靠先于写回（operator 序与参数序同源）",
              writebackIdx != nil && parkIdx != nil && parkIdx! < writebackIdx!)
        check("srSeam A17: 写回恰一条消息（不再拆 move/resize 两条旧串）",
              state.yabaiOperations.filter { $0.contains("session-delivery.writeback") }.count == 1)

        // MARK: B 段——实例守卫拒绝（零环境采集）
        var refuseEnv = SessionRestoreEnvironment()
        var refusalProbed = 0
        refuseEnv.automationInstanceRefusal = { _, _ in
            refusalProbed += 1
            return "该终端未安装"
        }
        refuseEnv.querySpaces = { state.spaceQueryCount = -999; return nil }
        let refused = runRestoreSeamAsync {
            await SessionRestoreExecutor(controller: controller, environment: refuseEnv).restore(snapshot: snapshot)
        }
        check("srSeam B1: 实例守卫拒绝 → ok=false + 原因透传",
              refused?.ok == false && refused?.message.contains("未安装") == true)
        check("srSeam B2: 守卫拒绝在环境采集之前短路", refusalProbed > 0 && state.spaceQueryCount != -999)

        // MARK: C 段——快照超上限直接拒绝（planner refusal 早退）
        let overflow = SessionRestoreSnapshot(
            id: "ut-overflow", name: "o",
            windows: Array(repeating: win(iterm, 0, space: 2, panes: [shellPaneB]),
                           count: TerminalGridPlanner.maxSnapshotCells + 1),
            launchCommand: nil)
        var quietEnv = SessionRestoreEnvironment()
        quietEnv.automationInstanceRefusal = { _, _ in nil }
        quietEnv.ensureTerminalRunning = { _, _ in true }
        let overflowResult = runRestoreSeamAsync {
            await SessionRestoreExecutor(controller: controller, environment: quietEnv).restore(snapshot: overflow)
        }
        check("srSeam C1: 快照超上限 → ok=false + 窗口风暴文案",
              overflowResult?.ok == false && overflowResult?.message.contains("疑似异常快照") == true)

        // MARK: D 段——活窗枚举失败（yabai 不可用）降级为空观测
        var noYabaiEnv = SessionRestoreEnvironment()
        noYabaiEnv.automationInstanceRefusal = { _, _ in nil }
        noYabaiEnv.ensureTerminalRunning = { _, _ in true }
        noYabaiEnv.screens = { [] }
        noYabaiEnv.querySpaces = { [] }
        noYabaiEnv.primaryDisplayID = { nil }
        noYabaiEnv.queryAllWindows = { nil }
        noYabaiEnv.runAppleScript = { _ in nil }
        noYabaiEnv.sleepNanos = { _ in }
        noYabaiEnv.now = { Date(timeIntervalSince1970: 0) }
        // 无 create 项下发 deliver，固定时钟不会自旋；仍保留显式取值保证可读性。
        noYabaiEnv.createTerminalCell = { _, _, _, _, _ in (nil, false, nil) }
        noYabaiEnv.focusSpace = { _, _ in true }
        let noYabaiSnap = SessionRestoreSnapshot(
            id: "ut-noyabai", name: "n",
            windows: [win(iterm, 0, space: nil, panes: [shellPaneB])],
            launchCommand: nil)
        let noYabaiResult = runRestoreSeamAsync {
            await SessionRestoreExecutor(controller: controller, environment: noYabaiEnv).restore(snapshot: noYabaiSnap)
        }
        check("srSeam D1: 无显示器/无 yabai → 无法安放并明示",
              noYabaiResult?.ok == true && noYabaiResult?.message.contains("无法安放") == true)
    }

    // MARK: - 投递失败臂（2026-11-23 补口）
    //
    // deliver() 的两条失败出口此前零覆盖（现有用例的 queryWindow 恒返回 info、
    // manageable 恒就绪）：
    //   ① queryWindow 返回 nil（窗口已关/查询失败）→ 直接 false；
    //   ② 窗口可管理但写回后 5s 虚拟时钟内从未观测到目标 space → false。
    // 两条都走 SessionRestoreEnvironment 注入缝 + 虚拟时钟，零真实等待零建窗。
    func runSessionRestoreDeliveryFailureTests() {
        guard let screen = NSScreen.screens.first else {
            check("srSeamFail A0: 无屏环境跳过", true)
            return
        }
        let iterm = "com.googlecode.iterm2"
        let shellPane = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/f")
        func window(_ x: CGFloat, space: Int?) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                appBundleID: iterm, frame: CGRect(x: x, y: 0, width: 800, height: 600),
                displayID: 1, yabaiDisplay: 1, yabaiSpace: space,
                title: nil, wasMinimized: false, panes: [shellPane])
        }
        // 两个 create 目标：9001 走「查询返回 nil」，9002 走「可管理但永不落位」
        let snapshot = SessionRestoreSnapshot(
            id: "ut-deliver-fail", name: "f",
            windows: [window(0, space: 2), window(1000, space: 2)],
            launchCommand: nil)

        var env = SessionRestoreEnvironment()
        env.automationInstanceRefusal = { _, _ in nil }
        env.ensureTerminalRunning = { _, _ in true }
        env.screens = { [screen] }
        env.exactYabaiDisplayIndex = { _ in 1 }
        env.cgDisplayID = { _ in 1 }
        env.primaryDisplayID = { 1 }
        env.querySpaces = {
            [YabaiSpaceInfo(id: 2, index: 2, display: 1, isVisible: true)]
        }
        env.focusSpace = { _, _ in true }
        env.setWindowFloat = { _, _ in }
        env.parkingScreen = { _ in NSScreen.screens.first }
        env.quartzVisibleFrame = { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) }
        env.runYabai = { _, _, _ in }
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        env.now = { clock }
        env.sleepNanos = { nanos in clock = clock.addingTimeInterval(Double(nanos) / 1_000_000_000) }
        env.runAppleScript = { _ in "" }
        env.queryAllWindows = { [] }
        env.bundleIdentifierOfPID = { _ in iterm }
        env.classifyTTY = { _ in PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil) }
        var created: [(UInt32?, String?)] = [(9001, "asid-1"), (9002, "asid-2")]
        env.createTerminalCell = { _, _, _, _, _ in
            let next = created.isEmpty ? (nil, nil) : created.removeFirst()
            return (cgWindowID: next.0, corrected: false, appleScriptID: next.1)
        }
        // ① 9001 查询恒 nil；② 9002 可管理但 space 恒不等于目标 2
        env.queryWindow = { id in
            if id == 9001 { return nil }
            return YabaiWindowInfo(
                id: Int(id), pid: 1, app: "iTerm2", title: nil,
                space: 9, display: 1,
                frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 100, h: 100),
                isFloatingRaw: false, hasAXReferenceRaw: true)
        }

        let dir = NSTemporaryDirectory() + "ut-seam-fail-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let controller = SessionRestoreController(
            store: SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/f.db")))
        let result = runRestoreSeamAsync {
            await SessionRestoreExecutor(controller: controller, environment: env)
                .restore(snapshot: snapshot)
        }
        let summary = result?.message ?? "nil"
        check("srSeamFail A1: restore 整体仍 ok（失败只记账不失败）",
              result?.ok == true)
        check("srSeamFail A2: 两窗均计入送达失败（query nil + 永不落位）（实际：\(summary)）",
              summary.contains("2 窗未能送达"))

        // B. Terminal 多 pane 的「附加 pane」分支（2026-11-23 补口）
        // create 批里 iTerm 走 itermAppendTab 已覆盖，但 Terminal 方言走
        // terminalWriteToWindow(windowCGID:) 的附加路径此前零覆盖——现有夹具的
        // Terminal 窗只有一个 pane。给 Terminal 窗两个 pane。
        var termEnv = SessionRestoreEnvironment()
        termEnv.automationInstanceRefusal = { _, _ in nil }
        termEnv.ensureTerminalRunning = { _, _ in true }
        termEnv.screens = { [screen] }
        termEnv.exactYabaiDisplayIndex = { _ in 1 }
        termEnv.cgDisplayID = { _ in 1 }
        termEnv.primaryDisplayID = { 1 }
        termEnv.querySpaces = { [YabaiSpaceInfo(id: 1, index: 1, display: 1, isVisible: true)] }
        termEnv.focusSpace = { _, _ in true }
        termEnv.setWindowFloat = { _, _ in }
        termEnv.parkingScreen = { _ in nil }
        termEnv.quartzVisibleFrame = { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) }
        termEnv.runYabai = { _, _, _ in }
        termEnv.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        termEnv.sleepNanos = { _ in }
        var termScripts: [String] = []
        termEnv.runAppleScript = { script in
            termScripts.append(script)
            return "ok"
        }
        termEnv.queryAllWindows = { [] }
        termEnv.bundleIdentifierOfPID = { _ in "com.apple.Terminal" }
        termEnv.classifyTTY = { _ in
            PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil)
        }
        termEnv.createTerminalCell = { _, _, _, _, _ in
            (cgWindowID: 9501, corrected: false, appleScriptID: "term-501")
        }
        termEnv.queryWindow = { id in
            YabaiWindowInfo(
                id: Int(id), pid: 1, app: "Terminal", title: nil, space: 1, display: 1,
                frame: YabaiWindowInfo.Frame(x: 0, y: 0, w: 100, h: 100),
                isFloatingRaw: false, hasAXReferenceRaw: true)
        }
        let termPaneA = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/a")
        let termPaneB = SessionPaneSnapshot(kind: .shell, cwd: "/tmp/b")
        let termSnap = SessionRestoreSnapshot(
            id: "ut-term-multipane", name: "t",
            windows: [SessionWindowSnapshot(
                appBundleID: "com.apple.Terminal",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                displayID: 1, yabaiDisplay: 1, yabaiSpace: 1,
                title: nil, wasMinimized: false, panes: [termPaneA, termPaneB])],
            launchCommand: nil)
        let dirB = NSTemporaryDirectory() + "ut-seam-term-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dirB) }
        let termController = SessionRestoreController(
            store: SessionRestoreStore(store: WindowStateStore(dbPath: dirB + "/t.db")))
        let termResult = runRestoreSeamAsync {
            await SessionRestoreExecutor(controller: termController, environment: termEnv)
                .restore(snapshot: termSnap)
        }
        check("srSeamFail B1: Terminal 多 pane 建窗成功", termResult?.ok == true)
        check("srSeamFail B2: 附加 pane 走 Terminal 方言 do script in window",
              termScripts.contains { $0.contains("do script") && $0.contains("window id 9501") })
    }

    /// MainActor 异步桥接（Task + 短片泵主 RunLoop，30s 死线）
    private func runRestoreSeamAsync<T: Sendable>(
        _ block: @escaping @MainActor () async -> T
    ) -> T? {
        let box = OverlayAsyncResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }
}
