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
    }
}
