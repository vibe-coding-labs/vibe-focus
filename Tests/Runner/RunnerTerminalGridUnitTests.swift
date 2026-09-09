import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalGridUnitTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runTerminalGridUnitTests() {
    // MARK: TerminalGrid 拆分单元（真实实现——2026-09-07 拆分批次：tty 解析/捕获排序/恢复帧规划）

    do {
        // ===== parseWindowTTYMap：逐行解析 windowID|tty（分支穷尽） =====
        let parsed = TerminalAutomationScript.parseWindowTTYMap("""
        12|/dev/ttys001
        bad-line-without-pipe
        xx|/dev/ttys002
          33  |  ttys003
        44|weird|path
        4294967296|/dev/ttys005

        """)
        check("ttyMap: 正常行解析", parsed[12] == "/dev/ttys001")
        check("ttyMap: 非 UInt32 id（含空白 id）行跳过", parsed[UInt32(33)] == nil && parsed.count == 2)
        check("ttyMap: 空白容忍只对 tty 侧（id 严格解析）", parsed[12] != nil && parsed[44] != nil)
        check("ttyMap: 首个 | 之后的 | 不撕列", parsed[44] == "/dev/weird|path")
        check("ttyMap: 空输入 → 空 Map", TerminalAutomationScript.parseWindowTTYMap("").isEmpty)

        // ===== sortedByReadingOrder：行带分组阅读序（分支穷尽） =====
        // 复用 CGWindowEntry(from:) 的 dict 构造（memberwise 被自定义 init 吞掉）。
        func cgEntry(_ id: UInt32, midX: CGFloat, midY: CGFloat) -> CGWindowEntry {
            CGWindowEntry(from: [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid_t(100),
                kCGWindowBounds as String: [
                    "X": midX - 50, "Y": midY - 40, "Width": CGFloat(100), "Height": CGFloat(80)
                ],
            ])!
        }
        func cgEntryNoBounds(_ id: UInt32) -> CGWindowEntry {
            CGWindowEntry(from: [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: pid_t(100),
            ])!
        }
        // 上行(y=100) x: 300,100；下行(y=300) x: 200,50 —— 期望阅读序 2,1,4,3
        let raw = [cgEntry(1, midX: 300, midY: 100), cgEntry(2, midX: 100, midY: 100),
                   cgEntry(3, midX: 200, midY: 300), cgEntry(4, midX: 50, midY: 300)]
        let ordered = TerminalGridController.sortedByReadingOrder(raw)
        check("captureOrder: 行带→midX 阅读序", ordered.map { $0.windowID } == [2, 1, 4, 3])
        // 无 bounds 条目：windowID 兜底排序
        let mixed = [cgEntryNoBounds(9), cgEntry(5, midX: 0, midY: 0), cgEntryNoBounds(7)]
        let orderedMixed = TerminalGridController.sortedByReadingOrder(mixed)
        check("captureOrder: 无 bounds 按 windowID 兜底",
              orderedMixed.map { $0.windowID } == [5, 7, 9])
        check("captureOrder: 空输入 → 空", TerminalGridController.sortedByReadingOrder([]).isEmpty)

        // ===== restoreTargetFrames：复用记录帧 vs 重排（分支穷尽） =====
        func cell(_ index: Int, x: CGFloat, y: CGFloat) -> TerminalGridCellSnapshot {
            TerminalGridCellSnapshot(index: index, x: x, y: y, width: 500, height: 400,
                                     ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        }
        let snapshot = TerminalGridSnapshot(
            name: "t", appBundleID: "com.apple.Terminal", displayID: 1,
            displayYabaiIndex: nil, rows: 1, cols: 2,
            cells: [cell(0, x: 10, y: 20), cell(1, x: 520, y: 20)],
            launchCommand: nil
        )
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        // 分支 1：记录屏仍可用 → 记录帧原样（已在界内，clamp 不动）
        let reused = TerminalGridController.restoreTargetFrames(
            snapshot: snapshot, recordedDisplayStillFits: true, visibleFrame: visible)
        check("restoreFrames: 屏可用 → 记录帧复用",
              reused.count == 2 && reused[0] == CGRect(x: 10, y: 20, width: 500, height: 400))
        // 分支 2：记录屏失效 → 按 rows×cols 重排（1×2 网格规划）
        let replanned = TerminalGridController.restoreTargetFrames(
            snapshot: snapshot, recordedDisplayStillFits: false, visibleFrame: visible)
        check("restoreFrames: 屏失效 → 规划重排 1×2",
              replanned.count == 2 && replanned[0] != replanned[1]
              && replanned[0].width == replanned[1].width)
        // 分支 3：屏可用但记录帧越界 → clamp 进可用区
        let overflowSnapshot = TerminalGridSnapshot(
            name: "t2", appBundleID: "com.apple.Terminal", displayID: 1,
            displayYabaiIndex: nil, rows: 1, cols: 1,
            cells: [cell(0, x: 1900, y: 900)],
            launchCommand: nil
        )
        let clampedFrames = TerminalGridController.restoreTargetFrames(
            snapshot: overflowSnapshot, recordedDisplayStillFits: true, visibleFrame: visible)
        check("restoreFrames: 越界记录帧 clamp 进界",
              clampedFrames.count == 1
              && clampedFrames[0].maxX <= visible.maxX && clampedFrames[0].maxY <= visible.maxY)
    }

    // ===== cocoaBoundsTuple：Quartz frame → Cocoa {l, t, r, b}（B65 补测） =====
    // y 轴翻转依赖活屏高（真机相关），此处锁定机器无关契约：格式/x 轴取整/高度保持/翻转方向。
    do {
        func parse(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ", ")
                .compactMap { Int($0) }
        }
        // 格式契约：大括号包裹、逗号空格分隔、恰好四个整数
        let basic = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 0, y: 0, width: 100, height: 50)))
        check("bounds: 格式为 {l, t, r, b} 四元组", basic.count == 4)
        // x 轴与活屏无关：就近取整（10.4→10、110.6→111）
        let frac = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 10.4, y: 0, width: 100.2, height: 50)))
        check("bounds: x 边界就近取整", frac.count == 4 && frac[0] == 10 && frac[2] == 111)
        // l/r 各自独立取整 → |r−l − w| ≤ 1 是容差上界
        check("bounds: r−l 与宽度差 ≤ 1", abs(Double(frac[2] - frac[0]) - 100.2) <= 1)
        // 高度保持：翻转是平移，b−t 与 h 差 ≤ 1（t/b 各自取整的容差上界）
        let tall = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 0, y: 100, width: 80, height: 333.3)))
        check("bounds: b−t 与高度差 ≤ 1", abs(Double(tall[3] - tall[1]) - 333.3) <= 1)
        // 翻转方向：quartzMaxY 上移 100 → cocoa top/bottom 恰好 −100（整数平移与取整无关）
        let lower = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 0, y: 200, width: 80, height: 100)))
        let upper = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 0, y: 300, width: 80, height: 100)))
        check("bounds: quartz y 增大 → cocoa 上界/下界恰 −100",
              upper[1] == lower[1] - 100 && upper[3] == lower[3] - 100)
        // 零尺寸：l==r、t==b 退化为点
        let point = parse(TerminalAutomationScript.cocoaBoundsTuple(
            quartzFrame: CGRect(x: 5, y: 5, width: 0, height: 0)))
        check("bounds: 零尺寸退化为点", point[0] == point[2] && point[1] == point[3])
    }

    // ===== latestSessionID：projects 目录最新会话定位（B65 home 注入缝 + 临时目录直测） =====
    do {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "vibefocus-b65-home-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func write(_ projectDir: String, _ fileName: String, modified age: TimeInterval) {
            let path = URL(fileURLWithPath: home)
                .appendingPathComponent(".claude/projects/\(projectDir)/\(fileName)").path
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data("{}".utf8))
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: path)
        }
        defer { try? fm.removeItem(atPath: home) }

        // 最新者胜出：非 jsonl（即使最新）与 31 天前旧件都被过滤
        write("main", "s-old.jsonl", modified: -31 * 24 * 3600)
        write("main", "s-mid.jsonl", modified: -29 * 24 * 3600)
        write("main", "notes.txt", modified: -60)
        write("main", "s-new.jsonl", modified: -3600)
        check("session: 最新 jsonl 胜出（30 天窗外/非 jsonl 均被滤）",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "main", home: home, now: now, fileManager: fm) == "s-new")
        // 30 天界外：目录只剩界外件 → nil
        write("oldonly", "only-old.jsonl", modified: -40 * 24 * 3600)
        check("session: 仅剩 30 天界外件 → nil",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "oldonly", home: home, now: now, fileManager: fm) == nil)
        // 30 天界含端点：恰好 cutoff 的文件入选（modified >= cutoff）
        write("edge", "edge.jsonl", modified: -30 * 24 * 3600)
        check("session: 恰在 30 天界上仍入选",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "edge", home: home, now: now, fileManager: fm) == "edge")
        // 目录里只有非 jsonl → nil
        write("nojsonl", "newest.txt", modified: -10)
        check("session: 目录无 jsonl → nil",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "nojsonl", home: home, now: now, fileManager: fm) == nil)
        // 目录不存在 → nil（兜底链：无会话降级，不抛错）
        check("session: 目录不存在 → nil",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "never-created", home: home, now: now, fileManager: fm) == nil)
        // 文件名即 sessionID：点分 stem 原样保留（不做内部解析）
        write("dots", "abc.def.jsonl", modified: -10)
        check("session: 点分文件名 stem 原样保留",
              ClaudeSessionLocator.latestSessionID(inProjectDir: "dots", home: home, now: now, fileManager: fm) == "abc.def")
    }

    // ===== shellPID：tty 登录 shell 选取（B66 直测：runner 注入假 ps 输出，零真身进程查询） =====
    do {
        var seenExec: String?
        var seenArgs: [String]?
        func ps(_ stdout: String, exitCode: Int32 = 0) -> (String, [String]) -> YabaiClient.YabaiResult? {
            { exec, args in
                seenExec = exec
                seenArgs = args
                return YabaiClient.YabaiResult(exitCode: exitCode, stdout: stdout, stderr: "")
            }
        }
        // 混合行：login 包装/claude CLI/垃圾行/裸 pid 全滤；-zsh 剥前导 '-'；路径形取 basename；最小 pid 胜出
        let mixed = """
          500 login -pf cc
          501 -zsh
          502 /bin/zsh -l
          600 claude --resume abc
          not-a-pid-line
          700
        """
        check("shellPID: 最小 shell pid 胜出（login/claude/垃圾行/裸 pid 全滤）",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: ps(mixed)) == 501)
        check("shellPID: 走 /bin/ps -t 且 /dev/ 前缀被剥",
              seenExec == "/bin/ps" && seenArgs == ["-t", "ttys007", "-o", "pid=,command="])
        // 路径形 shell 单命中
        check("shellPID: 路径形 basename 识别",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: ps("  90 /usr/bin/fish")) == 90)
        // 非 zsh 系（pwsh）也在 shell 集合内
        check("shellPID: pwsh 属 shell 集合",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: ps("  70 pwsh")) == 70)
        // 空 ps 输出 → nil
        check("shellPID: 空 ps 输出 → nil",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: ps("")) == nil)
        // ps 退出码非 0 → nil
        check("shellPID: ps 退出码非 0 → nil",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: ps("  1 zsh", exitCode: 1)) == nil)
        // ps 进程缺失（runner 返回 nil）→ nil
        check("shellPID: ps 不可用 → nil",
              ClaudeSessionLocator.shellPID(onTTY: "/dev/ttys007", runner: { _, _ in nil }) == nil)
        // 非 /dev/ 前缀的 tty 原样透传
        var capturedTTY: String?
        _ = ClaudeSessionLocator.shellPID(onTTY: "ttys003", runner: { _, args in
            capturedTTY = args[1]
            return YabaiClient.YabaiResult(exitCode: 0, stdout: "  1 zsh", stderr: "")
        })
        check("shellPID: 无 /dev/ 前缀原样透传", capturedTTY == "ttys003")
    }
    }

    // MARK: 捕获过滤纯决策（B105：TerminalGridController+Capture 16% 最薄面——注入式直测）

    func runCaptureFilterTests() {
        func entry(_ id: UInt32, pid: Int32 = 4242, layer: Int = 0, onScreen: Bool = true,
                   w: CGFloat = 800, h: CGFloat = 600) -> CGWindowEntry {
            let d: [String: Any] = [
                kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer, kCGWindowIsOnscreen as String: onScreen,
                kCGWindowBounds as String: ["X": CGFloat(0), "Y": CGFloat(0), "Width": w, "Height": h],
            ]
            return CGWindowEntry(from: d)!
        }
        let isTerm: (pid_t) -> String? = { _ in "com.apple.Terminal" }
        let noTerm: (pid_t) -> String? = { _ in nil }
        let onMain: (CGRect) -> UInt32? = { _ in 1 }
        let onOther: (CGRect) -> UInt32? = { _ in 2 }
        check("captureFilter: layer0+onscreen+合格尺寸+终端 owner+目标屏 → 通过",
              TerminalGridController.isCapturableTerminalEntry(entry(1), targetDisplayID: 1,
                                                              bundleIDOf: isTerm, displayIDOf: onMain))
        check("captureFilter: 非零 layer/离屏/小窗（<100pt）拒绝",
              !TerminalGridController.isCapturableTerminalEntry(entry(2, layer: 3), targetDisplayID: 1,
                                                               bundleIDOf: isTerm, displayIDOf: onMain)
              && !TerminalGridController.isCapturableTerminalEntry(entry(3, onScreen: false), targetDisplayID: 1,
                                                                  bundleIDOf: isTerm, displayIDOf: onMain)
              && !TerminalGridController.isCapturableTerminalEntry(entry(4, w: 99, h: 99), targetDisplayID: 1,
                                                                  bundleIDOf: isTerm, displayIDOf: onMain))
        check("captureFilter: owner 非终端（nil bundleID）拒绝",
              !TerminalGridController.isCapturableTerminalEntry(entry(5), targetDisplayID: 1,
                                                               bundleIDOf: noTerm, displayIDOf: onMain))
        check("captureFilter: 目标 display 不符拒绝",
              !TerminalGridController.isCapturableTerminalEntry(entry(6), targetDisplayID: 1,
                                                               bundleIDOf: isTerm, displayIDOf: onOther))
    }
}
