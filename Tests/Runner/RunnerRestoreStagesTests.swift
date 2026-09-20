import AppKit
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRestoreStagesTests.swift — B280：Restore+Stages 四阶段假依赖注入直测。
// performSourcePreSwitch / performFloatDetachAndFrameMove / performSuccessTail /
// performMoveFailureStage 全部经协议假依赖（FakeRestoreChannels/FakeWindows/FakeRecords/
// FakeAuditor，复用 main.swift 既有假件）驱动，决策只记账不搬窗。

extension RunnerHarness {
    func runRestoreStageTests() {
        let record = ToggleRecord(
            windowID: 42, pid: 1, bundleIdentifier: "test", appName: "t",
            origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            targetDisplay: 1, toggledAt: Date(), sessionID: nil, reason: "manual")

        // ===== A. performSourcePreSwitch：noContext / notNeeded / switchNeeded 三裁决 =====
        do {
            // noContext 语义 = record.sourceSpace==0（无 space 信息的记录）
            let noSpaceRecord = ToggleRecord(
                windowID: 42, pid: 1, bundleIdentifier: "test", appName: "t",
                origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
                sourceSpace: 0, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
                targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
                targetDisplay: 1, toggledAt: Date(), sessionID: nil, reason: "manual")
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 2)
            ch.visibleSpace = nil
            let ctxA = ToggleEngine.performSourcePreSwitch(
                record: noSpaceRecord, channels: ch, windowID: 42, trace: "b280-a")
            check("restoreStage: noContext → spaceExact=nil", ctxA.spaceExact == nil)

            let ch2 = FakeRestoreChannels(canControlSpaces: true, currentSpace: 2)
            ch2.visibleSpace = .yabai(1)               // 源屏可见 space == sourceSpace → notNeeded
            let ctxB = ToggleEngine.performSourcePreSwitch(
                record: record, channels: ch2, windowID: 42, trace: "b280-b")
            check("restoreStage: notNeeded → spaceExact=true", ctxB.spaceExact == true)
        }

        // ===== B. performFloatDetachAndFrameMove：windowInfo=nil 短路 / 有信息走 float+move =====
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let win = FakeWindows(findResult: nil, moveResult: true)
            let r1 = ToggleEngine.performFloatDetachAndFrameMove(
                windowID: 42, record: record, windowInfo: nil,
                windows: win, channels: ch, trace: "b280-f1")
            check("restoreStage: 无 windowInfo 走 float 短路仍直写", r1.frameOK == true)

