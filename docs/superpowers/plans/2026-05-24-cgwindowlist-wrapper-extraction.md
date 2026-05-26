# CGWindowListCopyWindowInfo Typed Wrapper Extraction

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Extract a typed `CGWindowEntry` struct and `cgWindowListAll()` helper to replace all 11 raw `[String: Any]` dictionary access patterns across 9 files.

**Architecture:** Single `CGWindowEntry` struct with failable initializer parses `[String: Any]` once, exposing typed properties. A top-level `cgWindowListAll()` function wraps the CG API call. All 11 call sites migrate from raw dictionary access to typed property access. Data flow: `CGWindowListCopyWindowInfo` → `[CGWindowEntry]` → typed filtering/lookup.

**Tech Stack:** Swift 5.9, CoreGraphics CGWindow API, macOS 14+

**Risks:**
- All 11 sites have subtly different filtering — must preserve exact semantics per site
- `kCGWindowBounds` is a nested `[String: CGFloat]` dict — needs careful CGRect conversion
- Some sites access `"kCGWindowName"` (with quotes in key) vs `kCGWindowName` constant — both must work
- ShutdownSnapshotManager and TerminalRestoreService use bounds differently (dict vs CGRect)

**Autonomy Level:** Full

---

### Task 1: Create CGWindowEntry wrapper

**Depends on:** None
**Files:**
- Create: `Sources/Support/CGWindowEntry.swift`

- [ ] **Step 1: Create CGWindowEntry struct with typed properties and cgWindowListAll() function**

```swift
import CoreGraphics
import Foundation

struct CGWindowEntry {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect?
    let name: String?
    let isOnScreen: Bool

    init?(from dict: [String: Any]) {
        guard let windowID = dict[kCGWindowNumber as String] as? UInt32,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = dict[kCGWindowOwnerName as String] as? String
        self.layer = dict[kCGWindowLayer as String] as? Int ?? 0
        self.name = dict["kCGWindowName"] as? String ?? dict["name"] as? String
        self.isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? true

        if let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] {
            self.bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
        } else {
            self.bounds = nil
        }
    }
}

func cgWindowListAll() -> [CGWindowEntry] {
    guard let rawList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return rawList.compactMap { CGWindowEntry(from: $0) }
}
```

- [ ] **Step 2: Verify compilation**
Run: `swift build 2>&1 | head -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: Commit**
Run: `git add Sources/Support/CGWindowEntry.swift && git commit -m "refactor(support): add CGWindowEntry typed wrapper for CGWindowListCopyWindowInfo"`

---

### Task 2: Migrate WindowManager files (4 files, 5 call sites)

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+ScreenPosition.swift:11-40`
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:326-355`
- Modify: `Sources/Window/WindowManager+Finding.swift:82-221`
- Modify: `Sources/Window/WindowManager+SystemEvents.swift:143-163`
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:168-195`

- [ ] **Step 1: Migrate WindowManager+ScreenPosition.swift — replace raw CGWindowList with cgWindowListAll()**

Replace the `isWindowOnMainScreen` method body (lines 17-40) to use `cgWindowListAll()`:

```swift
    func isWindowOnMainScreen(windowID: UInt32) -> Bool {
        log(
            "[WindowManager] isWindowOnMainScreen called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        let windows = cgWindowListAll()
        guard let entry = windows.first(where: { $0.windowID == windowID }) else {
            return false
        }
        guard let bounds = entry.bounds else {
            return false
        }
        return CoordinateKit.isMainScreen(bounds)
    }
```

- [ ] **Step 2: Migrate WindowManager+MoveWindow.swift — replace verifyWindowFrameViaCGWindowList**

Replace the CGWindowListCopyWindowInfo call (lines 333-355) in `verifyWindowFrameViaCGWindowList`:

```swift
    private func verifyWindowFrameViaCGWindowList(
        windowID: UInt32,
        targetFrame: CGRect,
        operationID: String
    ) -> Bool {
        let windows = cgWindowListAll()
        guard let entry = windows.first(where: { $0.windowID == windowID }) else {
            return false
        }
        guard let actualFrame = entry.bounds else {
            return false
        }

        let posDiff = abs(actualFrame.origin.x - targetFrame.origin.x) +
                     abs(actualFrame.origin.y - targetFrame.origin.y)
        let sizeDiff = abs(actualFrame.width - targetFrame.width) +
                      abs(actualFrame.height - targetFrame.height)
        let matched = posDiff < 30 && sizeDiff < 30

        if !matched {
            log(
                "[WindowManager] verifyWindowFrameViaCGWindowList: frame mismatch",
                level: .warn,
                fields: [
                    "op": operationID,
                    "windowID": String(windowID),
                    "actualFrame": String(describing: actualFrame),
                    "targetFrame": String(describing: targetFrame),
                    "posDiff": String(format: "%.1f", posDiff),
                    "sizeDiff": String(format: "%.1f", sizeDiff)
                ]
            )
        }
        return matched
    }
```

