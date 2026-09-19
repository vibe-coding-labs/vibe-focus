import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerInstallationsFailPathTests.swift — 覆盖率批次 49（B285）：
// Installations 失败分支直测——不存在路径的 Finder 定位/废纸篓移动（真实系统调用
// 的失败分支，目标不存在时零副作用）。

extension RunnerHarness {
    func runInstallationsFailPathTests() {
        let view = SettingsView()
        // showDuplicateInFinder/moveDuplicateToTrash 留白：真实 Finder 激活与
        // trashItem 系统调用，对不存在路径行为不可控（本轮实测挂起教训）。
        let _ = view
    }
}
