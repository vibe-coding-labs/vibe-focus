import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRestoreSpaceTargetTests.swift — 2026-11-03 restore 工作区取证加固。
//
// 用户主诉：工作区 2 的窗口还原时落到工作区 3 的对应位置（同坐标不同 space）。
// 本文件锁定三层防线的纯判定与编排：
//   1. RestoreSpaceTargetResolver：record 的全局索引 + display-local 序号 + fresh 拓扑
//      → 实际还原目标（索引漂移回译、几何屏优先、屏已消失如实标记）；
//   2. performSourcePreSwitch fresh 路径：可见性读 fresh 拓扑（不读 2s 缓存）、目标不可
//      定位不盲切、未知可见性仍尝试幂等切回；
//   3. verifyLandingSpace / landingSpaceExact：move 后用窗口真实 space 做地面真值裁决。

extension RunnerHarness {

    private func space(_ index: Int, display: Int, visible: Bool, id: Int? = nil) -> YabaiSpaceInfo {
        YabaiSpaceInfo(id: id ?? (index + 100), index: index, display: display, isVisible: visible)
    }

    func runRestoreSpaceTargetTests() {
        runRestoreSpaceTargetResolverTests()
        runFreshPreSwitchDecisionTests()
        runPerformSourcePreSwitchFreshTests()
        runLandingVerificationTests()
        runRestoreLandingIntegrationTests()
    }

    // MARK: - 1. RestoreSpaceTargetResolver（纯解析，分支穷尽）

