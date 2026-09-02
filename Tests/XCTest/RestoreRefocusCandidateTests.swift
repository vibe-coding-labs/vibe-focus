import Testing
import Foundation
@testable import VibeFocusKit

/// restore 恢复链路纯决策锁定：
/// 1. SpaceController.selectRefocusCandidate — 「聚焦带动视角切换」的候选选择
///    （SA 失效环境下 space 切回的唯一通道，候选质量直接决定 restore 是否落对 space）；
/// 2. ToggleEngine.isMoveFailureRetryable — frame 写失败时 record 保留/清除的处置。
@Suite("Restore Refocus Candidate & Failure Policy")
@MainActor
struct RestoreRefocusCandidateTests {

    private func window(
        id: Int,
        space: Int,
        hasAX: Bool = true,
        minimized: Bool? = nil
    ) -> YabaiWindowInfo {
        YabaiWindowInfo(
            id: id, pid: 100, app: "App", title: "w\(id)",
            space: space, display: 1, frame: nil,
            isFloatingRaw: false, hasAXReferenceRaw: hasAX,
            isMinimizedRaw: minimized
        )
    }

    // MARK: - selectRefocusCandidate

    @Test("候选: 选中目标 space 上唯一的可管理窗口")
    func picksSoleCandidate() {
        let windows = [window(id: 1, space: 2), window(id: 2, space: 3)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick?.id == 2)
    }

    @Test("候选: 跳过排除的 windowID（restore 视角守卫不聚焦被恢复窗口自身）")
    func skipsExcludedWindow() {
        let windows = [window(id: 7, space: 3)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: 7)
        #expect(pick == nil)
    }

    @Test("候选: 跳过无 AX 引用的窗口（yabai --focus 必失败）")
    func skipsUnmanaged() {
        let windows = [window(id: 1, space: 3, hasAX: false), window(id: 2, space: 3, hasAX: true)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick?.id == 2)
    }

    @Test("候选: 偏好非最小化窗口（聚焦最小化窗口会把它从 Dock 拉出）")
    func prefersNonMinimized() {
        let windows = [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: false)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick?.id == 2)
    }

    @Test("候选: 全部最小化时退回最小化候选（视角切换优先于布局扰动）")
    func fallsBackToMinimized() {
        let windows = [window(id: 1, space: 3, minimized: true), window(id: 2, space: 3, minimized: true)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick?.id == 1)
    }

    @Test("候选: minimized 字段缺失按未最小化处理")
    func missingMinimizedFieldCountsAsVisible() {
        let windows = [window(id: 1, space: 3, minimized: nil), window(id: 2, space: 3, minimized: true)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick?.id == 1)
    }

    @Test("候选: 目标 space 无窗口返回 nil")
    func emptySpaceReturnsNil() {
        let windows = [window(id: 1, space: 2)]
        let pick = SpaceController.selectRefocusCandidate(windows: windows, spaceIndex: 3, excludingWindowID: nil)
        #expect(pick == nil)
    }

    // MARK: - isMoveFailureRetryable

    @Test("失败处置: origFrame 仍在现有屏上 → 保留 record 允许重试")
    func reachableFrameRetainsRecord() {
        #expect(ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: true))
    }

    @Test("失败处置: origFrame 已不在任何屏 → 清除 record 走 stuck 解堵兜底")
    func unreachableFrameClearsRecord() {
        #expect(!ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: false))
    }

    // MARK: - sourceSpacePreSwitch（4-pre 源屏预切回决策）

    @Test("4-pre: record 无 space 上下文（sourceSpace=0）→ 不切，spaceExact=nil")
    func noContextWhenSourceSpaceMissing() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .noContext)
    }

    @Test("4-pre: record 无 display 上下文（sourceYabaiDisp=0）→ 不切，spaceExact=nil")
    func noContextWhenDisplayMissing() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 3) == .noContext)
    }

    @Test("4-pre: 上下文全缺（0/0/nil）→ 不切，spaceExact=nil")
    func noContextWhenEverythingMissing() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: nil) == .noContext)
    }

    @Test("4-pre: 源屏可见 space 查询失败 → 不盲切，spaceExact=true（历史行为）")
    func queryFailureSkipsSwitch() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: nil) == .notNeeded)
    }

    @Test("4-pre: 源屏可见 space 已等于 sourceSpace → 无需切，spaceExact=true")
    func alreadyOnSourceSpaceSkipsSwitch() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 3) == .notNeeded)
    }

    @Test("4-pre: 源屏停在别的 space → 需要预切回，携带可见 space 供日志")
    func differentVisibleSpaceNeedsSwitch() {
        #expect(ToggleEngine.sourceSpacePreSwitch(sourceSpace: 3, sourceYabaiDisp: 2, visibleSpaceOnSourceDisplay: 5) == .switchNeeded(visibleSpace: 5))
    }
}
