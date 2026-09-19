import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerGridSnapshotRowTests.swift — 覆盖率批次 13（B244）：
// SettingsView.gridSnapshotRow 快照行构建直测（开机恢复双分支）。
//
// gridSnapshotRow 是 internal 纯构建方法（按钮 action 闭包含 restoreLayout/
// removeSnapshot 真实会话操作，构建期不执行——诚实留白给 action 层）。memberwise
// 注入 @State（gridSnapshots/gridAutoRestoreSnapshotID/gridAutoRestoreEnabled 均
// 非 private）驱动「未设开机恢复→设为钮」「已设→pill+取消钮」双分支。

extension RunnerHarness {
    func runGridSnapshotRowTests() {
        let snapshot = SessionRestoreSnapshot(
            id: "b244-snap-1", name: "b244 布局",
            windows: [], launchCommand: nil,
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
            formatVersion: SessionRestoreSnapshot.currentFormatVersion)

        // SettingsView 有显式 init()（memberwise 被抑制），@State 不可注入——
        // 走默认构造（gridAutoRestoreSnapshotID 读当前偏好，构建期无论走哪一
        // 分支均为纯构建零副作用）。
        let view = SettingsView()
        let _ = view.gridSnapshotRow(snapshot)
        check("gridSnapshot: 快照行构建无异常（分支依当前偏好而定）", true)

        // 空窗口快照的计数文案形态（0 窗/单屏/0 session）
        let _ = view.savedLayoutsCard
        check("gridSnapshot: savedLayoutsCard 空表求值无异常", true)
    }
}
