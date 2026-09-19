import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSelectionRefreshTests.swift — 覆盖率批次 38（B270）：
// refreshSelectionInfo 直测（NSWorkspace runningApps + TerminalUsageTracker 只读采集，
// selectionPreview 静态缝 + gridSelectionPreview/gridFavoriteWarning @State 记账）。
// runGridTask（真建窗操作包装）留白。

extension RunnerHarness {
    func runSelectionRefreshTests() {
        let view = SettingsView()
        view.refreshSelectionInfo()
        check("selectionRefresh: refreshSelectionInfo 只读采集不崩", true)
        check("selectionRefresh: selectionDetailText 与偏好联动可读",
              !view.selectionDetailText.isEmpty)
    }
}
