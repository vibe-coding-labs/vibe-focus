# Refactor: Redundant Logic Cleanup — Phase 2

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Eliminate ~400 lines of redundant/duplicate logic and dead code across Space, Window, Hook, Overlay, and Toggle modules

**Architecture:** Delegation pattern — each redundant copy delegates to the canonical implementation (YabaiClient, TerminalRegistry, SpaceController), then the copy is removed. Dead code is deleted outright. No behavior changes.

**Tech Stack:** Swift 5.9, macOS 14+, yabai window manager

**Scope:** Small
**Risk:** Low (dead code removal + delegation, no behavior changes)
**Risks:**
- Overlay module depends on ScreenOverlayManager's own yabai queries — migration must verify overlay still works after delegating to YabaiClient
- TerminalAppRegistry has 5 callers — must update all to TerminalRegistry before deleting

**Autonomy Level:** Full

---

### Task 1: Consolidate yabai path discovery into YabaiClient

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift:136-248`
- Modify: `Sources/Space/SpaceController+Recovery.swift:210-317`
- Modify: `Sources/Space/YabaiClient.swift`

- [ ] **Step 1: Expand YabaiClient.yabaiPath() to include shell fallback — match SpaceController's full discovery logic**

Read `Sources/Space/SpaceController+Recovery.swift:210-317` (the full `locateYabai()` and `getYabaiPathFromUserShell()`). Add shell fallback discovery to YabaiClient.yabaiPath() so it covers the same search paths as SpaceController (including `/bin/yabai` and user shell `which yabai`).

- [ ] **Step 2: Make SpaceController.locateYabai() fully delegate to YabaiClient.yabaiPath()**

Currently `locateYabai()` checks `YabaiClient.yabaiPath()` first (line 214) but then falls through to its own copy of the search. Replace the entire `locateYabai()` body with a single delegation call: `return YabaiClient.yabaiPath()`. Remove `getYabaiPathFromUserShell()` entirely.

- [ ] **Step 3: Make ScreenOverlayManager+SpaceIndex delegate to YabaiClient**

Replace `ScreenOverlayManager.getYabaiPath()` (lines 136-203) with a delegation to `YabaiClient.yabaiPath()`. Replace `getYabaiPathFromUserShell()` (lines 205-248) with removal — YabaiClient handles this. Remove `cachedYabaiPath` property.

- [ ] **Step 4: Verify build + deploy**
Run: `swift build`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: Commit**
Run: `git add Sources/Space/YabaiClient.swift Sources/Space/SpaceController+Recovery.swift Sources/Overlay/ScreenOverlayManager+SpaceIndex.swift && git commit -m "refactor(space): consolidate all yabai path discovery into YabaiClient"`

---

### Task 2: Unify terminal app lists into TerminalRegistry

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+Finding.swift:130-137`
- Modify: `Sources/Toggle/ShutdownSnapshotManager.swift:123-128`
- Modify: `Sources/Hook/TerminalAppRegistry.swift`

- [ ] **Step 1: Replace WindowManager+Finding local `claudeHostApps` with TerminalRegistry.isTerminalBundleID()**

Replace `let claudeHostApps: Set<String> = [...]` (lines 130-137) with calls to `TerminalRegistry.shared.isTerminalBundleID(bundleID)` and `TerminalRegistry.shared.isIDEBundleID(bundleID)`. Remove the local set.

- [ ] **Step 2: Replace ShutdownSnapshotManager local `terminalBundleIDs` with TerminalRegistry**

Replace `let terminalBundleIDs: Set<String> = [...]` (lines 123-128) with `TerminalRegistry.shared.isTerminalBundleID(bundleID)`. Remove the local set.

- [ ] **Step 3: Replace TerminalAppRegistry callers with TerminalRegistry — then delete TerminalAppRegistry**

Search all callers of `TerminalAppRegistry` (SessionWindowRegistry.swift lines 28,46,109,116; WindowManager+TerminalContext.swift line 40). Replace each with `TerminalRegistry.shared`. Then delete `Sources/Hook/TerminalAppRegistry.swift`.

- [ ] **Step 4: Verify build + deploy**
Run: `swift build`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 5: Commit**
Run: `git add Sources/Window/WindowManager+Finding.swift Sources/Toggle/ShutdownSnapshotManager.swift Sources/Hook/TerminalAppRegistry.swift Sources/Hook/SessionWindowRegistry.swift Sources/Window/WindowManager+TerminalContext.swift && git commit -m "refactor(support): unify all terminal app lists into TerminalRegistry, delete TerminalAppRegistry wrapper"`

---

