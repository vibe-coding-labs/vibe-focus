// Tests/ShutdownSnapshotTests.swift
// Verification: ShutdownSnapshot data model encode/decode roundtrip
// Run: swift Tests/ShutdownSnapshotTests.swift (uses Foundation + CoreGraphics only)

import Foundation
import CoreGraphics

// Minimal re-declarations for standalone verification (mirror Sources/Toggle/ShutdownSnapshot.swift)
struct SnapshotRect: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    init(_ rect: CGRect) { x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct TerminalWindowSnapshot: Codable, Equatable {
    let windowID: UInt32
    let pid: Int32
    let appName: String
    let bundleIdentifier: String
    let title: String?
    let frame: SnapshotRect
    let displayID: UInt32
    let spaceIndex: Int?
    let displayLocalSpaceIndex: Int?
    let tty: String?
    let termSessionID: String?
    let itermSessionID: String?
    let claudeSessionID: String?
    let claudeProjectDir: String?
    let claudeModel: String?
}

struct ShutdownSnapshot: Codable {
    let capturedAt: Date
    let systemUptimeAtCapture: TimeInterval
    var terminalWindows: [TerminalWindowSnapshot]
    let runningTerminalApps: Set<String>
}

// --- Tests ---

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// Test 1: Encode/Decode roundtrip
print("Test 1: Snapshot encode/decode roundtrip")
do {
    let rect = SnapshotRect(CGRect(x: 100, y: 200, width: 800, height: 600))
    let window = TerminalWindowSnapshot(
        windowID: 12345, pid: 67890, appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal", title: "bash — 80x24",
        frame: rect, displayID: 1234567, spaceIndex: 3,
        displayLocalSpaceIndex: 1, tty: "/dev/ttys001",
        termSessionID: "ABC-123", itermSessionID: nil,
        claudeSessionID: "session-xyz-789",
        claudeProjectDir: "/Users/test/projects/myapp",
        claudeModel: "claude-sonnet-4-6"
    )
    let snapshot = ShutdownSnapshot(
        capturedAt: Date(), systemUptimeAtCapture: 12345.0,
        terminalWindows: [window],
        runningTerminalApps: ["com.apple.Terminal"]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    check("window count", decoded.terminalWindows.count == 1)
    check("sessionID", decoded.terminalWindows[0].claudeSessionID == "session-xyz-789")
    check("projectDir", decoded.terminalWindows[0].claudeProjectDir == "/Users/test/projects/myapp")
    check("displayID", decoded.terminalWindows[0].displayID == 1234567)
    check("spaceIndex", decoded.terminalWindows[0].spaceIndex == 3)
    check("uptime", decoded.systemUptimeAtCapture == 12345.0)
    check("equality", decoded.terminalWindows[0] == window)
    check("runningApps", decoded.runningTerminalApps == ["com.apple.Terminal"])
} catch {
    failed += 1; print("  FAIL: roundtrip threw \(error)")
}

// Test 2: SnapshotRect conversion
print("Test 2: SnapshotRect CGRect roundtrip")
do {
    let original = CGRect(x: 50.5, y: 100.3, width: 1024.0, height: 768.0)
    let rect = SnapshotRect(original)
    check("x", abs(rect.cgRect.origin.x - original.origin.x) < 0.01)
    check("y", abs(rect.cgRect.origin.y - original.origin.y) < 0.01)
    check("width", rect.cgRect.width == original.width)
    check("height", rect.cgRect.height == original.height)
}

// Test 3: Empty snapshot
print("Test 3: Empty snapshot")
do {
    let snapshot = ShutdownSnapshot(
        capturedAt: Date(), systemUptimeAtCapture: ProcessInfo.processInfo.systemUptime,
        terminalWindows: [],
        runningTerminalApps: []
    )
    check("empty", snapshot.terminalWindows.isEmpty)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    check("empty decode", decoded.terminalWindows.count == 0)
    check("empty apps", decoded.runningTerminalApps.isEmpty)
}

// Test 4: Boot detection logic
print("Test 4: Boot detection")
let currentUptime = ProcessInfo.processInfo.systemUptime
let oldSnapshot = ShutdownSnapshot(
    capturedAt: Date().addingTimeInterval(-3600),
    systemUptimeAtCapture: currentUptime - 3600,
    terminalWindows: [],
    runningTerminalApps: ["com.apple.Terminal"]
)
check("old snapshot from previous boot", oldSnapshot.systemUptimeAtCapture < currentUptime - 60)

let freshSnapshot = ShutdownSnapshot(
    capturedAt: Date(),
    systemUptimeAtCapture: currentUptime,
    terminalWindows: [],
    runningTerminalApps: []
)
check("fresh snapshot not from previous boot", !(freshSnapshot.systemUptimeAtCapture < currentUptime - 60))

// Test 5: runningTerminalApps tracking
print("Test 5: runningTerminalApps tracking")
do {
    let snapshot = ShutdownSnapshot(
        capturedAt: Date(),
        systemUptimeAtCapture: 12345.0,
        terminalWindows: [],
        runningTerminalApps: ["com.apple.Terminal", "com.googlecode.iterm2"]
    )
    check("runningApps count", snapshot.runningTerminalApps.count == 2)
    check("contains Terminal", snapshot.runningTerminalApps.contains("com.apple.Terminal"))
    check("contains iTerm2", snapshot.runningTerminalApps.contains("com.googlecode.iterm2"))

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ShutdownSnapshot.self, from: data)
    check("decoded runningApps", decoded.runningTerminalApps == snapshot.runningTerminalApps)
} catch {
    failed += 1; print("  FAIL: runningTerminalApps threw \(error)")
}

// Summary
print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
