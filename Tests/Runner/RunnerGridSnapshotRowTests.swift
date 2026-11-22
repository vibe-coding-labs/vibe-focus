import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerGridSnapshotRowTests.swift — 覆盖率批次 13（B244）：
// SettingsView.gridSnapshotRow 快照行构建直测（开机恢复双分支）。
//
// gridSnapshotRow 是 internal 纯构建方法（按钮 action 闭包含 restoreLayout/
// removeSnapshot 真实会话操作，构建期不执行——诚实留白给 action 层）。
// 2026-11-23 修正：@State 必须在**构造时**注入。旧版用 `SettingsView()` + 后置写
// gridAutoRestoreSnapshotID 在无窗渲染下不落 storage（B317 家法），行内「已设开机
// 恢复」pill 分支与多屏/多工作区计数组实际上从未求值。

extension RunnerHarness {
    func runGridSnapshotRowTests() {
        func snapshot(
            id: String,
            name: String,
            windows: [SessionWindowSnapshot] = [],
            capturedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)
        ) -> SessionRestoreSnapshot {
            SessionRestoreSnapshot(
                id: id, name: name, windows: windows, launchCommand: nil,
                capturedAt: capturedAt,
                formatVersion: SessionRestoreSnapshot.currentFormatVersion)
        }
        func window(displayID: UInt32, space: Int?, paneSession: String?) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                appBundleID: "com.apple.Terminal",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                displayID: displayID, yabaiDisplay: 1, yabaiSpace: space,
                title: nil, wasMinimized: false,
                panes: [SessionPaneSnapshot(kind: .localClaude, sessionID: paneSession, cwd: "/tmp")])
        }

        // A. 空窗口快照：单屏/0 工作区/0 session 的极简计数分支
        let empty = snapshot(id: "b244-snap-1", name: "b244 布局")
        let v1 = SettingsView(gridTargetCode: TerminalGridPreferences.target,
                              gridSnapshots: [empty])
        let _ = v1.gridSnapshotRow(empty)
        check("gridSnapshot: 空窗口快照行构建无异常（计数取短路分支）", true)
        let _ = v1.savedLayoutsCard
        check("gridSnapshot: savedLayoutsCard 非空表求值无异常", true)

        // B. 多屏 + 多工作区 + 有 session：三组「·」分隔块的计数分支
        let rich = snapshot(id: "b244-snap-2", name: "双屏双工作区", windows: [
            window(displayID: 1, space: 1, paneSession: "sess-a"),
            window(displayID: 2, space: 2, paneSession: nil),
        ])
        check("gridSnapshot: 计数夹具形态（2 窗/2 屏/2 工作区/1 session）",
              rich.windows.count == 2 && rich.displayCount == 2
              && rich.spaceCount == 2 && rich.sessionPaneCount == 1)
        let v2 = SettingsView(gridTargetCode: TerminalGridPreferences.target,
                              gridSnapshots: [rich])
        let _ = v2.gridSnapshotRow(rich)
        check("gridSnapshot: 多屏多工作区行渲染该三组计数", true)

        // C. 已设开机恢复 → 「开机恢复」pill + 「取消」钮；未设 → 「设为开机恢复」钮
        let v3 = SettingsView(
            gridTargetCode: TerminalGridPreferences.target,
            gridSnapshots: [rich],
            gridAutoRestoreSnapshotID: .some(rich.id))
        let _ = v3.gridSnapshotRow(rich)
        check("gridSnapshot: 已设开机恢复快照行走 pill + 取消分支", true)

        let v4 = SettingsView(
            gridTargetCode: TerminalGridPreferences.target,
            gridSnapshots: [rich],
            gridAutoRestoreSnapshotID: .some("other-snapshot-id"))
        let _ = v4.gridSnapshotRow(rich)
        check("gridSnapshot: 开机恢复指向他快照 → 本行走「设为开机恢复」分支", true)
    }
}