### Task 3: Delete dead code across 5 files

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager.swift:29-45` (RectPayload)
- Modify: `Sources/Window/WindowManager+WindowQuery.swift:52-100` (restoreWindow)
- Modify: `Sources/Window/WindowManager+Finding.swift:22-48` (candidateApplications)
- Modify: `Sources/Window/WindowManager+AXHelpers.swift:25-51` (isValidAXElement, CGWindowSnapshot)
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:26,28,39,60-86,269-283` (swipe vars, setupScreenNotifications, getCGSpaceIndex)
- Modify: `Sources/Hook/ClaudeHookModels.swift:99-101` (windowToken computed property)

- [ ] **Step 1: Remove RectPayload struct from WindowManager.swift**

Delete `struct RectPayload: Codable` (lines 29-45) — never referenced anywhere.

- [ ] **Step 2: Remove candidateApplications and WindowToken from WindowManager**

Delete `func candidateApplications(for token: WindowToken)` in WindowManager+Finding.swift (lines 22-48). Delete `struct WindowToken` in WindowManager.swift (lines 19-27). Delete `var windowToken` computed property in ClaudeHookModels.swift (lines 99-101).

- [ ] **Step 3: Remove restoreWindow(using:) from WindowManager+WindowQuery**

Delete `func restoreWindow(using token: WindowToken) -> AXUIElement?` (lines 52-100) — vestigial restore path, all restore now goes through ToggleEngine.

- [ ] **Step 4: Remove isValidAXElement and CGWindowSnapshot from WindowManager+AXHelpers**

Delete `func isValidAXElement(_:)` (lines 25-43) and `struct CGWindowSnapshot` (lines 45-51) — no external callers.

- [ ] **Step 5: Remove swipe/dead code from ScreenOverlayManager**

Delete `swipeEventMonitor` property (line 26), `lastSwipeTriggerAt` (line 28), `minSwipeTriggerInterval` (line 39), `setupScreenNotifications()` (lines 60-86), and `getCGSpaceIndex(for:)` stub (lines 269-283). Remove the commented-out call at line 49.

- [ ] **Step 6: Verify build + deploy**
Run: `swift build`
Expected:
  - Exit code: 0

- [ ] **Step 7: Commit**
Run: `git add -A && git commit -m "refactor: remove ~155 lines of dead code (RectPayload, WindowToken, candidateApplications, restoreWindow, isValidAXElement, CGWindowSnapshot, Overlay swipe vars, setupScreenNotifications, getCGSpaceIndex)"`

---

### Task 4: Replace NSLog with structured log()

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController.swift:68,74,81`
- Modify: `Sources/Space/SpaceController+Recovery.swift:211,241,250,259,266,270`
- Modify: `Sources/HotKey/HotKeyManager.swift:47,49,52`

- [ ] **Step 1: Replace NSLog in SpaceController.swift with log()**

Replace `NSLog("[SpaceController] Initializing...")` → `log("[SpaceController] Initializing...")`
Replace `NSLog("[SpaceController] Deinit called")` → `log("[SpaceController] Deinit called")`
Replace `NSLog("[SpaceController] isEnabled changed to: \(newValue)")` → `log("[SpaceController] isEnabled changed", fields: ["newValue": String(newValue)])`

- [ ] **Step 2: Replace NSLog in SpaceController+Recovery.swift with log()**

Replace all 6 NSLog calls with structured `log()` calls. Note: after Task 1, `locateYabai()` will be a single delegation line, so most of these NSLog calls will already be removed. Only keep logging for the delegation call itself.

- [ ] **Step 3: Replace NSLog in HotKeyManager.swift with log()**

Replace 3 NSLog calls in HotKeyManager.swift with structured `log()` calls using fields.

- [ ] **Step 4: Verify build**
Run: `swift build`
Expected: Exit code: 0

- [ ] **Step 5: Commit**
Run: `git add Sources/Space/SpaceController.swift Sources/Space/SpaceController+Recovery.swift Sources/HotKey/HotKeyManager.swift && git commit -m "refactor(log): replace raw NSLog calls with structured log() for consistent log pipeline"`

---

### Task 5: Unify ShellResult into YabaiClient.YabaiResult

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController.swift:388-392`
- Modify: `Sources/Space/YabaiClient.swift:33-37`

- [ ] **Step 1: Make ShellResult a typealias of YabaiResult**

In SpaceController.swift, replace `struct ShellResult { let stdout, stderr, exitCode }` with `typealias ShellResult = YabaiClient.YabaiResult`. Adjust any field-order references if needed (YabaiResult has `exitCode, stdout, stderr` vs ShellResult's `stdout, stderr, exitCode`).

- [ ] **Step 2: Verify build**
Run: `swift build`
Expected: Exit code: 0

- [ ] **Step 3: Commit**
Run: `git add Sources/Space/SpaceController.swift Sources/Space/YabaiClient.swift && git commit -m "refactor(space): unify ShellResult into YabaiClient.YabaiResult typealias"`