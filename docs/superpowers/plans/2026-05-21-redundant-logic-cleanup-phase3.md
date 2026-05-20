# Refactor: Phase 3 Redundant Logic Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Eliminate ~420 lines of remaining redundancy — ScreenOverlayManager yabai calls, duplicate shell runners, CGWindowList boilerplate, mainScreenHeight duplication, and dead code.

**Architecture:** ScreenOverlayManager currently has 6 raw Process() calls to yabai that bypass YabaiClient; 3 separate shell-runner helpers exist with identical logic; CGWindowListCopyWindowInfo iteration is copy-pasted in 11 places; mainScreenHeight is computed inline 6 times instead of using CoordinateKit.

**Tech Stack:** Swift 5.9, macOS 14+, YabaiClient (existing), CoordinateKit (existing)

**Scope:** Small
**Risk:** Low — all changes are pure delegation/replacement, no behavior changes

**Risks:**
- Task 1 modifies ScreenOverlayManager which has timing-sensitive overlay refresh → mitigate: keep existing semaphore timeout logic, just delegate Process() to YabaiClient
- Task 3 creates a shared CGWindowList helper → mitigate: exact same filter logic, just extracted

**Autonomy Level:** Full

---

### Task 1: Delegate ScreenOverlayManager yabai calls to YabaiClient

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift:147-207` (getYabaiDisplayIndex)
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:153-233` (queryYabaiSpaces, queryFocusedSpaceIndex)
- Modify: `Sources/Overlay/ScreenOverlayManager+Signal.swift:86-126` (registerYabaiSignals)
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:246-253` (unregisterYabaiSignals)

- [ ] **Step 1: Replace getYabaiDisplayIndex with YabaiClient delegation**

Replace the raw Process()+Pipe()+Semaphore+JSONSerialization in `ScreenOverlayManager+SpaceIndex.swift:getYabaiDisplayIndex(for:)` with `YabaiClient.run()` + JSON decode.

The current code (lines ~147-207) does:
1. `Process()` + `Pipe()` + `Semaphore` to call `yabai -m query --displays`
2. Manual `JSONSerialization.jsonObject` iteration
3. Match display by UUID → return index

Replace with:
```swift
func getYabaiDisplayIndex(for screen: NSScreen) -> Int? {
    let screenUUID = uuidForScreen(screen)
    guard let result = YabaiClient.run(arguments: ["-m", "query", "--displays"]),
          result.exitCode == 0 else {
        log("getYabaiDisplayIndex: yabai query failed", level: .debug)
        return nil
    }
    guard let data = result.stdout.data(using: .utf8),
          let displays = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        log("getYabaiDisplayIndex: JSON parse failed", level: .debug)
        return nil
    }
    for display in displays {
        if let uuid = display["uuid"] as? String, uuid == screenUUID {
            return display["index"] as? Int
        }
    }
    return cachedDisplayIndices[screenUUID]
}
```

- [ ] **Step 2: Replace queryYabaiSpaces with YabaiClient delegation**

Replace the raw Process()+Pipe()+Semaphore in `ScreenOverlayManager.swift:queryYabaiSpaces()` with `YabaiClient.run()`. Keep the `SpaceSnapshot` parsing logic but replace the Process boilerplate.

```swift
func queryYabaiSpaces() -> [SpaceSnapshot]? {
    guard let result = YabaiClient.run(arguments: ["-m", "query", "--spaces"]),
          result.exitCode == 0 else {
        log("queryYabaiSpaces: yabai query failed", level: .debug)
        return nil
    }
    guard let data = result.stdout.data(using: .utf8),
          let spaces = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        log("queryYabaiSpaces: JSON parse failed", level: .debug)
        return nil
    }
    return spaces.compactMap { space -> SpaceSnapshot? in
        guard let index = space["index"] as? Int else { return nil }
        return SpaceSnapshot(
            index: index,
            isVisible: space["is-visible"] as? Bool ?? false,
            hasFocus: space["has-focus"] as? Bool ?? false,
            display: space["display"] as? Int
        )
    }
}
```

- [ ] **Step 3: Replace queryFocusedSpaceIndex with YabaiClient delegation**

```swift
func queryFocusedSpaceIndex() -> Int? {
    guard let result = YabaiClient.run(arguments: ["-m", "query", "--spaces", "--space"]),
          result.exitCode == 0 else {
        log("queryFocusedSpaceIndex: yabai query failed", level: .debug)
        return nil
    }
    guard let data = result.stdout.data(using: .utf8),
          let space = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return space["index"] as? Int
}
```

- [ ] **Step 4: Replace signal registration Process calls with YabaiClient**

In `ScreenOverlayManager+Signal.swift`, replace the two `Process()` calls for signal list check and signal registration with `YabaiClient.run()`. Also replace `unregisterYabaiSignals()` in the main file.

- [ ] **Step 5: Verify build**
Run: `swift build 2>&1 | grep -i "error:"`
Expected:
  - Exit code: 0
  - Output is empty (no errors)

- [ ] **Step 6: Deploy and verify**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3 && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app && sleep 3 && ps aux | grep VibeFocus | grep -v grep | head -1`
Expected:
  - VibeFocus process is running

