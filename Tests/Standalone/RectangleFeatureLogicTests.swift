// Tests/Standalone/RectangleFeatureLogicTests.swift
// Verification: Rectangle 式摆位几何 / 终端网格规划 / 共存探测判定 / Claude session 定位纯逻辑
// Mirrors: Sources/Layout/LayoutFrameCalculator.swift, Sources/Layout/WindowLayoutManagerProbe.swift,
//          Sources/TerminalGrid/TerminalGridPlanner.swift, Sources/TerminalGrid/ClaudeSessionLocator.swift
// Run: swift Tests/Standalone/RectangleFeatureLogicTests.swift

import CoreGraphics
import Foundation

// MARK: - Mirrored logic

enum LayoutAction: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case maximize, center, nextDisplay
}

enum LayoutFrameCalculator {
    static func splitFrame(for action: LayoutAction, visibleFrame: CGRect, gap: CGFloat = 0) -> CGRect? {
        switch action {
        case .maximize, .nextDisplay:
            return visibleFrame.insetBy(dx: gap, dy: gap)
        case .leftHalf, .rightHalf:
            let span = max(0, (visibleFrame.width - gap * 2 - gap / 2) / 2)
            let x: CGFloat = action == .leftHalf
                ? visibleFrame.minX + gap
                : visibleFrame.minX + gap + span + gap / 2
            return CGRect(x: x, y: visibleFrame.minY + gap, width: span, height: max(0, visibleFrame.height - gap * 2))
        case .topHalf, .bottomHalf:
            let span = max(0, (visibleFrame.height - gap * 2 - gap / 2) / 2)
            let y: CGFloat = action == .topHalf
                ? visibleFrame.minY + gap
                : visibleFrame.minY + gap + span + gap / 2
            return CGRect(x: visibleFrame.minX + gap, y: y, width: max(0, visibleFrame.width - gap * 2), height: span)
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            let w = max(0, (visibleFrame.width - gap * 2 - gap / 2) / 2)
            let h = max(0, (visibleFrame.height - gap * 2 - gap / 2) / 2)
            let isLeft = action == .topLeftQuarter || action == .bottomLeftQuarter
            let isTop = action == .topLeftQuarter || action == .topRightQuarter
            let x: CGFloat = isLeft ? visibleFrame.minX + gap : visibleFrame.minX + gap + w + gap / 2
            let y: CGFloat = isTop ? visibleFrame.minY + gap : visibleFrame.minY + gap + h + gap / 2
            return CGRect(x: x, y: y, width: w, height: h)
        case .center:
            return nil
        }
    }

    static func centeredFrame(windowFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(windowFrame.width, visibleFrame.width)
        let height = min(windowFrame.height, visibleFrame.height)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}

enum TerminalGridPlanner {
    static let maxGridSize = 4

    static func validate(rows: Int, cols: Int) -> Bool {
        (1...maxGridSize).contains(rows) && (1...maxGridSize).contains(cols)
    }

