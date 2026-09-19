import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsRenderPilotTests.swift — B238：NSHostingView 离屏渲染试点
//（风险审计后开张，见台账）。SettingsView 唯一的 @EnvironmentObject 是 hotKeyManager
//（其余 8 个单例全是 @StateObject autoclosure 自实例化）；渲染时注入它即可让
// general tab（hotKeySection+inputBubbleSection+permissionsSection+loginItemSection，
// 即此前 D/A 组全部留白段落）在构建期完整求值。
//
// 风险审计结论（B238，2026-09-19）：
// - LoginItemManager.shared init = Task{refresh()}→SMAppService 状态 XPC（只读）+
//   后台 AppleScript 陈旧登录项清理（生产 app 每次启动同款幂等维护）；
// - sessionRegistry→WindowStateStore.shared 打开生产 DB：WAL 多进程安全，body 只读；
// - overlayManager init 装信号 handler+注册 yabai 信号：Runner 正常 exit 不受影响；
// - 按钮危险 action（NSPasteboard/Process/install 系）在 action 闭包内，渲染期不执行。
// 渲染=NSHostingView 离屏 layoutSubtreeIfNeeded（无窗口不触发 onAppear/安装类副作用）。

extension RunnerHarness {
    func runSettingsRenderPilotTests() {
        print("\n=== SettingsRenderPilot (B238) ===")
        let root = SettingsView().environmentObject(HotKeyManager.shared)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 940)
        host.layoutSubtreeIfNeeded()
        check("renderPilot: general tab 离屏渲染全程无异常", true)
        check("renderPilot: 渲染非退化（有实际布局尺寸）",
              host.frame.width == 680 && host.subviews.count > 0)
        // 二次 relayout：状态驱动的重求值路径（含默认态二次构建收敛）
        host.layoutSubtreeIfNeeded()
        check("renderPilot: 二次 relayout 幂等收敛", host.subviews.count > 0)
    }
}
