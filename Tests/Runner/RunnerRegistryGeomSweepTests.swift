import AppKit
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerRegistryGeomSweepTests.swift — B230 注册表与几何/样式扫尾
// 靶：SessionWindowRegistry 查找三通道与 remap DB 回落（临时库）/ DesignSystem 视图
// 构建器（ImageRenderer 离屏渲染，不建窗）/ CoordinateKit 多屏索引映射（真机实屏只读）。

extension RunnerHarness {
    func runRegistryGeomSweepTests() {
        runRegistryLookupSweep()
        runDesignSystemBuilders()
        runCoordinateScreenMapping()
    }

    // MARK: - SessionWindowRegistry：findState 三通道 / hasLiveSessionBinding / remap DB 回落

    private func runRegistryLookupSweep() {
        let dir = NSTemporaryDirectory() + "ut100-registry-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = WindowStateStore(dbPath: dir + "/reg.db")
        let reg = SessionWindowRegistry(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func mkState(_ wid: UInt32, session: String?, completed: Bool) -> WindowState {
            var s = WindowState(
                windowID: wid, pid: 4242, tty: nil, axWindowNumber: nil, appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal", title: "t", termSessionID: nil,
                itermSessionID: nil, sessionID: session, bindingType: .local,
                isCompleted: completed, createdAt: now, updatedAt: now)
            if completed { s.completedAt = now }
            return s
        }

        // A1: findState DB 回落——只种库不种内存 → 查到并回填缓存
        let dbOnly = mkState(301, session: "s-301", completed: false)
        store.saveWindowState(dbOnly)
        reg.windowStates.removeValue(forKey: 301)
        let back = reg.findState(windowID: 301)
        check("registry A1: findState DB 回落命中并回填内存",
              back?.windowID == 301 && back?.sessionID == "s-301"
              && reg.windowStates[301]?.windowID == 301)
        check("registry A2: findState 双 miss → nil",
              reg.findState(windowID: 404) == nil)

        // A3: hasLiveSessionBinding 四态（内存 live/内存 completed/仅库/双 miss）
        reg.windowStates[501] = mkState(501, session: "s-501", completed: false)
        reg.windowStates[502] = mkState(502, session: "s-502", completed: true)
        check("registry A3: 四态判定（live true/completed false/仅库 true/未知 false）",
              reg.hasLiveSessionBinding(windowID: 501)
              && !reg.hasLiveSessionBinding(windowID: 502)
              && reg.hasLiveSessionBinding(windowID: 301)
              && !reg.hasLiveSessionBinding(windowID: 606))

        // A4: remapWindowID DB 回落分支——内存无旧行、库有旧行 → 迁移+删旧+落新
        store.saveWindowState(mkState(401, session: "s-401", completed: false))
        reg.windowStates.removeValue(forKey: 401)
        reg.remapWindowID(oldWindowID: 401, newWindowID: 402)
        check("registry A4: remap DB 回落（新 ID 入缓存带会话、旧库行删除、新行落库）",
              reg.windowStates[402]?.sessionID == "s-401"
              && reg.findState(windowID: 401) == nil
              && store.findWindowState(windowID: 402)?.sessionID == "s-401")
    }

    // MARK: - DesignSystem：视图构建器离屏执行（ImageRenderer，不建窗）

    private func runDesignSystemBuilders() {
        // 按钮样式：渲染 Button 触发 makeBody（label 变换/背景/阴影/悬停动画链全执行）
        let button = Button("ut100") {}.buttonStyle(VibeProminentButtonStyle())
        let rendered1 = ImageRenderer(content: button)
        rendered1.scale = 1
        check("designSys B1: ProminentButtonStyle makeBody 离屏渲染成功",
              rendered1.nsImage != nil)

        // 卡片样式 + 点阵背景 + 自适应色：一次渲染覆盖 ViewModifier body 与 Canvas 闭包
        let card = DotGridPattern()
            .frame(width: 120, height: 80)
            .vibeCardStyle()
            .background(VibeColors.card)
        let rendered2 = ImageRenderer(content: card)
        rendered2.scale = 1
        check("designSys B2: CardStyle/DotGridPattern/自适应色离屏渲染成功",
              rendered2.nsImage != nil)
    }

    // MARK: - CoordinateKit：多屏索引映射（真机实屏只读）

    private func runCoordinateScreenMapping() {
        let screens = NSScreen.screens
        check("geom C1: 测试环境至少一块屏", !screens.isEmpty)

        // 越界双守卫
        check("geom C2: yabai 索引越界 → nil（0 与 999）",
              CoordinateKit.nsScreen(forYabaiDisplayIndex: 0) == nil
              && CoordinateKit.nsScreen(forYabaiDisplayIndex: 999) == nil)

        // 索引 1 = 主屏（frame origin 为零）
        if let main = CoordinateKit.nsScreen(forYabaiDisplayIndex: 1) {
            check("geom C3: 索引 1 映射主屏（origin zero）",
                  main.frame.origin == .zero)
        } else {
            check("geom C3: 主屏映射 nil（环境异常）", false)
        }

        // 逆映射：主屏 → 1
        if let anyScreen = screens.first {
            check("geom C4: quartzVisibleFrame 有限值（宽高非负）",
                  CoordinateKit.quartzVisibleFrame(of: anyScreen).width >= 0
                  && CoordinateKit.quartzVisibleFrame(of: anyScreen).height >= 0)
        }
        if let mainScreen = screens.first(where: { $0.frame.origin == .zero }) {
            check("geom C5: 主屏逆映射 → yabai 索引 1",
                  CoordinateKit.yabaiDisplayIndex(for: mainScreenScreenProxy(mainScreen)) == 1)
        }

        // 双屏环境：索引 2 ↔ 非主屏往返（单屏环境此断言自然跳过）
        if screens.count > 1,
           let second = CoordinateKit.nsScreen(forYabaiDisplayIndex: 2),
           second.frame.origin != .zero {
            check("geom C6: 双屏环境索引 2 ↔ 非主屏往返一致",
                  CoordinateKit.yabaiDisplayIndex(for: secondScreenProxy(second)) == 2)
        } else {
            check("geom C6: 单屏环境跳过索引 2 往返", true)
        }
    }

    /// NSScreen 引用透传（保持调用形态与生产一致的语义占位）
    private func mainScreenScreenProxy(_ screen: NSScreen) -> NSScreen { screen }
    private func secondScreenProxy(_ screen: NSScreen) -> NSScreen { screen }
}
