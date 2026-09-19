import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsFullRenderTests.swift — 覆盖率批次 43（B268）：
// SettingsView 真实渲染直测（NSHostingView 环境注入——B271 遗留 EnvironmentObject
// 难题的解法：HotKeyManager.shared 经 .environmentObject 注入渲染环境，脱离
// 「裸 body 求值必崩」限制，全部 section（含 EnvironmentObject 段）真实渲染）。
//
// 渲染触发全部构建表达式+ForEach 内层+嵌套 body——B229 机制性留白段大部分转可测。
// SettingsView.selectedTab 为 @State internal：经 NSHostingView 渲染当前态
// （.general 默认），跨 tab 渲染依赖 TabView 惰性策略——以「渲染不崩」为契约。

extension RunnerHarness {
    func runSettingsFullRenderTests() {
        // 真实渲染：环境注入 HotKeyManager.shared（@EnvironmentObject 依赖满足）
        let host = NSHostingView(rootView: SettingsView().environmentObject(HotKeyManager.shared))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        check("settingsRender: 全树真实渲染（NSHostingView）不崩", true)
        check("settingsRender: 渲染产生非空子视图树",
              host.subviews.count > 0)
    }
}