    static func cells(visibleFrame: CGRect, rows: Int, cols: Int, gap: CGFloat) -> [CGRect] {
        guard validate(rows: rows, cols: cols), visibleFrame.width > 0, visibleFrame.height > 0 else {
            return []
        }
        let cellWidth = (visibleFrame.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellHeight = (visibleFrame.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cellWidth > 0, cellHeight > 0 else { return [] }
        var result: [CGRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                result.append(CGRect(
                    x: visibleFrame.minX + CGFloat(col) * (cellWidth + gap),
                    y: visibleFrame.minY + CGFloat(row) * (cellHeight + gap),
                    width: cellWidth,
                    height: cellHeight
                ))
            }
        }
        return result
    }

    static func inferGrid(from frames: [CGRect], tolerance: CGFloat = 40) -> (rows: Int, cols: Int)? {
        guard !frames.isEmpty else { return nil }
        var rowBands: [CGFloat] = []
        var colBands: [CGFloat] = []
        for frame in frames.sorted(by: { $0.midY < $1.midY }) {
            if rowBands.contains(where: { abs($0 - frame.midY) <= tolerance }) { continue }
            rowBands.append(frame.midY)
        }
        for frame in frames.sorted(by: { $0.midX < $1.midX }) {
            if colBands.contains(where: { abs($0 - frame.midX) <= tolerance }) { continue }
            colBands.append(frame.midX)
        }
        guard validate(rows: rowBands.count, cols: colBands.count) else { return nil }
        return (rowBands.count, colBands.count)
    }

    static func clampToVisible(frame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        var width = max(min(frame.width, visibleFrame.width), 1)
        var height = max(min(frame.height, visibleFrame.height), 1)
        var x = frame.origin.x
        var y = frame.origin.y
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - height)
        width = min(width, visibleFrame.width)
        height = min(height, visibleFrame.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

let knownManagerNames = ["Rectangle", "Rectangle Pro", "Magnet", "Moom", "SizeUp", "Spectacle",
                         "Amethyst", "Hammerspoon", "BetterSnapTool", "Swish", "Loop"]

struct ProbeProfile {
    let runningConflicts: [String]
    var hasRunningConflict: Bool { !runningConflicts.isEmpty }
}

func probeEvaluate(runningAppNames: Set<String>, runningBundleIDs: Set<String>, installedAppNames: Set<String>) -> ProbeProfile {
    let knownBundleIDs = [
        "Rectangle": "com.knollsoft.Rectangle",
        "Rectangle Pro": "com.knollsoft.RectanglePro",
        "Magnet": "com.coredigest.WndManager",
        "Moom": "com.manytricks.Moom",
        "SizeUp": "com.irradiatedsoftware.SizeUp",
        "Spectacle": "com.wondersofspectacle.Spectacle",
        "Amethyst": "com.amethyst.Amethyst",
        "Hammerspoon": "org.hammerspoon.Hammerspoon",
        "BetterSnapTool": "com.hegenberg.BetterSnapTool",
        "Swish": "net.mattpallott.Swish",
        "Loop": "com.Midwinter.Duncan.Loop"
    ]
    var conflicts: [String] = []
    for known in knownManagerNames {
        let bundleID = knownBundleIDs[known] ?? ""
        let running = runningBundleIDs.contains(bundleID) || runningAppNames.contains(known)
        if running {
            conflicts.append(known)
        }
        _ = installedAppNames.contains(known) || running
    }
    return ProbeProfile(runningConflicts: conflicts)
}

enum ClaudeSessionLocator {
    static func escapedProjectDir(forCWD cwd: String) -> String {
        String(cwd.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        })
    }

    static func sessionID(fromSessionFileName fileName: String) -> String? {
        guard fileName.hasSuffix(".jsonl") else { return nil }
        let stem = String(fileName.dropLast(".jsonl".count))
        return stem.isEmpty ? nil : stem
    }

    static func isClaudeProcess(commandLine: String) -> Bool {
        let tokens = commandLine.split(separator: " ")
        return tokens.contains { token in
            let t = String(token)
            return t == "claude" || t.hasSuffix("/claude")
        }
    }
}

// MARK: - Harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("  PASS: \(name)")
    } else {
        failed += 1
        print("  FAIL: \(name)")
    }
}

// MARK: - 摆位几何

do {
    let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)

    let left = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 0)
    let right = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 0)
    check("摆位: 左右半屏对半分互补", left?.width == visible.width / 2 && left?.maxX == right?.minX && right?.maxX == visible.maxX)

    let top = LayoutFrameCalculator.splitFrame(for: .topHalf, visibleFrame: visible, gap: 0)
    let bottom = LayoutFrameCalculator.splitFrame(for: .bottomHalf, visibleFrame: visible, gap: 0)
    check("摆位: 上下半屏对半分（Quartz y 向下）", top?.minY == visible.minY && top?.maxY == bottom?.minY && bottom?.maxY == visible.maxY)

    let tl = LayoutFrameCalculator.splitFrame(for: .topLeftQuarter, visibleFrame: visible, gap: 0)
    let br = LayoutFrameCalculator.splitFrame(for: .bottomRightQuarter, visibleFrame: visible, gap: 0)
    check("摆位: 四分 = 半宽×半高角对齐",
          tl?.width == visible.width / 2 && tl?.height == visible.height / 2
          && tl?.minX == visible.minX && br?.maxX == visible.maxX && br?.maxY == visible.maxY)

    let gapL = LayoutFrameCalculator.splitFrame(for: .leftHalf, visibleFrame: visible, gap: 8)
    let gapR = LayoutFrameCalculator.splitFrame(for: .rightHalf, visibleFrame: visible, gap: 8)
    check("摆位: 留白时两半不重叠", gapL!.maxX < gapR!.minX && gapL!.width + gapR!.width < visible.width)

    check("摆位: maximize = inset", LayoutFrameCalculator.splitFrame(for: .maximize, visibleFrame: visible, gap: 12) == visible.insetBy(dx: 12, dy: 12))
    check("摆位: center 走专用路径", LayoutFrameCalculator.splitFrame(for: .center, visibleFrame: visible, gap: 0) == nil)

    let centered = LayoutFrameCalculator.centeredFrame(windowFrame: CGRect(x: 100, y: 100, width: 800, height: 500), visibleFrame: visible)
    check("摆位: 居中保持尺寸中心对齐", centered.width == 800 && centered.midX == visible.midX && centered.midY == visible.midY)

    let clampedCenter = LayoutFrameCalculator.centeredFrame(windowFrame: CGRect(x: 0, y: 0, width: 9999, height: 9999), visibleFrame: visible)
    check("摆位: 居中超大窗口 clamp", clampedCenter.size == visible.size)
}

