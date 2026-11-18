import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXSizeWriteSeamTests.swift
// 靶：WindowManager AX 两阶段写（AXSizeWriteEnvironment 注入）——
// resizeViaAX 首轮收敛/两轮未收敛/写失败，apply 的 size 失败中止、
// position 失败、size 未匹配但 position 成功仍算成功。
// 零 AXUIElementSetAttributeValue、零真实睡眠。

final class AXSizeWriteSeamState: @unchecked Sendable {
    var writeOK = true
    var writeCalls = 0
    var readbackScript: [CGRect?] = []
    var readCalls = 0
    var lastReadWindowID: UInt32?
    var positionOK = true
    var positionCalls = 0
    var settles = 0

    func nextReadback() -> CGRect? {
        defer { readCalls += 1 }
        if readCalls < readbackScript.count { return readbackScript[readCalls] }
        return readbackScript.last ?? nil
    }
}

extension RunnerHarness {
    func runAXSizeWriteSeamTests() {
        let state = AXSizeWriteSeamState()
        let ax = AXUIElementCreateSystemWide()
        let target = CGRect(x: 20, y: 20, width: 800, height: 600)

        func makeEnv() -> AXSizeWriteEnvironment {
            AXSizeWriteEnvironment(
                writeSize: { _, _, _, _, _ in
                    state.writeCalls += 1
                    return (state.writeOK, 1)
                },
                readBounds: { windowID in
                    state.lastReadWindowID = windowID
                    return state.nextReadback()
                },
                writePosition: { _, _ in
                    state.positionCalls += 1
                    return state.positionOK
                },
                settle: { _ in state.settles += 1 }
            )
        }
        func reset() {
            state.writeOK = true
            state.writeCalls = 0
            state.readbackScript = []
            state.readCalls = 0
            state.lastReadWindowID = nil
            state.positionOK = true
            state.positionCalls = 0
            state.settles = 0
        }
        let wm = WindowManager.shared

        // A. size 首轮收敛
        reset()
        state.readbackScript = [CGRect(x: 0, y: 0, width: 800, height: 600)]
        let a = wm.resizeViaAX(targetFrame: target, window: ax, windowID: 7101,
                               op: "ut-ax", stage: "ut", environment: makeEnv())
        check("axSizeWrite A1: 首轮收敛 → true、写一次",
              a && state.writeCalls == 1 && state.lastReadWindowID == 7101)
        check("axSizeWrite A2: settle 由注入接管", state.settles == 1)

        // B. 两轮都不收敛 → false
        reset()
        state.readbackScript = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let b = wm.resizeViaAX(targetFrame: target, window: ax, windowID: 7101,
                               op: "ut-ax", stage: "ut", environment: makeEnv())
        check("axSizeWrite B1: 两轮未收敛 → false 且写两次",
              !b && state.writeCalls == 2 && state.settles == 2)

        // C. AX 写失败 → 立即 false（不再 settle）
        reset()
        state.writeOK = false
        let c = wm.resizeViaAX(targetFrame: target, window: ax, windowID: 7101,
                               op: "ut-ax", stage: "ut", environment: makeEnv())
        check("axSizeWrite C1: 写失败 → false、单次写、零 settle",
              !c && state.writeCalls == 1 && state.settles == 0)

        // D. apply：size 写失败 → 中止，不走 position
        reset()
        state.writeOK = false
        let d = wm.apply(frame: target, to: ax, operationID: "ut-ax",
                         stage: "ut", windowID: 7101, environment: makeEnv())
        check("axSizeWrite D1: size 失败 → apply false 且零 position",
              !d && state.positionCalls == 0)

        // E. apply：size 收敛但 position 失败 → false
        reset()
        state.readbackScript = [target]
        state.positionOK = false
        let e = wm.apply(frame: target, to: ax, operationID: "ut-ax",
                         stage: "ut", windowID: 7101, environment: makeEnv())
        check("axSizeWrite E1: position 失败 → apply false",
              !e && state.positionCalls == 1 && state.writeCalls == 1)

        // F. apply：size 未收敛但 position 成功 → true（axOK 语义）
        reset()
        state.readbackScript = [CGRect(x: 0, y: 0, width: 10, height: 10)]
        let f = wm.apply(frame: target, to: ax, operationID: "ut-ax",
                         stage: "ut", maxAttempts: 2, windowID: 7101, environment: makeEnv())
        check("axSizeWrite F1: size 未匹配但 position 成功 → true",
              f && state.writeCalls == 2 && state.positionCalls == 1)
    }
}