- [ ] **Step 7: Commit**
Run: `git add -A && git commit -m "refactor(overlay): delegate all ScreenOverlayManager yabai calls to YabaiClient"`

---

### Task 2: Unify three shell-runner helpers into one

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+MoveWindow.swift:18-34` (runShellCommand)
- Modify: `Sources/Support/Support+Diagnostics.swift:73-99` (runProcessForDiagnostics)
- Create: `Sources/Support/ShellRunner.swift`

- [ ] **Step 1: Create ShellRunner utility**

Create `Sources/Support/ShellRunner.swift` — a single shared shell command runner that replaces `runShellCommand`, `runProcessForDiagnostics`, and `SpaceController.runProcess`:

```swift
import Foundation

enum ShellRunner {
    @discardableResult
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 10) -> YabaiClient.YabaiResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return YabaiClient.YabaiResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    static func runShell(_ command: String) -> String? {
        let result = run(executable: "/bin/bash", arguments: ["-c", command])
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Replace runShellCommand in WindowManager+MoveWindow**

Replace the local `runShellCommand()` method with a call to `ShellRunner.runShell()`. The existing callers in MoveWindow use `runShellCommand("command")` which returns `String?` — same signature as `ShellRunner.runShell()`.

- [ ] **Step 3: Replace runProcessForDiagnostics in Support+Diagnostics**

Replace the local `runProcessForDiagnostics()` with `ShellRunner.run()`. Keep the logging wrapper but delegate the actual process execution.

- [ ] **Step 4: Verify build**
Run: `swift build 2>&1 | grep -i "error:"`
Expected:
  - Exit code: 0
  - Output is empty

- [ ] **Step 5: Deploy and verify**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3 && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app && sleep 3 && ps aux | grep VibeFocus | grep -v grep | head -1`
Expected:
  - VibeFocus process is running

- [ ] **Step 6: Commit**
Run: `git add -A && git commit -m "refactor(support): unify three shell-runner helpers into ShellRunner"`

---

### Task 3: Extract shared CGWindowList query helper and use CoordinateKit.mainScreenHeight

**Depends on:** None
**Files:**
- Create: `Sources/Support/CGWindowQuery.swift`
- Modify: `Sources/Window/WindowManager+Finding.swift:86-137`
- Modify: `Sources/Window/WindowManager+Finding.swift:203-225`
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:173-203`
- Modify: `Sources/Window/WindowManager+ScreenPosition.swift:18-55`
- Modify: `Sources/Window/WindowManager+WindowQuery.swift:25-50`
- Modify: `Sources/Space/SpaceController+Switch.swift` (mainScreenHeight)
- Modify: `Sources/Space/NativeSpaceBridge.swift` (mainScreenHeight)
- Modify: `Sources/Toggle/ToggleEngine.swift` (mainScreenHeight)

- [ ] **Step 1: Create CGWindowQuery helper**

Create `Sources/Support/CGWindowQuery.swift`:

```swift
import CoreGraphics
import Foundation

struct CGWindowInfo {
    let windowID: UInt32
    let pid: pid_t
    let appName: String
    let title: String
    let layer: Int
    let bounds: CGRect
}

enum CGWindowQuery {
    static func listWindows(excludeDesktopElements: Bool = true) -> [CGWindowInfo] {
        let options: CGWindowListOption = excludeDesktopElements
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionOnScreenOnly]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowList.compactMap { info -> CGWindowInfo? in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
                return nil
            }
            let appName = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let x = bounds?["X"] as? CGFloat ?? 0
            let y = bounds?["Y"] as? CGFloat ?? 0
            let w = bounds?["Width"] as? CGFloat ?? 0
            let h = bounds?["Height"] as? CGFloat ?? 0
            return CGWindowInfo(windowID: windowID, pid: pid, appName: appName, title: title, layer: layer, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
    }
}
```

- [ ] **Step 2: Replace CGWindowList iteration in findClaudeCodeWindow**

In `WindowManager+Finding.swift`, replace the manual `CGWindowListCopyWindowInfo` + iteration with `CGWindowQuery.listWindows()`, mapping each `CGWindowInfo` to the existing `WindowCandidate` struct.

- [ ] **Step 3: Replace CGWindowList iteration in other WindowManager extensions**

Replace the same pattern in:
- `findWindowByCGWindowID` (Finding.swift:203)
- `findWindowsForPID` (TerminalContext.swift:173)
- `isWindowOnMainScreen` (ScreenPosition.swift:18) — use `CGWindowQuery.listWindows().first { $0.windowID == windowID }` then check bounds vs mainScreen
- `validateWindowExists` (WindowQuery.swift:25) — same pattern

- [ ] **Step 4: Replace mainScreenHeight with CoordinateKit.mainScreenHeight**

In these files, replace `NSScreen.screens[0].frame.height` and `NSScreen.screens.first?.frame.height ?? 0` with `CoordinateKit.mainScreenHeight`:
- `SpaceController+Switch.swift` (lines ~222, 263, 413)
- `NativeSpaceBridge.swift` (line ~168)
- `ToggleEngine.swift` (line ~160)
- `TerminalRestoreService.swift` (line ~275)
- `ShutdownSnapshotManager.swift` (line ~182)

- [ ] **Step 5: Verify build**
Run: `swift build 2>&1 | grep -i "error:"`
Expected:
  - Exit code: 0
  - Output is empty

- [ ] **Step 6: Deploy and verify**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3 && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app && sleep 3 && ps aux | grep VibeFocus | grep -v grep | head -1`
Expected:
  - VibeFocus process is running

- [ ] **Step 7: Commit**
Run: `git add -A && git commit -m "refactor(support): extract CGWindowQuery helper and use CoordinateKit.mainScreenHeight"`

---

### Task 4: Delete dead code and remove unused imports

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+WindowQuery.swift` (delete validateWindowExists)
- Modify: `Sources/Window/WindowManager+Finding.swift` (remove Carbon/CoreFoundation imports)
- Modify: `Sources/Window/WindowManager+TerminalContext.swift` (remove Carbon/CoreFoundation imports)
- Modify: `Sources/Window/WindowManager+MoveWindow.swift` (remove Carbon/CoreFoundation imports)
- Modify: `Sources/Overlay/ScreenOverlayManager.swift` (delete duplicate uuidForScreen if found)

- [ ] **Step 1: Delete validateWindowExists**

In `WindowManager+WindowQuery.swift`, the function `validateWindowExists(windowID:)` has zero external callers. Delete it.

- [ ] **Step 2: Remove unused Carbon and CoreFoundation imports**

Remove `import Carbon` and `import CoreFoundation` from:
- `WindowManager+Finding.swift`
- `WindowManager+TerminalContext.swift`
- `WindowManager+MoveWindow.swift`

These imports are vestiges of previously-deleted code.

- [ ] **Step 3: Verify build**
Run: `swift build 2>&1 | grep -i "error:"`
Expected:
  - Exit code: 0
  - Output is empty

- [ ] **Step 4: Deploy and verify**
Run: `bash scripts/dev-build.sh 2>&1 | tail -3 && killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app && sleep 3 && ps aux | grep VibeFocus | grep -v grep | head -1`
Expected:
  - VibeFocus process is running

- [ ] **Step 5: Commit**
Run: `git add -A && git commit -m "refactor: delete dead validateWindowExists and remove unused Carbon/CoreFoundation imports"`
