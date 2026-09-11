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

    // ===== coveringGrid + captureSummaryMessage：自由摆法捕获数字自洽 =====
    // inferGrid 是几何聚类估计，自由摆法下 rows×cols 乘积≠窗口数（真机实证：16 窗聚成 3×4），
    // 快照照存裸推断网格会让重排恢复帧不足丢窗、文案把两数并列会被读成矛盾。
    do {
        // 干净网格：原样保留（乘积 == 格子数不动）
        check("covering: 干净网格 3×4/12 原样",
              TerminalGridPlanner.coveringGrid(inferred: (3, 4), cellCount: 12) == (rows: 3, cols: 4))
        // 欠覆盖：先扩列（2×3/7 → 2×4=8）
        check("covering: 欠覆盖先扩列 2×3/7→2×4",
              TerminalGridPlanner.coveringGrid(inferred: (2, 3), cellCount: 7) == (rows: 2, cols: 4))
        // 列到顶扩行（3×4/16 → 4×4）
        check("covering: 列到顶扩行 3×4/16→4×4",
              TerminalGridPlanner.coveringGrid(inferred: (3, 4), cellCount: 16) == (rows: 4, cols: 4))
        // 过覆盖但合法：不动（3×2=6 ≥ 5）
        check("covering: 过覆盖合法网格原样",
              TerminalGridPlanner.coveringGrid(inferred: (3, 2), cellCount: 5) == (rows: 3, cols: 2))
        // 推断越界（fallback 1×N）：夹回上限再长到覆盖（1×16/16 → 4×4）
        check("covering: 越界推断 1×16/16→4×4",
              TerminalGridPlanner.coveringGrid(inferred: (1, 16), cellCount: 16) == (rows: 4, cols: 4))
        // 超 4×4 容量：封顶 4×4（重排只放前 16 格，总量由恢复汇总如实播报）
        check("covering: 超容量封顶 3×4/20→4×4",
              TerminalGridPlanner.coveringGrid(inferred: (3, 4), cellCount: 20) == (rows: 4, cols: 4))
        // 退化单格
        check("covering: 单格原样",
              TerminalGridPlanner.coveringGrid(inferred: (1, 1), cellCount: 1) == (rows: 1, cols: 1))

        // 文案：干净网格才并列形状，自由摆法只报窗口数（不再出现「16 (3×4)」式矛盾）
        check("summary: 干净网格带 (3×4)",
              TerminalGridPlanner.captureSummaryMessage(cellCount: 12, rows: 3, cols: 4, sessionCount: 2)
              == "已捕获 12 个终端窗口（3×4），其中 2 个关联到 Claude session")
        check("summary: 乘积不符省略括号",
              TerminalGridPlanner.captureSummaryMessage(cellCount: 16, rows: 3, cols: 4, sessionCount: 0)
              == "已捕获 16 个终端窗口，其中 0 个关联到 Claude session")
        check("summary: 乘积大于窗数同样省略",
              TerminalGridPlanner.captureSummaryMessage(cellCount: 5, rows: 3, cols: 2, sessionCount: 1)
              == "已捕获 5 个终端窗口，其中 1 个关联到 Claude session")
        check("summary: 单行 fallback 1×N 自洽展示",
              TerminalGridPlanner.captureSummaryMessage(cellCount: 3, rows: 1, cols: 3, sessionCount: 0)
              == "已捕获 3 个终端窗口（1×3），其中 0 个关联到 Claude session")

        // 恢复重排：旧快照存的是裸推断网格（3×4/16 格）屏失效 → 覆盖成 4×4，16 窗全有位子
        func legacyCell(_ index: Int) -> TerminalGridCellSnapshot {
            TerminalGridCellSnapshot(index: index, x: 10, y: 20, width: 300, height: 200,
                                     ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        }
        let legacy = TerminalGridSnapshot(
            name: "legacy", appBundleID: "com.apple.Terminal", displayID: 1,
            displayYabaiIndex: nil, rows: 3, cols: 4,
            cells: (0..<16).map(legacyCell),
            launchCommand: nil
        )
        let legacyReplan = TerminalGridController.restoreTargetFrames(
            snapshot: legacy, recordedDisplayStillFits: false,
            visibleFrame: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        check("restoreFrames: 旧快照欠覆盖重排 16 窗全有位子",
              legacyReplan.count == 16
              && legacyReplan.allSatisfy { $0.maxX <= 2000 && $0.maxY <= 1000 })
    }

    // ===== B122~B124 文案/记账诚实化：displayGrid / autoRestoreSummary / cellCreationFailure =====
    do {
        func auditCell(_ index: Int) -> TerminalGridCellSnapshot {
            TerminalGridCellSnapshot(index: index, x: 10, y: 20, width: 300, height: 200,
                                     ttyPath: nil, sessionID: nil, cwd: nil, title: nil)
        }
        func auditSnapshot(rows: Int, cols: Int, cells: Int) -> TerminalGridSnapshot {
            TerminalGridSnapshot(
                name: "audit", appBundleID: "com.apple.Terminal", displayID: 1,
                displayYabaiIndex: nil, rows: rows, cols: cols,
                cells: (0..<cells).map(auditCell),
                launchCommand: nil
            )
        }
        // displayGrid：旧快照（裸推断 3×4 · 16 格）显示侧长成 4×4，与恢复重排同口径；干净网格原样
        check("displayGrid: 旧快照欠覆盖 3×4/16 → 4×4",
              auditSnapshot(rows: 3, cols: 4, cells: 16).displayGrid == (rows: 4, cols: 4))
        check("displayGrid: 干净网格 3×4/12 原样",
              auditSnapshot(rows: 3, cols: 4, cells: 12).displayGrid == (rows: 3, cols: 4))
        check("displayGrid: 覆盖网格幂等 2×4/8 原样",
              auditSnapshot(rows: 2, cols: 4, cells: 8).displayGrid == (rows: 2, cols: 4))

        // autoRestore 汇总：四类去处之外的超容量格子必须显式记账
        check("autoSummary: 全部有去处不添尾注",
              TerminalGridPlanner.autoRestoreSummaryMessage(created: 3, injected: 2, skipped: 4, failures: 0, unprocessed: 0)
              == "自动恢复：新建 3、注入 2、跳过运行中 4")
        check("autoSummary: 失败计数并列",
              TerminalGridPlanner.autoRestoreSummaryMessage(created: 1, injected: 0, skipped: 2, failures: 5, unprocessed: 0)
              == "自动恢复：新建 1、注入 0、跳过运行中 2、失败 5")
        check("autoSummary: 超容量差额显式交代",
              TerminalGridPlanner.autoRestoreSummaryMessage(created: 12, injected: 0, skipped: 0, failures: 0, unprocessed: 4)
              == "自动恢复：新建 12、注入 0、跳过运行中 0；另有 4 格超出网格容量（4×4）未处理")
        check("autoSummary: 失败+超容并存",
              TerminalGridPlanner.autoRestoreSummaryMessage(created: 0, injected: 1, skipped: 0, failures: 2, unprocessed: 3)
              == "自动恢复：新建 0、注入 1、跳过运行中 0、失败 2；另有 3 格超出网格容量（4×4）未处理")

        // 建格失败：序号 1 起与阅读序一致；已建成窗不回收、必须交代去向
        check("cellFail: 首格失败无尾注",
              TerminalGridPlanner.cellCreationFailureMessage(failedIndex: 0, createdCount: 0, detail: "超时")
              == "第 1 个终端窗口创建失败：超时（若为自动化权限问题，请在 系统设置 → 隐私与安全性 → 自动化 中允许 VibeFocus 控制终端）")
        check("cellFail: 前 3 窗已建成的诚实尾注",
              TerminalGridPlanner.cellCreationFailureMessage(failedIndex: 3, createdCount: 3, detail: "超时")
              == "第 4 个终端窗口创建失败：超时（若为自动化权限问题，请在 系统设置 → 隐私与安全性 → 自动化 中允许 VibeFocus 控制终端）；前 3 个窗口已创建并保留在屏上")
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

    // MARK: TerminalUsageTable 纯表操作（B150：record/ranked/编码解码此前零直测——
    // 「自动：最近常用」排序唯一数据源；注释自称「表操作可完整单测」但从未兑现）
    func runUsageTableTests() {
        do {
            // record：首次建档 / 累加 / lastAt 只前进不后退（乱序旧日期不能拖回——实测踩坑语义）
            var table = TerminalUsageTable()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            table.record(bundleID: "com.googlecode.iterm2", at: t0)
            check("usageTable: 首次记录建档 count=1",
                  table.entries["com.googlecode.iterm2"]?.count == 1
                  && table.entries["com.googlecode.iterm2"]?.lastAt == t0)
            table.record(bundleID: "com.googlecode.iterm2", at: t0.addingTimeInterval(3600))
            check("usageTable: 新记录累加且 lastAt 前进",
                  table.entries["com.googlecode.iterm2"]?.count == 2
                  && table.entries["com.googlecode.iterm2"]?.lastAt == t0.addingTimeInterval(3600))
            table.record(bundleID: "com.googlecode.iterm2", at: t0)
            check("usageTable: 乱序旧日期 count 照累加但 lastAt 不回退",
                  table.entries["com.googlecode.iterm2"]?.count == 3
                  && table.entries["com.googlecode.iterm2"]?.lastAt == t0.addingTimeInterval(3600))
        }
        do {
            // ranked：minCount 过滤 / 衰减权重排序（近期低频压过高频陈旧）/ count 保持原始累计口径
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var table = TerminalUsageTable()
            let recent = now.addingTimeInterval(-3600)          // 1h 前
            let stale = now.addingTimeInterval(-30 * 24 * 3600) // 30d 前（14d 半衰下权重≈0.226×）
            table.entries["com.apple.Terminal"] = .init(count: 10, lastAt: stale)
            table.entries["com.googlecode.iterm2"] = .init(count: 3, lastAt: recent)
            table.entries["com.marpisoft.ghostty"] = .init(count: 0, lastAt: recent)
            let ranked = table.ranked(minCount: 1, now: now)
            check("usageTable: ranked——衰减后近期低频（3×1h）压过高频陈旧（10×30d）",
                  ranked.first?.bundleID == "com.googlecode.iterm2"
                  && ranked.count == 2)
            check("usageTable: ranked——count 仍为原始累计（展示口径不衰减）",
                  ranked.last?.bundleID == "com.apple.Terminal" && ranked.last?.count == 10)
            check("usageTable: ranked——minCount 过滤零噪声",
                  table.ranked(minCount: 4, now: now).map(\.bundleID) == ["com.apple.Terminal"])
            // 未来时间戳（负年龄）夹 0：权重=原始次数；等次数下比 lastAt 更新者先
            var clamped = TerminalUsageTable()
            clamped.entries["com.apple.Terminal"] = .init(count: 3, lastAt: now.addingTimeInterval(3600))
            clamped.entries["com.googlecode.iterm2"] = .init(count: 3, lastAt: now.addingTimeInterval(-3600))
            let future = clamped.ranked(minCount: 1, now: now, halfLifeDays: 14)
            check("usageTable: ranked——未来 lastAt 负年龄夹 0，等次数比 lastAt 新者先",
                  future.first?.bundleID == "com.apple.Terminal"
                  && future.dropFirst().first?.bundleID == "com.googlecode.iterm2")
        }
        do {
            // encoded/decode：往返保真 + 坏数据 nil
            var table = TerminalUsageTable()
            let at = Date(timeIntervalSince1970: 1_750_000_000)
            table.entries["com.googlecode.iterm2"] = .init(count: 7, lastAt: at)
            let roundtrip = TerminalUsageTable.decode(table.encoded() ?? Data())
            check("usageTable: 编码解码往返保真",
                  roundtrip == table
                  && roundtrip?.entries["com.googlecode.iterm2"]?.lastAt == at)
            check("usageTable: 坏数据解码 → nil 不抛",
                  TerminalUsageTable.decode(Data("not json".utf8)) == nil)
        }

        // ===== 自动化环境守卫：实例判定（真机实证 2026-09-11：并行 E2E 的 /tmp
        // 临时 iTerm2 与真实终端并存 → bundle id 寻址随机路由 → 建窗 AE 进垂死
        // 副本秒败无输出。唯一安全态 = 单实例且路径不在临时目录） =====
        do {
            func instance(_ pid: pid_t, _ path: String?) -> (pid: pid_t, executablePath: String?) {
                (pid: pid, executablePath: path)
            }
            check("instanceGuard: 单实例正式路径 → clean",
                  TerminalAutomationScript.automationInstanceVerdict(instances: [
                      instance(100, "/Applications/iTerm.app/Contents/MacOS/iTerm2")
                  ]) == .clean)
            check("instanceGuard: 零实例 → notRunning",
                  TerminalAutomationScript.automationInstanceVerdict(instances: []) == .notRunning)
            check("instanceGuard: 唯一实例在 /tmp → 非 clean（真实终端未运行）",
                  TerminalAutomationScript.automationInstanceVerdict(instances: [
                      instance(200, "/tmp/vibefocus-b149-UUID/iTerm2")
                  ]) != .clean)
            check("instanceGuard: /private/tmp 与 /var/folders 同判临时副本",
                  TerminalAutomationScript.isEphemeralInstancePath("/private/tmp/x/iTerm2")
                  && TerminalAutomationScript.isEphemeralInstancePath("/var/folders/zz/T/iTerm2")
                  && !TerminalAutomationScript.isEphemeralInstancePath("/Applications/iTerm.app/Contents/MacOS/iTerm2"))
            check("instanceGuard: 唯一实例路径不可辨 → 不放行（诚实拒绝）",
                  TerminalAutomationScript.automationInstanceVerdict(instances: [
                      instance(300, nil)
                  ]) != .clean)
            check("instanceGuard: 双正式实例并存 → ambiguous（寻址会漂移）",
                  TerminalAutomationScript.automationInstanceVerdict(instances: [
                      instance(400, "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
                      instance(401, "/Applications/iTerm.app/Contents/MacOS/iTerm2")
                  ]) != .clean)
            check("instanceGuard: 临时+正式并存 → 非 clean",
                  TerminalAutomationScript.automationInstanceVerdict(instances: [
                      instance(500, "/tmp/e2e/iTerm2"),
                      instance(501, "/Applications/iTerm.app/Contents/MacOS/iTerm2")
                  ]) != .clean)
            check("instanceGuard: 实例列表 >3 截断为 3 并标总数（拒绝文案不随副本数无限变长）",
                  {
                      let verdict = TerminalAutomationScript.automationInstanceVerdict(instances: [
                          instance(1, "/tmp/a/iTerm2"), instance(2, "/tmp/b/iTerm2"),
                          instance(3, "/tmp/c/iTerm2"), instance(4, "/tmp/d/iTerm2"),
                          instance(5, "/tmp/e/iTerm2")
                      ])
                      guard case .ambiguous(let detail) = verdict else { return false }
                      return detail.contains("等共 5 个") && !detail.contains("/tmp/d")
                  }())
            check("instanceGuard: clean → 放行文案为 nil",
                  TerminalAutomationScript.instanceGuardFailureMessage(
                      for: .clean, appName: "iTerm2") == nil)
            check("instanceGuard: ephemeralOnly 文案交代丢失风险",
                  TerminalAutomationScript.instanceGuardFailureMessage(
                      for: .ephemeralOnly(detail: "pid 200：/tmp/e2e/iTerm2"),
                      appName: "iTerm2")?.contains("丢失") == true)
            check("instanceGuard: ambiguous 文案交代随机路由",
                  TerminalAutomationScript.instanceGuardFailureMessage(
                      for: .ambiguous(detail: "pid 500；pid 501"),
                      appName: "iTerm2")?.contains("随机路由") == true)
            check("instanceGuard: notRunning 文案带应用名",
                  TerminalAutomationScript.instanceGuardFailureMessage(for: .notRunning, appName: "iTerm2")?
                  .contains("iTerm2") == true)

            // ===== 进程路径归属（basename 对比正式安装版；NSWorkspace 看不到裸副本的补丁） =====
            check("procPath: 正式安装版路径命中",
                  TerminalAutomationScript.processPathMatchesCanonicalExec(
                      "/Applications/iTerm.app/Contents/MacOS/iTerm2", canonicalExecName: "iTerm2"))
            check("procPath: /tmp 副本同 basename 命中（这正是要抓的形态）",
                  TerminalAutomationScript.processPathMatchesCanonicalExec(
                      "/tmp/vibefocus-b149-UUID/iTerm2", canonicalExecName: "iTerm2"))
            check("procPath: iTermServer 守护/其它进程不误命中",
                  !TerminalAutomationScript.processPathMatchesCanonicalExec(
                      "/Users/x/Library/Application Support/iTerm2/iTermServer-3.6.10", canonicalExecName: "iTerm2")
                  && !TerminalAutomationScript.processPathMatchesCanonicalExec(
                      "/Applications/Safari.app/Contents/MacOS/Safari", canonicalExecName: "iTerm2"))
            check("procPath: Terminal.app 可执行名对齐",
                  TerminalAutomationScript.processPathMatchesCanonicalExec(
                      "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                      canonicalExecName: "Terminal"))
        }

        // ===== 建窗重试表与失败明细（瞬时 AE 故障退避重试；挂起类不重试） =====
        do {
            check("cellRetry: 第 1 次失败退避 400ms",
                  TerminalAutomationScript.cellCreateRetryDelayNanos(failedAttempts: 1) == 400_000_000)
            check("cellRetry: 第 2 次失败退避 800ms",
                  TerminalAutomationScript.cellCreateRetryDelayNanos(failedAttempts: 2) == 800_000_000)
            check("cellRetry: 退避封顶 800ms（不随失败次数增长）",
                  TerminalAutomationScript.cellCreateRetryDelayNanos(failedAttempts: 7) == 800_000_000)
            check("cellRetry: 上限 3 次尝试（首次 + 2 退避重试）",
                  TerminalAutomationScript.maxCellCreateAttempts == 3)

            check("scriptFailure: nil 结果（未启动/超时）→ 明确含超时语义",
                  TerminalAutomationScript.describeScriptFailure(nil)?.contains("30s 超时") == true)
            check("scriptFailure: 非零退出 + stderr → 原文透传",
                  TerminalAutomationScript.describeScriptFailure(
                      .init(exitCode: 1, stdout: "", stderr: "execution error: iTerm2 got an error (-1712)")
                  ) == "execution error: iTerm2 got an error (-1712)")
            check("scriptFailure: 非零退出 + 空 stderr → 退出码现身（2026-09-11 实证形态）",
                  TerminalAutomationScript.describeScriptFailure(
                      .init(exitCode: 1, stdout: "", stderr: "")
                  )?.contains("退出码 1") == true)
            check("scriptFailure: 零退出 → nil（成功不污染）",
                  TerminalAutomationScript.describeScriptFailure(
                      .init(exitCode: 0, stdout: "18421", stderr: "")) == nil)
        }
    }
}