- [ ] **Step 3: Migrate WindowManager+Finding.swift — findClaudeCodeWindow**

Replace lines 82-124 in `findClaudeCodeWindow` to use `cgWindowListAll()`:

```swift
        let windows = cgWindowListAll()

        let projectName = cwd?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .last?
            .lowercased()

        let isHostApp = { (c: WindowCandidate) in
            TerminalRegistry.isTerminalOrIDEApp(appName: c.appName, bundleIdentifier: c.bundleIdentifier)
        }

        var candidates: [WindowCandidate] = []
        for entry in windows {
            guard entry.layer == 0 else { continue }

            let appName = entry.ownerName ?? ""
            let title = entry.name ?? ""
            let isOnMainScreen = isWindowOnMainScreen(windowID: entry.windowID)

            let bundleIdentifier: String?
            if let app = NSRunningApplication(processIdentifier: entry.ownerPID) {
                bundleIdentifier = app.bundleIdentifier
            } else {
                bundleIdentifier = nil
            }
```

Note: The rest of `findClaudeCodeWindow` (from `let candidate = WindowCandidate(...)` onward) stays unchanged. Only the window enumeration loop header and field access change.

- [ ] **Step 4: Migrate WindowManager+Finding.swift — findWindowByCGWindowID**

Replace lines 197-221 in `findWindowByCGWindowID`:

```swift
    func findWindowByCGWindowID(_ targetWindowID: UInt32) -> WindowIdentity? {
        let windows = cgWindowListAll()

        guard let entry = windows.first(where: { $0.windowID == targetWindowID }) else {
            return nil
        }
        let bundleID: String? = NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleIdentifier

        return WindowIdentity(
            windowID: targetWindowID,
            pid: entry.ownerPID,
            bundleIdentifier: bundleID,
            appName: entry.ownerName,
            windowNumber: Int(targetWindowID),
            title: entry.name
        )
    }
```

- [ ] **Step 5: Migrate WindowManager+SystemEvents.swift — systemEventsGetWindowID**

Replace lines 146-163 in `systemEventsGetWindowID`:

```swift
    private func systemEventsGetWindowID(forPID pid: pid_t) -> UInt32? {
        let windows = cgWindowListAll()
        return windows.first(where: { $0.ownerPID == pid && $0.layer == 0 })?.windowID
    }
```

- [ ] **Step 6: Migrate WindowManager+TerminalContext.swift — findWindowsForPID**

Replace lines 170-195 in `findWindowsForPID`:

```swift
    private func findWindowsForPID(_ pid: Int32) -> [WindowIdentity] {
        let windows = cgWindowListAll()

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (runShellCommand("/bin/ps", args: ["-o", "comm=", "-p", String(pid)])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown")
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        var results: [WindowIdentity] = []
        for entry in windows {
            guard entry.layer == 0 else { continue }
            guard entry.ownerPID == pid else { continue }

            results.append(WindowIdentity(
                windowID: entry.windowID,
                pid: entry.ownerPID,
                bundleIdentifier: bundleID,
                appName: appName,
                title: entry.name
            ))
        }
        return results
    }
```

- [ ] **Step 7: Verify compilation**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 8: Commit**
Run: `git add Sources/Window/ && git commit -m "refactor(window): migrate WindowManager files to CGWindowEntry typed wrapper"`

---