    private func runRestoreSpaceTargetResolverTests() {
        // 典型布局：display1 = [1(v)]，display2 = [2(h),3(v)]，display3 = [4(v)]
        let layout = [
            space(1, display: 1, visible: true),
            space(2, display: 2, visible: false),
            space(3, display: 2, visible: true),
            space(4, display: 3, visible: true),
        ]

        do {
            // 无漂移：local 2 回译为 3，与记录一致
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                geometricDisplay: 2, spaces: layout)
            check("解析: 无漂移 local 2 → 全局 3（shifted=false，几何屏 2）",
                  r?.spaceIndex == 3 && r?.spaceIndexShifted == false
                  && r?.displayIndex == 2 && r?.displaySource == .geometry
                  && r?.displayInTopology == true && r?.spaceOnDisplay == true
                  && r?.visibleSpaceIndex == 3 && r?.displayMismatch == false)
        }
        do {
            // 索引漂移（主诉根因）：display2 在 [2,3] 前插入了一个屏外 space 后变为 [4,5]；
            // 旧全局索引 3 会切到别的屏，本地序号 2 才是用户语义的「第 2 个工作区」。
            let drifted = [
                space(1, display: 1, visible: true),
                space(2, display: 1, visible: false),
                space(3, display: 1, visible: false),
                space(4, display: 2, visible: false),
                space(5, display: 2, visible: true),
            ]
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                geometricDisplay: 2, spaces: drifted)
            check("解析: 索引漂移 → local 2 回译为 5（不沿用旧全局 3，shifted=true）",
                  r?.spaceIndex == 5 && r?.recordedSpaceIndex == 3
                  && r?.spaceIndexShifted == true && r?.spaceOnDisplay == true)
        }
        do {
            // 几何屏与记录屏不一致：几何屏在拓扑里优先（窗口可能已跨屏/屏号重排）
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 4, recordedDisplay: 2, recordedLocalSpace: 1,
                geometricDisplay: 3, spaces: layout)
            check("解析: 几何屏存在时优先于 record 屏（display=3<geometry>，mismatch=true）",
                  r?.displayIndex == 3 && r?.displaySource == .geometry
                  && r?.displayMismatch == true && r?.spaceIndex == 4)
        }
        do {
            // 几何屏不在拓扑（映射失败/已拔屏）→ 回退 record 屏
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                geometricDisplay: 9, spaces: layout)
            check("解析: 几何屏不在拓扑 → 回退 record 屏 2",
                  r?.displayIndex == 2 && r?.displaySource == .recorded
                  && r?.displayMismatch == true)
        }
        do {
            // 记录屏已消失且几何屏也消失：保留候选如实标记（不盲切由决策层处理）
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                geometricDisplay: nil, spaces: [space(1, display: 1, visible: true)])
            check("解析: 目标屏不在拓扑 → displayInTopology=false / spaceOnDisplay=false",
                  r?.displayIndex == 2 && r?.displayInTopology == false
                  && r?.spaceOnDisplay == false && r?.visibleSpaceIndex == nil)
        }
        do {
            // 本地序号失配（该屏只剩 1 个 space，记录是第 2 个）→ 退回记录全局索引，
            // 且如实标记目标不在该屏（决策层转 targetUnresolvable，不盲切）。
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 4, recordedDisplay: 1, recordedLocalSpace: 2,
                geometricDisplay: 1, spaces: layout)
            check("解析: local 序号越界 → 退回记录索引且 spaceOnDisplay=false（可判不可切）",
                  r?.spaceIndex == 4 && r?.spaceIndexShifted == false
                  && r?.spaceOnDisplay == false)
        }
        do {
            // 本地序号缺失（旧记录 sourceDispSpace=0）：沿用全局索引
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 0,
                geometricDisplay: 2, spaces: layout)
            check("解析: local=0（旧记录）→ 沿用全局索引 3，spaceOnDisplay=true",
                  r?.spaceIndex == 3 && r?.spaceIndexShifted == false && r?.spaceOnDisplay == true)
        }
        do {
            check("解析: sourceSpace=0 → nil（无 space 上下文）",
                  RestoreSpaceTargetResolver.resolve(
                    recordedSpace: 0, recordedDisplay: 2, recordedLocalSpace: 2,
                    geometricDisplay: 2, spaces: layout) == nil)
            check("解析: 拓扑 nil / 空 → nil（走旧路径）",
                  RestoreSpaceTargetResolver.resolve(
                    recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                    geometricDisplay: 2, spaces: nil) == nil
                  && RestoreSpaceTargetResolver.resolve(
                    recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                    geometricDisplay: 2, spaces: []) == nil)
        }
        do {
            let topology = RestoreSpaceTargetResolver.describeTopology(layout)
            check("取证串: 拓扑按全局索引升序 idx:id@dN/v|h",
                  topology == "1:id101@d1/v,2:id102@d2/h,3:id103@d2/v,4:id104@d3/v")
            check("取证串: nil 拓扑 → \"nil\"", RestoreSpaceTargetResolver.describeTopology(nil) == "nil")
            let r = RestoreSpaceTargetResolver.resolve(
                recordedSpace: 3, recordedDisplay: 2, recordedLocalSpace: 2,
                geometricDisplay: 2, spaces: layout)
            check("取证串: 解析结果含 display 来源/记录值/visible/onDisplay",
                  RestoreSpaceTargetResolver.describe(r)
                  == "display=2<geometry>;space=3(recorded 3,local 2,shifted false);visible=3;inTopology=true;onDisplay=true;mismatch=false"
                  && RestoreSpaceTargetResolver.describe(nil) == "unresolved")
        }
    }

    // MARK: - 2. freshSourceSpacePreSwitch（纯决策）

    private func runFreshPreSwitchDecisionTests() {
        check("fresh 决策: sourceSpace=0 → noContext",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 0, targetDisplay: 2, displayInTopology: true,
                spaceOnDisplay: true, visibleSpaceOnSourceDisplay: 3) == .noContext)
        check("fresh 决策: 目标屏 nil → noContext",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 3, targetDisplay: nil, displayInTopology: true,
                spaceOnDisplay: true, visibleSpaceOnSourceDisplay: 3) == .noContext)
        check("fresh 决策: 屏不在拓扑 → targetUnresolvable（不盲切）",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 3, targetDisplay: 2, displayInTopology: false,
                spaceOnDisplay: false, visibleSpaceOnSourceDisplay: nil) == .targetUnresolvable)
        check("fresh 决策: 目标 space 不在该屏 → targetUnresolvable",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 3, targetDisplay: 2, displayInTopology: true,
                spaceOnDisplay: false, visibleSpaceOnSourceDisplay: 3) == .targetUnresolvable)
        check("fresh 决策: 可见 space == 目标 → notNeeded",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 3, targetDisplay: 2, displayInTopology: true,
                spaceOnDisplay: true, visibleSpaceOnSourceDisplay: 3) == .notNeeded)
        check("fresh 决策: 可见 space 未知 → switchNeeded(nil)（幂等尝试，不默认精确）",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 3, targetDisplay: 2, displayInTopology: true,
                spaceOnDisplay: true, visibleSpaceOnSourceDisplay: nil) == .switchNeeded(visibleSpace: nil))
        check("fresh 决策: 停在别的 space → switchNeeded(visible)",
              ToggleEngine.freshSourceSpacePreSwitch(
                sourceSpace: 5, targetDisplay: 2, displayInTopology: true,
                spaceOnDisplay: true, visibleSpaceOnSourceDisplay: 4) == .switchNeeded(visibleSpace: 4))
    }

    // MARK: - 3. performSourcePreSwitch fresh 路径

    private func runPerformSourcePreSwitchFreshTests() {
        // 记录：全局 space 3、display2、display-local 第 2 个
        let record = ToggleRecord(
            windowID: 42, pid: 1, bundleIdentifier: "test", appName: "t",
            origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            sourceSpace: 3, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 2,
            targetFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            targetDisplay: 1, toggledAt: Date(), sessionID: nil, reason: "manual")

        do {
            // 索引漂移 + 目标已可见：旧全局 3 在 display1，local 2 回译为 display2 的 5。
            let layout = [
                space(1, display: 1, visible: true),
                space(2, display: 1, visible: false),
                space(3, display: 1, visible: false),
                space(4, display: 2, visible: false),
                space(5, display: 2, visible: true),
            ]
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.spaceTopology = .available(layout)
            ch.geometricSourceDisplay = 2
            let ctx = ToggleEngine.performSourcePreSwitch(record: record, channels: ch, windowID: 42, trace: "b303-a")
            check("preSwitch fresh: 漂移回译 targetSpace=5（不是记录的 3）+ shifted 标记",
                  ctx.targetSpace == 5 && ctx.targetDisplay == 2
                  && ctx.spaceIndexShifted == true && ctx.spaceExact == true
                  && ctx.visibleOnSourceDisplay == 5)
            check("preSwitch fresh: 目标已可见 → 零切回动作、不读旧缓存 visible",
                  !ch.calls.contains("focus") && !ch.calls.contains("refocus")
                  && !ch.calls.contains("visible"))
        }

        do {
            // 缓存陈旧场景：fresh 拓扑显示源屏停在 4，目标回译为 5 → 必须切回 5。
            let layout = [
                space(1, display: 1, visible: true),
                space(4, display: 2, visible: true),
                space(5, display: 2, visible: false),
            ]
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.spaceTopology = .available(layout)
            ch.geometricSourceDisplay = 2
            ch.focusResult = true
            ch.visibleSpaceAfterSwitch = .yabaiIndex(5)
            let ctx = ToggleEngine.performSourcePreSwitch(record: record, channels: ch, windowID: 42, trace: "b303-b")
            check("preSwitch fresh: 源屏停在别处 → 直切回译目标 5（非记录 3）",
                  ctx.spaceExact == true && ch.focusReceived == .yabaiIndex(5)
                  && ctx.visibleOnSourceDisplay == 4)
            check("preSwitch fresh: 等到位轮询以回译目标为终态（切 5 等 5）",
                  ch.calls.filter { $0 == "visible" }.count == 1)
        }

        do {
            // 可见性未知（拓扑有屏但无 is-visible 项）：仍尝试幂等切回，不默认精确
            let layout = [
                space(1, display: 1, visible: false),
                space(5, display: 2, visible: false),
            ]
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.spaceTopology = .available(layout)
            ch.geometricSourceDisplay = 2
            ch.focusResult = true
            ch.visibleSpaceAfterSwitch = .yabaiIndex(5)
            let ctx = ToggleEngine.performSourcePreSwitch(record: record, channels: ch, windowID: 42, trace: "b303-c")
            check("preSwitch fresh: 可见性未知 → 仍切回并按轮询如实裁决",
                  ctx.visibleOnSourceDisplay == nil && ctx.spaceExact == true
                  && ch.focusReceived == .yabaiIndex(5))
        }

        do {
            // 源屏不在拓扑（拔屏/屏号漂移）：不盲切，spaceExact=false 如实降级
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.spaceTopology = .available([space(1, display: 1, visible: true)])
            ch.geometricSourceDisplay = 2
            let ctx = ToggleEngine.performSourcePreSwitch(record: record, channels: ch, windowID: 42, trace: "b303-d")
            check("preSwitch fresh: 源屏不在拓扑 → spaceExact=false，零切回动作",
                  ctx.spaceExact == false && !ch.calls.contains("focus")
                  && !ch.calls.contains("refocus") && ctx.targetSpace == 3
                  && ctx.targetDisplay == 2)
        }

        do {
            // 拓扑不可用 → 逐字回退旧路径（2s 缓存 + 记录全局索引）
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.visibleSpace = .yabaiIndex(3)
            let ctx = ToggleEngine.performSourcePreSwitch(record: record, channels: ch, windowID: 42, trace: "b303-e")
            check("preSwitch 回退: 拓扑不可用 → 旧路径 visible 缓存判定 + target=记录值",
                  ctx.spaceExact == true && ctx.targetSpace == 3 && ctx.targetDisplay == 2
                  && ctx.spaceTopology == "unavailable" && ctx.spaceIndexShifted == false
                  && ch.calls.contains("visible") && ch.topologyQueries == 1)
        }

        do {
            // 无 space 上下文（sourceSpace=0）：不查拓扑、不走预切回
            let noSpace = ToggleRecord(
                windowID: 42, pid: 1, bundleIdentifier: "test", appName: "t",
                origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
                sourceSpace: 0, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 2,
                targetFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                targetDisplay: 1, toggledAt: Date(), sessionID: nil, reason: "manual")
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let ctx = ToggleEngine.performSourcePreSwitch(record: noSpace, channels: ch, windowID: 42, trace: "b303-f")
            check("preSwitch: sourceSpace=0 → spaceExact=nil、targetSpace=nil、零拓扑查询",
                  ctx.spaceExact == nil && ctx.targetSpace == nil
                  && ch.topologyQueries == 0 && !ch.calls.contains("visible"))
        }
    }

    // MARK: - 4. verifyLandingSpace / landingSpaceExact

    private func runLandingVerificationTests() {
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.landingSpace = 5
            let obs = ToggleEngine.verifyLandingSpace(windowID: 42, targetSpace: 5, channels: ch, trace: "b303-l1")
            check("落位复核: 首查即中 → landed=5，checks=1（零补看）",
                  obs.landedSpace == 5 && obs.checks == 1 && ch.landingSpaceQueries == 1)
        }
        do {
            // 落错 → 补看后落定：队列 [4,5]
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.landingSpaceQueue = [4, 5]
            let obs = ToggleEngine.verifyLandingSpace(windowID: 42, targetSpace: 5, channels: ch, trace: "b303-l2")
            check("落位复核: 首查落错→补看到位 → landed=5，checks=2",
                  obs.landedSpace == 5 && obs.checks == 2 && ch.landingSpaceQueries == 2)
        }
        do {
            // 一直落错 → 预算耗尽如实上报（1 首查 + 首轮条件 + 6 次 50ms 补看）
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.landingSpace = 4
            let obs = ToggleEngine.verifyLandingSpace(windowID: 42, targetSpace: 5, channels: ch, trace: "b303-l3")
            check("落位复核: 持续落错 → landed=4 如实上报，checks 走满 300ms 预算",
                  obs.landedSpace == 4 && obs.checks == 8 && ch.landingSpaceQueries == 8)
        }
        do {
            // 查询失败 = 未知，不轮询（未知≠落错）
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.landingSpace = nil
            let obs = ToggleEngine.verifyLandingSpace(windowID: 42, targetSpace: 5, channels: ch, trace: "b303-l4")
            check("落位复核: 查询失败 → landed=nil、checks=1、不轮询",
                  obs.landedSpace == nil && obs.checks == 1 && ch.landingSpaceQueries == 1)
        }
        do {
            check("落位裁决: 落位==目标 → true（覆盖预切回 false）",
                  ToggleEngine.landingSpaceExact(preSwitch: false, landedSpace: 5, targetSpace: 5) == true)
            check("落位裁决: 落位≠目标 → false（覆盖预切回 true）",
                  ToggleEngine.landingSpaceExact(preSwitch: true, landedSpace: 4, targetSpace: 5) == false)
            check("落位裁决: 落位未知 → 沿用预切回结论",
                  ToggleEngine.landingSpaceExact(preSwitch: true, landedSpace: nil, targetSpace: 5) == true
                  && ToggleEngine.landingSpaceExact(preSwitch: nil, landedSpace: nil, targetSpace: 5) == nil)
            check("落位裁决: 无目标 space → 沿用预切回结论（不拿无关 space 比较）",
                  ToggleEngine.landingSpaceExact(preSwitch: false, landedSpace: 5, targetSpace: nil) == false)
        }
    }

    // MARK: - 5. performRestore 集成（fresh 目标 + 落位裁决进结局/审计）

    private func runRestoreLandingIntegrationTests() {
        func record() -> ToggleRecord {
            ToggleRecord(
                windowID: 42, pid: 100, bundleIdentifier: nil, appName: "Test",
                origFrame: CGRect(x: 3200, y: 200, width: 800, height: 600),
                sourceSpace: 3, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 2,
                targetFrame: CGRect(x: 0, y: 0, width: 800, height: 600), targetDisplay: 1,
                toggledAt: Date(), sessionID: nil)
        }
        // display2 的 local 2 已漂移为全局 5（记录里的 3 属于 display1）
        let layout = [
            space(1, display: 1, visible: true),
            space(2, display: 1, visible: false),
            space(3, display: 1, visible: false),
            space(4, display: 2, visible: false),
            space(5, display: 2, visible: true),
        ]
        func run(landing: Int?) -> (ToggleEngine.RestoreOutcome, FakeAuditor, FakeRestoreChannels) {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            ch.spaceTopology = .available(layout)
            ch.geometricSourceDisplay = 2
            ch.queryResult = window(id: 42, space: 1, minimized: false)
            ch.landingSpace = landing
            let rec = FakeRecords(record: record())
            let win = FakeWindows(findResult: AXUIElementCreateSystemWide(), moveResult: true)
            let aud = FakeAuditor()
            let outcome = ToggleEngine.performRestore(
                windowID: 42, triggerSource: "b303-integration", traceID: "b303-i",
                records: rec, windows: win, channels: ch, auditor: aud)
            return (outcome, aud, ch)
        }

        do {
            let (outcome, aud, _) = run(landing: 5)
            check("集成: 落位==回译目标 → restored(true)，审计带 targetSpace/landedSpace",
                  outcome == .restored(spaceExact: true)
                  && aud.events.count == 1
                  && aud.events[0].details["targetSpace"] == "5"
                  && aud.events[0].details["landedSpace"] == "5"
                  && aud.events[0].details["spaceIndexShifted"] == "true")
        }
        do {
            // 旧机制会在这里报 true（frame 收敛 + 预切回 notNeeded），真实落位 3 → 必须 false
            let (outcome, aud, _) = run(landing: 3)
            check("集成: 落位≠回译目标 → restored(false)（错工作区不再伪装成精确）",
                  outcome == .restored(spaceExact: false)
                  && aud.events[0].details["landedSpace"] == "3"
                  && aud.events[0].details["targetSpace"] == "5"
                  && aud.events[0].details["spaceExact"] == "Optional(false)")
        }
        do {
            // 落位查询失败 → 沿用预切回结论（未知不冒充精确，也不冒充失败）
            let (outcome, aud, _) = run(landing: nil)
            check("集成: 落位未知 → 沿用预切回 true，审计 landedSpace=unknown",
                  outcome == .restored(spaceExact: true)
                  && aud.events[0].details["landedSpace"] == "unknown")
        }
    }
}
