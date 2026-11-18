import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionLivePanelRenderTests.swift — 覆盖率批次（2026-11-03）：
// 设置页「活跃会话 / 最近完成」面板的**行渲染**（SessionLivePanelView.rowView、
// statusTint、徽章/远程标记/项目/age/离屏占位、completedSessionList 行）。
//
// 安全边界：注册表内存表直接注入伪造 WindowState（不 bind、不碰 AX/DB 语义），
// 活动追踪走公开 record + resetForTesting；CLI 进程 isPersistable=false，不写用户文件。
// 渲染期不触发任何按钮 action。

extension RunnerHarness {

    func runSessionLivePanelRenderTests() {
        print("\n=== SessionLivePanelRender ===")
        let registry = SessionWindowRegistry.shared
        let tracker = SessionActivityTracker.shared
        let savedStates = registry.windowStates
        defer {
            registry.windowStates = savedStates
            tracker.resetForTesting()
            check("livePanel: 注入夹具已还原", registry.windowStates.count == savedStates.count)
        }
        tracker.resetForTesting()
        registry.windowStates = [:]

        let now = Date()
        func makeState(
            _ sessionID: String, windowID: UInt32, app: String, cwd: String?,
            remote: Bool, completed: Bool, at: Date
        ) -> WindowState {
            var state = WindowState(
                windowID: windowID, pid: 33_333, tty: nil, axWindowNumber: nil, appName: app,
                bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                sessionID: sessionID, bindingType: remote ? .remote : .local,
                isCompleted: completed, createdAt: at, updatedAt: at)
            state.cwd = cwd
            return state
        }

        registry.windowStates = [
            8_100_001: makeState("sid-waiting", windowID: 8_100_001, app: "iTerm2",
                                 cwd: "/tmp/live-demo/alpha", remote: false,
                                 completed: false, at: now.addingTimeInterval(-300)),
            8_100_002: makeState("sid-running", windowID: 8_100_002, app: "Terminal",
                                 cwd: "/tmp/live-demo/beta", remote: true,
                                 completed: false, at: now.addingTimeInterval(-60)),
            8_100_003: makeState("sid-bound", windowID: 8_100_003, app: "Warp",
                                 cwd: nil, remote: false,
                                 completed: false, at: now.addingTimeInterval(-30)),
            8_100_004: makeState("sid-done", windowID: 8_100_004, app: "Ghostty",
                                 cwd: "/tmp/live-demo/done", remote: false,
                                 completed: true, at: now.addingTimeInterval(-600)),
            8_100_005: makeState("sid-ended", windowID: 8_100_005, app: "kitty",
                                 cwd: "/tmp/live-demo/ended", remote: true,
                                 completed: true, at: now.addingTimeInterval(-1200)),
            8_100_006: makeState("sid-stale", windowID: 8_100_006, app: "WezTerm",
                                 cwd: nil, remote: false,
                                 completed: true, at: now.addingTimeInterval(-7200)),
        ]
        // 状态覆盖：waiting / running / bound（无活动）/ done / ended；
        // 8_100_006 完成超过 30 分钟 → 应被 recentCompletedBindings 过滤掉。
        tracker.record(sessionID: "sid-waiting", event: .notification, code: "permission",
                       at: now.addingTimeInterval(-120))
        tracker.record(sessionID: "sid-running", event: .userPromptSubmit, code: nil,
                       at: now.addingTimeInterval(-45))
        tracker.record(sessionID: "sid-done", event: .stop, code: nil,
                       at: now.addingTimeInterval(-600))
        tracker.record(sessionID: "sid-ended", event: .sessionEnd, code: nil,
                       at: now.addingTimeInterval(-1200))

        check("livePanel: 活跃绑定 3 条（排除完成态）",
              registry.activeBindingsForUI.count == 3)
        check("livePanel: 最近完成 2 条（超 30 分钟被过滤）",
              registry.recentCompletedBindings.count == 2)

        let rows = SessionPanelLogic.buildRows(
            bindings: registry.activeBindingsForUI,
            activities: tracker.activities,
            geo: [8_100_001: SessionWindowGeo(space: 2, display: 1)],
            now: now)
        check("livePanel: 行状态派生 waiting/running/bound",
              rows.map(\.status).contains(.waiting)
              && rows.map(\.status).contains(.running)
              && rows.map(\.status).contains(.bound))

        // 空态：两列表的空分支文案
        registry.windowStates = [:]
        tracker.resetForTesting()
        let emptyActive = ImageRenderer(content: SessionLivePanelView())
        check("livePanel: 空活跃列表渲染出图", emptyActive.nsImage != nil)
        let emptyCompleted = ImageRenderer(content: SettingsView().completedSessionList)
        check("livePanel: 空完成列表渲染出图", emptyCompleted.nsImage != nil)

        // 有数据的行渲染（状态徽章×5、远程标、项目名、age、离屏占位）
        registry.windowStates = [
            8_100_001: makeState("sid-waiting", windowID: 8_100_001, app: "iTerm2",
                                 cwd: "/tmp/live-demo/alpha", remote: false,
                                 completed: false, at: now.addingTimeInterval(-300)),
            8_100_002: makeState("sid-running", windowID: 8_100_002, app: "Terminal",
                                 cwd: "/tmp/live-demo/beta", remote: true,
                                 completed: false, at: now.addingTimeInterval(-60)),
            8_100_003: makeState("sid-bound", windowID: 8_100_003, app: "Warp",
                                 cwd: nil, remote: false,
                                 completed: false, at: now.addingTimeInterval(-30)),
            8_100_004: makeState("sid-done", windowID: 8_100_004, app: "Ghostty",
                                 cwd: "/tmp/live-demo/done", remote: false,
                                 completed: true, at: now.addingTimeInterval(-600)),
            8_100_005: makeState("sid-ended", windowID: 8_100_005, app: "kitty",
                                 cwd: "/tmp/live-demo/ended", remote: true,
                                 completed: true, at: now.addingTimeInterval(-1200)),
        ]
        tracker.record(sessionID: "sid-waiting", event: .notification, code: "permission",
                       at: now.addingTimeInterval(-120))
        tracker.record(sessionID: "sid-running", event: .userPromptSubmit, code: nil,
                       at: now.addingTimeInterval(-45))
        tracker.record(sessionID: "sid-done", event: .stop, code: nil,
                       at: now.addingTimeInterval(-600))
        tracker.record(sessionID: "sid-ended", event: .sessionEnd, code: nil,
                       at: now.addingTimeInterval(-1200))

        let filledActive = ImageRenderer(content: SessionLivePanelView())
        check("livePanel: 有行活跃列表渲染出图（含远程/项目/离屏）", filledActive.nsImage != nil)

        let filledCompleted = ImageRenderer(content: SettingsView().completedSessionList)
        check("livePanel: 有行完成列表渲染出图", filledCompleted.nsImage != nil)
    }
}