### Task 3: Migrate Hook and Toggle files (4 files, 6 call sites)

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Hook/HookEventHandler+WindowMove.swift:140-158`
- Modify: `Sources/Hook/SessionWindowRegistry.swift:162-186,267-276`
- Modify: `Sources/Toggle/ShutdownSnapshotManager.swift:126-175`
- Modify: `Sources/Toggle/TerminalRestoreService.swift:175-196`

- [ ] **Step 1: Migrate HookEventHandler+WindowMove.swift — binding age validation**

Replace lines 140-157 (the CGWindowListCopyWindowInfo block inside binding age check):

```swift
            if bindingAge > 1800 {
                let windows = cgWindowListAll()
                if let matchedEntry = windows.first(where: { $0.windowID == windowID }) {
                    if matchedEntry.ownerPID != binding.pid {
                        log(
                            "[HookEventHandler] \(triggerName) stale binding: window PID mismatch (binding age: \(Int(bindingAge))s)",
                            level: .warn,
                            fields: [
                                "sessionID": payload.sessionID,
                                "windowID": String(windowID),
                                "boundPID": String(binding.pid),
                                "actualPID": String(matchedEntry.ownerPID),
                                "bindingAge": String(Int(bindingAge))
                            ]
                        )
                        SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                        return (
```

Note: The rest of the function after this block stays unchanged. Only the window lookup changes.

- [ ] **Step 2: Migrate SessionWindowRegistry.swift — verifyBinding**

Replace lines 162-186 (the CGWindowListCopyWindowInfo block in `verifyBinding`):

```swift
        let windows = cgWindowListAll()
        if let matchedEntry = windows.first(where: { $0.windowID == windowID }) {
            if matchedEntry.ownerPID != expectedPID {
                log("[SessionWindowRegistry] verifyBinding failed: window owner PID mismatch", level: .warn, fields: [
                    "windowID": String(windowID),
                    "expectedPID": String(expectedPID),
                    "actualPID": String(matchedEntry.ownerPID)
                ])
            }
            return matchedEntry.ownerPID == expectedPID
        } else {
            log("[SessionWindowRegistry] verifyBinding failed: windowID \(windowID) not found in CGWindowList", level: .warn, fields: [
                "windowID": String(windowID),
                "expectedPID": String(expectedPID)
            ])
            return false
        }
```

- [ ] **Step 3: Migrate SessionWindowRegistry.swift — purgeClosedWindows**

Replace lines 267-276 (the CGWindowListCopyWindowInfo block in `purgeClosedWindows`):

```swift
    func purgeClosedWindows() {
        let windows = cgWindowListAll()
        var activeWindowIDs: Set<UInt32> = []
        for entry in windows {
            activeWindowIDs.insert(entry.windowID)
        }
```

- [ ] **Step 4: Migrate ShutdownSnapshotManager.swift — captureSnapshot**

Replace lines 126-175 (the CGWindowListCopyWindowInfo block and window loop in `captureSnapshot`):

```swift
        let windows = cgWindowListAll()

        // 按 PID 分组，过滤终端 App
        var pidToBundleID: [pid_t: String] = [:]
        var pidToAppName: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, isTerminalApp(bundleID) {
                pidToBundleID[app.processIdentifier] = bundleID
                pidToAppName[app.processIdentifier] = app.localizedName ?? bundleID
            }
        }

        let runningTerminalApps = Set(pidToBundleID.values)

        for entry in windows {
            guard let bundleID = pidToBundleID[entry.ownerPID],
                  let appName = pidToAppName[entry.ownerPID] else {
                continue
            }

            guard entry.layer == 0 else { continue }
            guard entry.bounds != nil else { continue }

            let title = entry.name ?? ""
```

Note: The rest of the loop body (creating TerminalWindowSnapshot) stays unchanged. The bounds dict access at line ~165 needs to change from `info[kCGWindowBounds as String] as? [String: CGFloat]` to use `entry.bounds` directly — verify the downstream usage of the bounds dict to use `entry.bounds!` instead.

- [ ] **Step 5: Migrate TerminalRestoreService.swift — enumerateExistingTerminalWindows**

Replace lines 175-196 (the entire `enumerateExistingTerminalWindows` method):

```swift
    private func enumerateExistingTerminalWindows() -> [ExistingWindow] {
        let windows = cgWindowListAll()

        return windows.compactMap { entry in
            guard entry.ownerName == "Terminal",
                  entry.layer == 0,
                  let frame = entry.bounds else {
                return nil
            }
            guard frame.width > 50, frame.height > 50 else { return nil }
            return ExistingWindow(windowID: entry.windowID, pid: entry.ownerPID, frame: frame, title: entry.name ?? "")
        }
    }
```

- [ ] **Step 6: Verify compilation**
Run: `swift build 2>&1 | head -30`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 7: Commit**
Run: `git add Sources/Hook/ Sources/Toggle/ && git commit -m "refactor(hook,toggle): migrate Hook and Toggle files to CGWindowEntry typed wrapper"`

---

### Task 4: Quality gate — verify no raw CGWindowListCopyWindowInfo calls remain

**Depends on:** Task 2, Task 3
**Files:** None (verification only)

- [ ] **Step 1: Grep for remaining raw CGWindowListCopyWindowInfo calls**
Run: `grep -rn "CGWindowListCopyWindowInfo" Sources/`
Expected:
  - Output contains ONLY: `Sources/Support/CGWindowEntry.swift` (the single wrapper)
  - No other files reference it

- [ ] **Step 2: Full build verification**
Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 3: Final commit (if any cleanup needed)**
Run: `git add -A && git commit -m "refactor: complete CGWindowListCopyWindowInfo wrapper migration"` (only if there are unstaged changes)
