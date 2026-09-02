// Tests/Standalone/RestoreRefocusCandidateTests.swift
// Verification: restore 恢复链路纯决策（refocus 候选选择 + 失败 record 处置 +
//               源屏预切回决策 + 结局标签派生）
// Mirrors: Sources/Space/SpaceController+Switch.swift selectRefocusCandidate
//          Sources/Toggle/ToggleEngine+Restore.swift isMoveFailureRetryable
//          Sources/Toggle/ToggleEngine+Restore.swift sourceSpacePreSwitch
//          Sources/Toggle/ToggleEngine+Restore.swift RestoreOutcome.outcomeLabel
// Run: swift Tests/Standalone/RestoreRefocusCandidateTests.swift

import Foundation

// MARK: - Mirrors (与源码同步维护；Swift Testing 版在 Tests/XCTest/RestoreRefocusCandidateTests.swift)

struct YabaiWindowInfoMirror {
    let id: Int?
    let space: Int?
    let hasAXReference: Bool
    let isMinimized: Bool

    var isManageableByYabai: Bool { hasAXReference }
}

func selectRefocusCandidate(
    windows: [YabaiWindowInfoMirror],
    spaceIndex: Int,
    excludingWindowID excluded: UInt32?
) -> YabaiWindowInfoMirror? {
    let onSpace = windows.filter { w in
        guard w.space == spaceIndex,
              w.isManageableByYabai,
              w.id.map({ UInt32($0) }) != excluded else { return false }
        return true
    }
    return onSpace.first { !$0.isMinimized } ?? onSpace.first
}

func isMoveFailureRetryable(origFrameOnAnyDisplay: Bool) -> Bool {
    origFrameOnAnyDisplay
}

/// 4-pre 源屏预切回决策的返回形态（镜像 SourceSpacePreSwitch；Equatable 手写比较）。
enum SourceSpacePreSwitchMirror: Equatable {
    case noContext
    case notNeeded
    case switchNeeded(visibleSpace: Int)
}

func sourceSpacePreSwitch(
    sourceSpace: Int,
    sourceYabaiDisp: Int,
    visibleSpaceOnSourceDisplay: Int?
) -> SourceSpacePreSwitchMirror {
    guard sourceSpace > 0, sourceYabaiDisp > 0 else { return .noContext }
    guard let visible = visibleSpaceOnSourceDisplay else { return .notNeeded }
    return visible == sourceSpace ? .notNeeded : .switchNeeded(visibleSpace: visible)
}

/// restore 真实结局的返回形态（镜像 RestoreOutcome；结局标签派生与源码同步维护）。
enum RestoreOutcomeMirror {
    case restored(spaceExact: Bool?)
    case aborted(reason: String)
    case moveFailedRetryable
    case moveFailedPermanent

    var outcomeLabel: String {
        switch self {
        case .restored(let spaceExact):
            return "restored(spaceExact=\(String(describing: spaceExact)))"
        case .aborted(let reason):
            return "aborted_\(reason)"
        case .moveFailedRetryable:
            return "move_failed_retryable_record_kept"
        case .moveFailedPermanent:
            return "move_failed_permanent_record_cleared"
        }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func win(id: Int, space: Int, hasAX: Bool = true, minimized: Bool? = nil) -> YabaiWindowInfoMirror {
    YabaiWindowInfoMirror(id: id, space: space, hasAXReference: hasAX, isMinimized: minimized ?? false)
}

// MARK: - selectRefocusCandidate

check("选中目标 space 上唯一的可管理窗口",
      selectRefocusCandidate(windows: [win(id: 1, space: 2), win(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)

check("跳过排除的 windowID（视角守卫不聚焦被恢复窗口自身）",
      selectRefocusCandidate(windows: [win(id: 7, space: 3)], spaceIndex: 3, excludingWindowID: 7) == nil)

check("跳过无 AX 引用的窗口（yabai --focus 必失败）",
      selectRefocusCandidate(windows: [win(id: 1, space: 3, hasAX: false), win(id: 2, space: 3)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)

check("偏好非最小化窗口（聚焦最小化窗口会把它从 Dock 拉出）",
      selectRefocusCandidate(windows: [win(id: 1, space: 3, minimized: true), win(id: 2, space: 3, minimized: false)], spaceIndex: 3, excludingWindowID: nil)?.id == 2)

check("全部最小化时退回最小化候选（视角切换优先于布局扰动）",
      selectRefocusCandidate(windows: [win(id: 1, space: 3, minimized: true), win(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)

check("minimized 字段缺失按未最小化处理",
      selectRefocusCandidate(windows: [win(id: 1, space: 3, minimized: nil), win(id: 2, space: 3, minimized: true)], spaceIndex: 3, excludingWindowID: nil)?.id == 1)

check("目标 space 无窗口返回 nil",
      selectRefocusCandidate(windows: [win(id: 1, space: 2)], spaceIndex: 3, excludingWindowID: nil) == nil)

// MARK: - isMoveFailureRetryable

check("origFrame 仍在现有屏上 → 保留 record 允许重试",
      isMoveFailureRetryable(origFrameOnAnyDisplay: true))

check("origFrame 已不在任何屏 → 清除 record 走 stuck 解堵兜底",
      !isMoveFailureRetryable(origFrameOnAnyDisplay: false))

// MARK: - sourceSpacePreSwitch（4-pre 源屏预切回决策）

check("record 无 space 上下文（sourceSpace=0）→ 不切",
      sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .noContext)

check("record 无 display 上下文（sourceYabaiDisp=0）→ 不切",
      sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 3) == .noContext)

check("上下文全缺（0/0/nil）→ 不切",
      sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: nil) == .noContext)

check("源屏可见 space 查询失败 → 不盲切（历史行为 spaceExact=true）",
      sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: nil) == .notNeeded)

check("源屏可见 space 已等于 sourceSpace → 无需切",
      sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .notNeeded)

check("源屏停在别的 space → 需要预切回，携带可见 space",
      sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 5) == .switchNeeded(visibleSpace: 5))

// MARK: - RestoreOutcome.outcomeLabel（失败日志与 CrashContextRecorder 的机器可读标签）

check("restored(spaceExact=true) 标签携带精确值",
      RestoreOutcomeMirror.restored(spaceExact: true).outcomeLabel == "restored(spaceExact=Optional(true))")
check("restored(spaceExact=false) 标签携带退化值（源屏切回失败不静默）",
      RestoreOutcomeMirror.restored(spaceExact: false).outcomeLabel == "restored(spaceExact=Optional(false))")
check("restored(spaceExact=nil) 标签携带无上下文值",
      RestoreOutcomeMirror.restored(spaceExact: nil).outcomeLabel == "restored(spaceExact=nil)")
check("aborted 原因进标签",
      RestoreOutcomeMirror.aborted(reason: "no_toggle_record").outcomeLabel == "aborted_no_toggle_record")
check("瞬时失败标签明示 record 保留",
      RestoreOutcomeMirror.moveFailedRetryable.outcomeLabel == "move_failed_retryable_record_kept")
check("永久失败标签明示 record 已清除",
      RestoreOutcomeMirror.moveFailedPermanent.outcomeLabel == "move_failed_permanent_record_cleared")

// MARK: - Summary

print("\nRestoreRefocusCandidateTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
