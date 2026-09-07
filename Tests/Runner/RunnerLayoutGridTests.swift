import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerLayoutGridTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runLayoutGridTests() {
    // MARK: Rectangle 摆位 + Terminal 网格（feat/rectangle-integration）

    // 摆位几何：半屏恰好对半分、四分恰好四等分、留白语义、居中保持尺寸
    do {
        let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)  // 主屏可视区（扣菜单栏）
        let left = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 0)
        let right = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 0)
        check("摆位: 左右半屏恰好对半分且互补",
              left != nil && right != nil
              && left?.width == visible.width / 2
              && left?.maxX == right?.minX
              && left?.height == visible.height
              && right?.maxX == visible.maxX)

        let top = LayoutFrameCalculator.splitFrame(for: .topHalf, visibleFrame: visible, gap: 0)
        let bottom = LayoutFrameCalculator.splitFrame(for: .bottomHalf, visibleFrame: visible, gap: 0)
        check("摆位: 上下半屏对半分（Quartz y 向下，top 在小 y）",
              top?.minY == visible.minY && bottom?.maxY == visible.maxY
              && top?.maxY == bottom?.minY
              && top?.height == visible.height / 2)

        let tl = LayoutFrameCalculator.splitFrame(for: .topLeftQuarter, visibleFrame: visible, gap: 0)
        let br = LayoutFrameCalculator.splitFrame(for: .bottomRightQuarter, visibleFrame: visible, gap: 0)
        check("摆位: 四分 = 半宽×半高，角落对齐",
              tl?.width == visible.width / 2 && tl?.height == visible.height / 2
              && tl?.minX == visible.minX && tl?.minY == visible.minY
              && br?.maxX == visible.maxX && br?.maxY == visible.maxY)

        let gapLeft = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 8)
        let gapRight = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 8)
        check("摆位: 留白 8 时两半屏不重叠且合计 < 可视区",
              gapLeft != nil && gapRight != nil
              && gapLeft!.maxX < gapRight!.minX
              && gapLeft!.width + gapRight!.width < visible.width)

        let maximize = LayoutFrameCalculator.splitFrame(for: .maximize, visibleFrame: visible, gap: 12)
        check("摆位: maximize = 可视区 inset",
              maximize == visible.insetBy(dx: 12, dy: 12))

        let window = CGRect(x: 100, y: 100, width: 800, height: 500)
        let centered = LayoutFrameCalculator.centeredFrame(windowFrame: window, visibleFrame: visible)
        check("摆位: 居中保持窗口尺寸且中心对齐可视区中心",
              centered.width == 800 && centered.height == 500
              && centered.midX == visible.midX && centered.midY == visible.midY)

        let hugeWindow = CGRect(x: 0, y: 0, width: 9999, height: 9999)
        let clampedCenter = LayoutFrameCalculator.centeredFrame(windowFrame: hugeWindow, visibleFrame: visible)
        check("摆位: 居中超大窗口 clamp 到可视区尺寸",
              clampedCenter.width == visible.width && clampedCenter.height == visible.height)

        check("摆位: center 动作无窗口尺寸入参时返回 nil（走 centeredFrame 专用路径）",
              LayoutFrameCalculator.splitFrame(for: .center, visibleFrame: visible, gap: 0) == nil)
    }

    // Carbon hotkey id 映射：与 1=toggle / 2=title editor 错开，注册/分派两端一致
    do {
        let ids = LayoutAction.allCases.map { $0.carbonHotKeyID }
        check("热键表: 11 个 action id 唯一且 ≥100（不撞 toggle=1/title=2）",
              Set(ids).count == LayoutAction.allCases.count && ids.min()! >= 100)
        check("热键表: id → action 往返一致",
              LayoutAction.allCases.allSatisfy { LayoutAction.action(forCarbonHotKeyID: $0.carbonHotKeyID) == $0 })
        check("热键表: 未注册 id 返回 nil",
              LayoutAction.action(forCarbonHotKeyID: 2) == nil
              && LayoutAction.action(forCarbonHotKeyID: 999) == nil)
    }

    // 默认键位表：全覆盖、无表内重复、不撞已知系统冲突与默认 toggle 键
    do {
        let table = LayoutHotKeyTable.withDefaults
        check("热键表: 默认表覆盖全部 action", table.bindings.count == LayoutAction.allCases.count)
        check("热键表: 默认表无重复组合键", LayoutHotKeyTable.duplicateBinding(in: table) == nil)
        check("热键表: 默认表不与主 toggle 键撞车",
              LayoutHotKeyTable.collidesWithToggleHotKey(table, toggleHotKey: .default) == nil)
        check("热键表: 默认键全部过系统冲突校验（无已知系统快捷键命中）",
              table.bindings.values.allSatisfy { HotKeyManager.validationError(for: $0) == nil })
        // Codable round-trip
        if let data = table.encoded(), let decoded = LayoutHotKeyTable.decode(data) {
            check("热键表: JSON round-trip 一致", decoded == table)
        } else {
            check("热键表: JSON round-trip 一致", false)
        }
    }

    // 共存探测判定核心（零 I/O）
    do {
        let profile = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Finder", "Rectangle"],
            runningBundleIDs: ["com.apple.finder"],
            installedAppNames: ["Rectangle"]
        )
        check("共存: 按应用名识别运行中的 Rectangle", profile.hasRunningConflict
              && profile.runningConflicts.first?.name == "Rectangle")
        check("共存: 摘要非空", profile.conflictSummary?.contains("Rectangle") == true)

        let bundleHit = WindowLayoutManagerProbe.evaluate(
            runningAppNames: [],
            runningBundleIDs: ["com.coredigest.WndManager"],
            installedAppNames: []
        )
        check("共存: 按 bundleID 识别运行中的 Magnet", bundleHit.hasRunningConflict
              && bundleHit.runningConflicts.first?.name == "Magnet")

        let clean = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Finder", "yabai"],
            runningBundleIDs: [],
            installedAppNames: []
        )
        check("共存: yabai/Finder 运行不误报（yabai 是增强层非竞品）", !clean.hasRunningConflict)

        let installedOnly = WindowLayoutManagerProbe.evaluate(
            runningAppNames: [],
            runningBundleIDs: [],
            installedAppNames: ["Moom"]
        )
        check("共存: 仅安装未运行 → 记录 installed 不算冲突", !installedOnly.hasRunningConflict
              && installedOnly.candidates.first(where: { $0.name == "Moom" })?.installed == true)
    }

    // 共存策略：运行中 + 未显式选择 → 自动停用；显式选择后不再改
    do {
        let running = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Rectangle"], runningBundleIDs: [], installedAppNames: []
        )
        let savedChoice = LayoutPreferences.coexistenceChoice
        let savedEnabled = LayoutPreferences.isEnabled
        defer {
            LayoutPreferences.coexistenceChoice = savedChoice
            LayoutPreferences.isEnabled = savedEnabled
        }
        LayoutPreferences.coexistenceChoice = .unspecified
        LayoutPreferences.isEnabled = true
        _ = WindowLayoutManagerProbe.applyCoexistencePolicy(profile: running)
        check("共存: 竞品运行 + unspecified → 自动停用摆位热键", !LayoutPreferences.isEnabled)

        LayoutPreferences.isEnabled = true
        LayoutPreferences.coexistenceChoice = .enableAnyway
        _ = WindowLayoutManagerProbe.applyCoexistencePolicy(profile: running)
        check("共存: 用户显式选择启用后不再自动改", LayoutPreferences.isEnabled)
    }

    // 终端网格规划：格子数、互补、gap、捕获反推行列、clamp
    do {
        let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)
        let cells22 = TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 2, cols: 2, gap: 8))
        check("网格: 2×2 出 4 格且尺寸一致",
              cells22.count == 4
              && Set(cells22.map { $0.width }).count == 1
              && Set(cells22.map { $0.height }).count == 1)
        check("网格: 2×2 行列对齐（同列同 x、同行同 y）",
              cells22[0].minX == cells22[2].minX && cells22[0].minY == cells22[1].minY
              && cells22[0].maxY <= cells22[2].minY && cells22[0].maxX <= cells22[1].minX)
        check("网格: 行列越界拒绝",
              TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 5, cols: 2, gap: 8)).isEmpty
              && TerminalGridPlanner.cells(visibleFrame: visible, spec: .init(rows: 0, cols: 2, gap: 8)).isEmpty)

        let laid = [
            CGRect(x: 0, y: 25, width: 860, height: 542),
            CGRect(x: 868, y: 25, width: 860, height: 542),
            CGRect(x: 0, y: 575, width: 860, height: 542),
            CGRect(x: 868, y: 575, width: 860, height: 542)
        ]
        let inferred = TerminalGridPlanner.inferGrid(from: laid)
        check("网格: 2×2 摆法反推行列 = (2,2)", inferred?.rows == 2 && inferred?.cols == 2)

        let three = Array(laid.dropLast())
        let inferred3 = TerminalGridPlanner.inferGrid(from: three)
        check("网格: 缺右下角的 3 窗摆法反推 = (2,2)", inferred3?.rows == 2 && inferred3?.cols == 2)

        let ordered = TerminalGridPlanner.rowMajorOrder([laid[2], laid[1], laid[0], laid[3]])
        check("网格: rowMajorOrder 按行优先排序", ordered == laid)

        let clamped = TerminalGridPlanner.clampToVisible(
            frame: CGRect(x: -50, y: 0, width: 3000, height: 2000),
            visibleFrame: visible
        )
        check("网格: clamp 越界 frame 进可视区",
              clamped.minX >= visible.minX && clamped.minY >= visible.minY
              && clamped.maxX <= visible.maxX && clamped.maxY <= visible.maxY
              && clamped.width == visible.width && clamped.height == visible.height)
    }

    // AppleScript 生成器：转义 + bounds 换算 + 命令选择
    do {
        let raw = "echo \"hi\" \\ done"
        let escaped = TerminalAutomationScript.appleScriptEscaped(raw)
        let expected = "echo \\\"hi\\\" \\\\ done"
        check("脚本: 引号与反斜杠转义", escaped == expected)

        let frame = CGRect(x: 0, y: 25, width: 860, height: 542)
        let script = TerminalAutomationScript.terminalCreateWindow(command: "claude --resume abc", quartzFrame: frame)
        check("脚本: Terminal 建窗脚本含 do script/等窗轮询/set bounds/return id",
              script.contains("do script \"claude --resume abc\"")
              && script.contains("repeat until (count of windows) > priorWindowCount")
              && script.contains("set bounds of front window to {0, ")
              && script.contains("return id of front window"))

        let noCmd = TerminalAutomationScript.terminalCreateWindow(command: nil, quartzFrame: frame)
        check("脚本: 无命令时 do script 空串（开纯 shell，防命令退出关窗）",
              noCmd.contains("do script \"\"")
              && noCmd.contains("repeat until (count of windows) > priorWindowCount")
              && !noCmd.contains("do script \"do script"))

        let iterm = TerminalAutomationScript.itermCreateWindow(command: "claude", quartzFrame: frame)
        check("脚本: iTerm2 建窗脚本含 write text 与 set bounds",
              iterm.contains("write text \"claude\"") && iterm.contains("set bounds of current window"))

        check("脚本: 有 session 时恢复命令为 claude --resume",
              TerminalAutomationScript.cellCommand(sessionID: "sess-1", cwd: nil, launchCommand: "claude") == "claude --resume sess-1")
        check("脚本: 无 session 时回落启动命令",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: nil, launchCommand: "claude") == "claude")
        check("脚本: 两者皆无 → nil（纯 shell）",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: nil, launchCommand: nil) == nil)
        check("脚本: cwd 层——cd + resume 组合",
              TerminalAutomationScript.cellCommand(sessionID: "s1", cwd: "/Users/x/My Dir", launchCommand: nil)
              == "cd '/Users/x/My Dir' && claude --resume s1")
        check("脚本: cwd 单引号 POSIX 转义",
              TerminalAutomationScript.shellQuoted("it's here") == "'it'\\''s here'")
        check("脚本: 纯 shell 格子只 cd",
              TerminalAutomationScript.cellCommand(sessionID: nil, cwd: "/tmp", launchCommand: nil) == "cd '/tmp'")
        check("脚本: 注入脚本指向既有窗口",
              TerminalAutomationScript.terminalInjectCommand(windowID: 4131, command: "cd '/tmp'")
              .contains("do script \"cd '/tmp'\" in window id 4131"))
    }

    // Claude session 定位（纯函数部分）
    do {
        check("session: 目录名映射（/ . 空格 → -，字母数字-_ 保留）",
              ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/.local/bin") == "-Users-cc--local-bin"
              && ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/My Dir/x") == "-Users-cc-My-Dir-x")
        check("session: jsonl 文件名 → sessionID",
              ClaudeSessionLocator.sessionID(fromSessionFileName: "5ddcf2ed-be72.jsonl") == "5ddcf2ed-be72"
              && ClaudeSessionLocator.sessionID(fromSessionFileName: "notasession.txt") == nil)
        check("session: claude 进程命令行判定（路径尾部匹配，不误吞含 claude 字样的其它进程）",
              ClaudeSessionLocator.isClaudeProcess(commandLine: "/Users/x/.local/bin/claude --resume abc")
              && ClaudeSessionLocator.isClaudeProcess(commandLine: "claude")
              && !ClaudeSessionLocator.isClaudeProcess(commandLine: "vim notes-about-claude.md"))
    }

    // 自动恢复规划器：建/注入/跳过三态 + 一窗一格去重 + 不支持注入降级
    do {
        let cells = [
            TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 800, height: 500, ttyPath: "/dev/ttys001", sessionID: "s1", cwd: "/a", title: nil),
            TerminalGridCellSnapshot(index: 1, x: 808, y: 0, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        ]
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 500), CGRect(x: 808, y: 0, width: 800, height: 500)]
        let liveClaude = TerminalLiveWindow(windowID: 101, frame: frames[0], ttyPath: "/dev/ttys001", hasLiveClaude: true)
        let liveIdle = TerminalLiveWindow(windowID: 102, frame: CGRect(x: 810, y: 2, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        let actions = TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [liveClaude, liveIdle])
        check("规划器: claude 仍在跑 → skipRunning", actions[0] == .skipRunning)
        check("规划器: 空闲活窗口 → inject 且带窗口 id", actions[1] == .inject(windowID: 102))
        check("规划器: 格位空 → create",
              TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [])
              == [.create, .create])
        let far = TerminalLiveWindow(windowID: 103, frame: CGRect(x: 5000, y: 5000, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        check("规划器: 中心距离超容差不匹配",
              TerminalAutoRestorePlanner.plan(cells: [cells[0]], targetFrames: [frames[0]], liveWindows: [far]) == [.create])
        check("规划器: 不支持注入时匹配到的窗口一律 skipRunning，缺失格仍 create",
              TerminalAutoRestorePlanner.plan(cells: cells, targetFrames: frames, liveWindows: [liveClaude], injectEnabled: false)
              == [.skipRunning, .create])
        // 两 cell 都想认领同一窗口：第一个赢，第二个 create（used 去重）
        let stacked = [
            TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil),
            TerminalGridCellSnapshot(index: 1, x: 2, y: 2, width: 800, height: 500, ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        ]
        let oneLive = TerminalLiveWindow(windowID: 201, frame: CGRect(x: 0, y: 0, width: 800, height: 500), ttyPath: nil, hasLiveClaude: false)
        check("规划器: 同窗口不被两个格子重复认领",
              TerminalAutoRestorePlanner.plan(cells: stacked, targetFrames: [frames[0], frames[0]], liveWindows: [oneLive])
              == [.inject(windowID: 201), .create])
    }

    // 快照格子数安全护栏（真机事故：604 格污染快照 → autoRestore 新建 539 扇窗）
    check("护栏: 格子数上限 64 的边界判定",
          TerminalGridPlanner.isValidSnapshotCellCount(1)
          && TerminalGridPlanner.isValidSnapshotCellCount(64)
          && !TerminalGridPlanner.isValidSnapshotCellCount(0)
          && !TerminalGridPlanner.isValidSnapshotCellCount(65))

        // MARK: 编排终端选择器（feat/terminal-auto-select，真实源码）

    do {
        let all = [
            TerminalSelectionCandidate(bundleID: "com.apple.Terminal", name: "Terminal.app", support: .full, usageCount: 0, lastUsedAt: nil, isRunning: true),
            TerminalSelectionCandidate(bundleID: "com.googlecode.iterm2", name: "iTerm2", support: .partial, usageCount: 0, lastUsedAt: nil, isRunning: false),
            TerminalSelectionCandidate(bundleID: "dev.warp.Warp-Stable", name: "Warp", support: .none, usageCount: 0, lastUsedAt: nil, isRunning: false)
        ]
        check("选择器: 手动指定优先", TerminalSelectionResolver.resolve(manualBundleID: "com.googlecode.iterm2", candidates: all).bundleID == "com.googlecode.iterm2")
        check("选择器: 手动 partial 支持级别标注正确",
              TerminalSelectionResolver.resolve(manualBundleID: "com.googlecode.iterm2", candidates: all).reason.contains("部分支持"))
        check("选择器: 自动兜底 Terminal.app",
              TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: all).bundleID == "com.apple.Terminal")
        check("选择器: 未知手动目标不空引用",
              TerminalSelectionResolver.resolve(manualBundleID: "com.unknown", candidates: all).bundleID == "com.apple.Terminal")
        check("选择器: 支持面查询（未知终端 → none）",
              TerminalSelectionResolver.supportLevel(forBundleID: "dev.warp.Warp-Stable") == .none
              && TerminalSelectionResolver.supportLevel(forBundleID: "com.apple.Terminal") == .full)
    }

    // MARK: 网格目标偏好 + 间距（真实 UserDefaults 实现）
    // 用户反馈（2026-09-06）：格子间空隙大——根因是 gap 读取 `== 0 ? 8` 把
    // "未设置"与"显式 0"混为一谈，0 永远不生效；编排总落主屏——目标只有
    // 主屏/焦点屏两档。这里锁定新的 target 编码 + 旧键迁移 + gap 语义。
    print("\n=== 网格目标偏好 / 间距 ===")
    do {
        let defaults = UserDefaults.standard
        let keys = [TerminalGridPreferences.targetKey, TerminalGridPreferences.displayModeKey, TerminalGridPreferences.gapKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }

        check("gap: 未设置默认 0（无缝，Rectangle 风格）", TerminalGridPreferences.gap == 0)
        TerminalGridPreferences.gap = 0
        check("gap: 显式 0 持久为 0（不再被强转 8）",
              TerminalGridPreferences.gap == 0 && defaults.object(forKey: TerminalGridPreferences.gapKey) != nil)
        TerminalGridPreferences.gap = 100
        check("gap: 上限 clamp 40", TerminalGridPreferences.gap == 40)
        TerminalGridPreferences.gap = 8
        check("gap: 8 正常读回", TerminalGridPreferences.gap == 8)

        check("target: 默认 main", TerminalGridPreferences.target == "main")
        defaults.set("focused", forKey: TerminalGridPreferences.displayModeKey)
        check("target: 旧 displayMode=focused 自动迁移", TerminalGridPreferences.target == "focused")
        TerminalGridPreferences.target = "d123s4"
        check("target: 显式写入优先于旧键", TerminalGridPreferences.target == "d123s4")
        check("target: 写入值可解析为 displaySpace",
              GridTargetCode.parse(TerminalGridPreferences.target) == .displaySpace(displayID: 123, spaceIndex: 4))
        defaults.set("garbage", forKey: TerminalGridPreferences.targetKey)
        check("target: 非法值回落到旧键迁移结果", TerminalGridPreferences.target == "focused")

        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    }
}
