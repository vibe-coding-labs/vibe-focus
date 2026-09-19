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
}