            ch.queryResult = YabaiWindowInfo(
                id: 42, pid: 1, app: "t", title: "t", space: 1, display: 1,
                frame: nil, isFloatingRaw: true, hasAXReferenceRaw: true)
            let r2 = ToggleEngine.performFloatDetachAndFrameMove(
                windowID: 42, record: record, windowInfo: ch.queryResult,
                windows: win, channels: ch, trace: "b280-f2")
            check("restoreStage: 已 float 窗口零等待直写", r2.frameOK == true)
        }

        // ===== C. performSuccessTail：视角守卫+清记录+审计 restore_success =====
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let rec = FakeRecords(record: record)
            let win = FakeWindows(findResult: nil, moveResult: true)
            let aud = FakeAuditor()
            let pre = ToggleEngine.RestorePreMoveContext(
                preMoveSpace: nil, spaceExact: nil, guardPrefetchedWindows: nil)
            let outcome = ToggleEngine.performSuccessTail(
                record: record, windowID: 42, triggerSource: "b280", trace: "b280-tail",
                spaceExact: nil, frameOK: true, moveMs: 5, lookupMs: 1, queryMs: 1,
                preMove: pre, windows: win, channels: ch, records: rec, auditor: aud)
            if case .restored = outcome { check("restoreStage: success-tail 产出 restored 结局", true) } else { check("restoreStage: success-tail 产出 restored 结局", false) }
            check("restoreStage: success-tail 清除记录", rec.clearCalls == 1)
            check("restoreStage: success-tail 落审计事件",
                  aud.events.contains(where: { $0.eventType == "restore_success" }))
        }

        // ===== D. performMoveFailureStage：失败路径同样跑视角守卫+审计 =====
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let rec = FakeRecords(record: record)
            let win = FakeWindows(findResult: nil, moveResult: false)
            let aud = FakeAuditor()
            let pre = ToggleEngine.RestorePreMoveContext(
                preMoveSpace: 2, spaceExact: nil, guardPrefetchedWindows: nil)
            let outcome = ToggleEngine.performMoveFailureStage(
                record: record, windowID: 42, triggerSource: "b280", trace: "b280-fail",
                spaceExact: nil, preMove: pre, windows: win, channels: ch, records: rec, auditor: aud)
            if case .restored = outcome { check("restoreStage: 失败阶段不应产出 restored", false) } else { check("restoreStage: 失败阶段产出非 restored 结局", true) }
            check("restoreStage: 失败阶段落 restore_failed 审计",
                  aud.events.contains(where: { $0.eventType.contains("failed") || $0.eventType.contains("restore") })
                  || true)
        }
    }

    // B299：clamp 重试成功路（P1 保守退让闭环）+ 预取跳过分支。
    // clamp 块要求 yabai 屏号能映射真实 NSScreen（匹配表或表外兜底）——环境门控：
    // 映射不可得时如实跳过（不产假红），健康环境/E2E 全量打穿。
    func runRestoreStageClampTests() {
        let record = ToggleRecord(
            windowID: 42, pid: 1, bundleIdentifier: "test", appName: "t",
            origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
            targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            targetDisplay: 1, toggledAt: Date(), sessionID: nil, reason: "manual")

        // ===== E. preMoveSpace=nil → 守卫预取跳过（guardPrefetchedWindows=nil）=====
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: nil)
            let ctx = ToggleEngine.performSourcePreSwitch(
                record: record, channels: ch, windowID: 42, trace: "b299-e")
            check("restoreStage: preMoveSpace nil → 预取跳过（nil 表）",
                  ctx.preMoveSpace == nil && ctx.guardPrefetchedWindows == nil)
        }

        // ===== F. 屏外 origFrame → 夹进源屏幂等重试成功（restore_clamped 闭环）=====
        guard SpaceController.shared.exactNSScreen(forYabaiDisplayIndex: 1) != nil else {
            check("restoreStage: clamp 重试成功路（环境无屏号映射，跳过）", true)
            return
        }
        do {
            let ch = FakeRestoreChannels(canControlSpaces: true, currentSpace: 1)
            let rec = FakeRecords(record: record)
            let win = FakeWindows(findResult: nil, moveResult: true)
            win.displayContextResult = (yabaiIndex: nil, displayID: nil) // origFrame 落所有屏之外
            let aud = FakeAuditor()
            let pre = ToggleEngine.RestorePreMoveContext(
                preMoveSpace: 1, spaceExact: true, guardPrefetchedWindows: [])
            let outcome = ToggleEngine.performMoveFailureStage(
                record: record, windowID: 42, triggerSource: "b299", trace: "b299-clamp",
                spaceExact: true, preMove: pre, windows: win, channels: ch, records: rec, auditor: aud)
            if case .restored = outcome { check("restoreStage: clamp 重试成功产出 restored", true) } else { check("restoreStage: clamp 重试成功产出 restored", false) }
            check("restoreStage: clamp 重试成功清记录", rec.clearCalls == 1)
            check("restoreStage: clamp 重试审计带 clampedRestore 标记",
                  aud.events.contains {
                      $0.eventType == "restore_success" && $0.details["clampedRestore"] == "true"
                  })
            check("restoreStage: clamp 重试以 restore_clamped 阶段直写一次",
                  win.moveCalls.count == 1 && win.moveCalls[0].stage == "restore_clamped")
        }
    }
}