// MARK: - 终端网格规划

do {
    let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)
    let cells = TerminalGridPlanner.cells(visibleFrame: visible, rows: 2, cols: 2, gap: 8)
    check("网格: 2×2 出 4 格", cells.count == 4)
    check("网格: 行列对齐", cells[0].minX == cells[2].minX && cells[0].minY == cells[1].minY)
    check("网格: 越界拒绝", TerminalGridPlanner.cells(visibleFrame: visible, rows: 5, cols: 2, gap: 8).isEmpty
          && !TerminalGridPlanner.validate(rows: 0, cols: 1))

    let laid = [
        CGRect(x: 0, y: 25, width: 860, height: 542),
        CGRect(x: 868, y: 25, width: 860, height: 542),
        CGRect(x: 0, y: 575, width: 860, height: 542),
        CGRect(x: 868, y: 575, width: 860, height: 542)
    ]
    let inferred = TerminalGridPlanner.inferGrid(from: laid)
    check("网格: 2×2 摆法反推 = (2,2)", inferred?.rows == 2 && inferred?.cols == 2)

    let clamped = TerminalGridPlanner.clampToVisible(frame: CGRect(x: -50, y: 0, width: 3000, height: 2000), visibleFrame: visible)
    check("网格: clamp 越界 frame 进可视区",
          clamped.minX >= visible.minX && clamped.minY >= visible.minY
          && clamped.maxX <= visible.maxX && clamped.maxY <= visible.maxY)
}

// MARK: - 共存探测

do {
    let running = probeEvaluate(runningAppNames: ["Finder", "Rectangle"], runningBundleIDs: [], installedAppNames: ["Rectangle"])
    check("共存: 按名识别运行中的 Rectangle", running.hasRunningConflict && running.runningConflicts == ["Rectangle"])

    let magnet = probeEvaluate(runningAppNames: [], runningBundleIDs: ["com.coredigest.WndManager"], installedAppNames: [])
    check("共存: 按 bundleID 识别 Magnet", magnet.hasRunningConflict && magnet.runningConflicts == ["Magnet"])

    let clean = probeEvaluate(runningAppNames: ["Finder", "yabai"], runningBundleIDs: [], installedAppNames: [])
    check("共存: yabai/Finder 不误报", !clean.hasRunningConflict)
}

// MARK: - Claude session 定位纯逻辑

do {
    check("session: 目录名映射", ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/.local/bin") == "-Users-cc--local-bin")
    check("session: 空格/点也替换", ClaudeSessionLocator.escapedProjectDir(forCWD: "/Users/cc/My.Dir x") == "-Users-cc-My-Dir-x")
    check("session: jsonl 文件名 → sessionID", ClaudeSessionLocator.sessionID(fromSessionFileName: "abc-123.jsonl") == "abc-123")
    check("session: 非 jsonl 拒绝", ClaudeSessionLocator.sessionID(fromSessionFileName: "x.txt") == nil)
    check("session: claude 进程判定", ClaudeSessionLocator.isClaudeProcess(commandLine: "/usr/local/bin/claude --resume x")
          && !ClaudeSessionLocator.isClaudeProcess(commandLine: "vim claude-notes.md"))
}

// MARK: - 汇总

print("")
print("RectangleFeatureLogicTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
