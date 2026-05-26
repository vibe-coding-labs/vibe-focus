// Tests/Standalone/DataModelTests.swift
// Verification: TerminalContext, WindowState data model validation logic
// Mirrors: Sources/Hook/ClaudeHookModels.swift:47-117 (WindowState)
//          Sources/Hook/ClaudeHookModels.swift:157-203 (TerminalContext)
// Run: swift Tests/Standalone/DataModelTests.swift

import Foundation
import CoreGraphics

let mainScreenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

// MARK: - TerminalContext (mirrors ClaudeHookModels.swift:157-203)

struct TestTerminalContext: Equatable {
    let termSessionID: String?
    let itermSessionID: String?
    let kittyWindowID: String?
    let weztermPane: String?
    let tty: String?
    let ppid: String?
    let claudeProjectDir: String?
    let windowID: String?
    let machineLabel: String?

    var hasUsefulContext: Bool {
        if let tty, !tty.isEmpty { return true }
        if let termSessionID, !termSessionID.isEmpty { return true }
        if let itermSessionID, !itermSessionID.isEmpty { return true }
        if let ppid, let pid = Int32(ppid), pid > 1 { return true }
        if let machineLabel, !machineLabel.isEmpty { return true }
        return false
    }

    var isRemote: Bool {
        guard let label = machineLabel, !label.isEmpty else { return false }
        return true
    }
}

// MARK: - WindowState (mirrors ClaudeHookModels.swift:47-118)

struct TestWindowState: Equatable {
    var origX: CGFloat?
    var origY: CGFloat?
    var origW: CGFloat?
    var origH: CGFloat?
    var targetX: CGFloat?
    var targetY: CGFloat?
    var targetW: CGFloat?
    var targetH: CGFloat?

    var hasToggleState: Bool {
        origX != nil && targetX != nil
    }

    var originalFrame: CGRect? {
        guard let x = origX, let y = origY, let w = origW, let h = origH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var targetFrame: CGRect? {
        guard let x = targetX, let y = targetY, let w = targetW, let h = targetH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func isCorrupted(mainScreenFrame: CGRect) -> Bool {
        guard let orig = originalFrame, let tgt = targetFrame else { return false }
        let origCenter = CGPoint(x: orig.midX, y: orig.midY)
        let tgtCenter = CGPoint(x: tgt.midX, y: tgt.midY)
        return mainScreenFrame.contains(origCenter) && mainScreenFrame.contains(tgtCenter)
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - TerminalContext.hasUsefulContext

print("1. TerminalContext.hasUsefulContext")
do {
    let ctx1 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: "/dev/ttys003", ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has TTY → useful", ctx1.hasUsefulContext)

    let ctx2 = TestTerminalContext(
        termSessionID: "ABC123", itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has termSessionID → useful", ctx2.hasUsefulContext)

    let ctx3 = TestTerminalContext(
        termSessionID: nil, itermSessionID: "I:session", kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("has itermSessionID → useful", ctx3.hasUsefulContext)

    let ctx4 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "1234",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=1234 → useful", ctx4.hasUsefulContext)

    let ctx5 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "1",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=1 → NOT useful", !ctx5.hasUsefulContext)

    let ctx6 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: "", ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("empty TTY → NOT useful", !ctx6.hasUsefulContext)

    let ctx7 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("all nil → NOT useful", !ctx7.hasUsefulContext)

    let ctx8 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: "remote-mac"
    )
    check("has machineLabel → useful", ctx8.hasUsefulContext)

    let ctx9 = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: "invalid",
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("ppid=invalid (non-numeric) → NOT useful", !ctx9.hasUsefulContext)
}

// MARK: - TerminalContext.isRemote

print("\n2. TerminalContext.isRemote")
do {
    let remote = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: "remote-mac"
    )
    check("has machineLabel → remote", remote.isRemote)

    let local = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: nil
    )
    check("nil machineLabel → NOT remote", !local.isRemote)

    let empty = TestTerminalContext(
        termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
        weztermPane: nil, tty: nil, ppid: nil,
        claudeProjectDir: nil, windowID: nil, machineLabel: ""
    )
    check("empty machineLabel → NOT remote", !empty.isRemote)
}

// MARK: - WindowState.hasToggleState

print("\n3. WindowState.hasToggleState")
do {
    var ws1 = TestWindowState()
    ws1.origX = 100; ws1.targetX = 200
    check("both present → has toggle state", ws1.hasToggleState)

    var ws2 = TestWindowState()
    ws2.origX = 100; ws2.targetX = nil
    check("missing targetX → NO toggle state", !ws2.hasToggleState)

    var ws3 = TestWindowState()
    ws3.origX = nil; ws3.targetX = 200
    check("missing origX → NO toggle state", !ws3.hasToggleState)

    let ws4 = TestWindowState()
    check("all nil → NO toggle state", !ws4.hasToggleState)
}

// MARK: - WindowState.originalFrame / targetFrame

print("\n4. WindowState frame extraction")
do {
    var ws = TestWindowState()
    ws.origX = 1480; ws.origY = -710; ws.origW = 1145; ws.origH = 710
    ws.targetX = 75; ws.targetY = 38; ws.targetW = 1656; ws.targetH = 1070

    let origFrame = ws.originalFrame!
    checkEqual("origFrame.x", origFrame.origin.x, 1480.0)
    checkEqual("origFrame.y", origFrame.origin.y, -710.0)
    checkEqual("origFrame.width", origFrame.width, 1145.0)
    checkEqual("origFrame.height", origFrame.height, 710.0)

    let tgtFrame = ws.targetFrame!
    checkEqual("targetFrame.x", tgtFrame.origin.x, 75.0)
    checkEqual("targetFrame.y", tgtFrame.origin.y, 38.0)
}

print("\n5. WindowState frame extraction — missing fields")
do {
    var ws = TestWindowState()
    ws.origX = 100; ws.origY = nil; ws.origW = 500; ws.origH = 500
    check("missing origY → nil originalFrame", ws.originalFrame == nil)

    var ws2 = TestWindowState()
    ws2.targetX = 100; ws2.targetY = 200; ws2.targetW = nil; ws2.targetH = 500
    check("missing targetW → nil targetFrame", ws2.targetFrame == nil)
}

// MARK: - WindowState.isCorrupted

print("\n6. WindowState.isCorrupted")
do {
    var ws1 = TestWindowState()
    ws1.origX = 100; ws1.origY = 100; ws1.origW = 500; ws1.origH = 500
    ws1.targetX = 200; ws1.targetY = 200; ws1.targetW = 600; ws1.targetH = 600
    check("both on main screen → corrupted", ws1.isCorrupted(mainScreenFrame: mainScreenFrame))

    var ws2 = TestWindowState()
    ws2.origX = 1480; ws2.origY = -710; ws2.origW = 1145; ws2.origH = 710
    ws2.targetX = 75; ws2.targetY = 38; ws2.targetW = 1656; ws2.targetH = 1070
    check("orig off-screen → NOT corrupted", !ws2.isCorrupted(mainScreenFrame: mainScreenFrame))

    let ws3 = TestWindowState()
    check("no frames → NOT corrupted", !ws3.isCorrupted(mainScreenFrame: mainScreenFrame))
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
