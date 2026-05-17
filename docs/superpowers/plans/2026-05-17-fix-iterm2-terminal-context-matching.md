# Bug Fix: iTerm2 Terminal Context Window Matching Failure

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix iTerm2 terminal context window matching so that UserPromptSubmit auto-restore works when Claude Code runs inside iTerm2.

**Root Cause:** `findWindowByTerminalContext()` in `WindowManager+TerminalContext.swift` has three matching strategies, all of which fail for iTerm2:

1. **`matchWindowByTTYProcess`** (line 286-313): Matches window titles containing `— {command}` pattern. iTerm2 titles (like "✳ Claude Code") don't follow this format.
2. **`matchTerminalWindowByAppleScript`** (line 168-283): Uses `tell application "Terminal"` — only supports Apple Terminal.app, not iTerm2.
3. **TTY ordering fallback** (line 222-283): Uses `lsof -c Terminal` which filters by process name "Terminal" — doesn't match iTerm2's process name "iTerm2".

The `itermSessionID` (captured from `ITERM_SESSION_ID` env var, format: `w0t0p0:UUID`) is available in `TerminalContext` but **never used** for matching.

**Architecture:** iTerm2 AppleScript matching → use `itermSessionID` to query iTerm2 sessions via AppleScript, find the containing window, return its `WindowIdentity`. Inserted before the Terminal.app-specific fallback. Additionally fix the lsof filter to work with iTerm2's process name.

**Tech Stack:** Swift 5.9, macOS 14+, iTerm2 AppleScript API

**Risks:**
- iTerm2 AppleScript requires Automation permission (already have NSAppleEventsUsageDescription in build) → low risk
- iTerm2 session `id` property format may differ across versions → parse UUID suffix for matching
- lsof `-c` filter change could broaden results → `-p` PID filter already constrains results

---

### Task 1: Add iTerm2 AppleScript Session Matching

**Depends on:** None
**Files:**
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:100-126` (insert iTerm2 matching before Terminal.app fallback)
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:168-283` (add iTerm2 AppleScript method)

- [ ] **Step 1: Insert iTerm2 matching branch in findWindowByTerminalContext**

Insert between the `matchWindowByTTYProcess` call (line 102) and the `matchTerminalWindowByAppleScript` call (line 112), add iTerm2-specific matching using the already-available `itermSessionID`.

File: `Sources/Window/WindowManager+TerminalContext.swift:101-118`

Replace the section from line 101 to line 126:

```swift
        // 用 TTY 上的进程 command 精确匹配窗口标题
        let matchedWindow = matchWindowByTTYProcess(tty: tty, windows: windows)
        if let match = matchedWindow {
            log(
                "[WindowManager] findWindowByTerminalContext: matched window by TTY process",
                fields: ["tty": tty, "windowID": String(match.windowID)]
            )
            return match
        }

        // iTerm2: 用 ITERM_SESSION_ID 通过 AppleScript 精确匹配
        if let itermSID = ctx.itermSessionID, !itermSID.isEmpty,
           let match = matchiTerm2WindowBySessionID(itermSessionID: itermSID, windows: windows) {
            log(
                "[WindowManager] findWindowByTerminalContext: matched iTerm2 window by session ID",
                fields: ["itermSessionID": itermSID, "windowID": String(match.windowID)]
            )
            return match
        }

        // Fallback: Terminal.app 的 CGWindowList 无窗口标题，用 AppleScript 按 TTY 查窗口 ID
        if let match = matchTerminalWindowByAppleScript(tty: tty, terminalPID: terminalPID, windows: windows) {
            log(
                "[WindowManager] findWindowByTerminalContext: matched window by AppleScript TTY lookup",
                fields: ["tty": tty, "windowID": String(match.windowID)]
            )
            return match
        }

        log(
            "[WindowManager] findWindowByTerminalContext: all matching methods failed among \(windows.count) windows",
            level: .warn,
            fields: ["tty": tty, "terminalPID": String(terminalPID), "itermSessionID": ctx.itermSessionID ?? "nil"]
        )
        return nil
```

- [ ] **Step 2: Add matchiTerm2WindowBySessionID method**

Insert the new private method before `matchTerminalWindowByAppleScript` (line 168).

File: `Sources/Window/WindowManager+TerminalContext.swift` (insert before line 168)

```swift
    /// 通过 ITERM_SESSION_ID 用 iTerm2 AppleScript API 查找窗口
    /// ITERM_SESSION_ID 格式: w{N}t{N}p{N}:{UUID}
    /// 遍历 iTerm2 所有窗口的 session，匹配 UUID 部分找到目标窗口
    private func matchiTerm2WindowBySessionID(itermSessionID: String, windows: [WindowIdentity]) -> WindowIdentity? {
        // 提取 UUID 部分（冒号后的部分）用于匹配
        let uuidPart: String
        if let colonRange = itermSessionID.range(of: ":") {
            uuidPart = String(itermSessionID[colonRange.upperBound...])
        } else {
            uuidPart = itermSessionID
        }

        guard !uuidPart.isEmpty else { return nil }

        let escapedUUID = uuidPart
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // AppleScript: 遍历 iTerm2 窗口和 session，匹配包含目标 UUID 的 session
        let script = """
        osascript -e 'tell application "iTerm2"
            set targetUUID to "\(escapedUUID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set sid to (id of s) as text
                        if sid contains targetUUID then
                            return (id of w) as text
                        end if
                    end repeat
                end repeat
            end repeat
            return ""
        end tell'
        """
        let result = runShellCommand("/bin/bash", args: ["-c", script])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !result.isEmpty, let windowID = UInt32(result) {
            log(
                "[WindowManager] matchiTerm2WindowBySessionID: found window by iTerm2 AppleScript",
                fields: ["itermSessionID": itermSessionID, "windowID": String(windowID)]
            )
            // 在候选窗口列表中查找匹配的
            if let match = windows.first(where: { $0.windowID == windowID }) {
                return match
            }
            // AppleScript 返回了有效的窗口 ID 但不在 CGWindowList 候选中，直接构造
            let appName = "iTerm2"
            let bundleID = "com.googlecode.iterm2"
            return WindowIdentity(
                windowID: windowID,
                pid: windows.first?.pid ?? 0,
                bundleIdentifier: bundleID,
                appName: appName,
                windowNumber: nil,
                title: nil,
                capturedAt: Date()
            )
        }

        log(
            "[WindowManager] matchiTerm2WindowBySessionID: AppleScript returned no match",
            level: .debug,
            fields: ["itermSessionID": itermSessionID, "result": result.isEmpty ? "(empty)" : result]
        )
        return nil
    }
```

- [ ] **Step 3: Build and verify compilation**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output does NOT contain: "error:"

- [ ] **Step 4: Deploy to running app**
Run: `bash scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build Succeeded" or "signed" or similar success indicator

- [ ] **Step 5: 提交**
Run: `git add Sources/Window/WindowManager+TerminalContext.swift && git commit -m "fix(terminal): add iTerm2 AppleScript session matching for window context resolution"`

---

### Task 2: Fix lsof Terminal Filter for iTerm2

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Window/WindowManager+TerminalContext.swift:222-262` (fix lsof filter)

- [ ] **Step 1: Remove Terminal-specific filter from lsof command**

The lsof fallback at line 224 uses `-c Terminal` which only matches Terminal.app process name. Since `-p` already constrains to the exact PID, the `-c` filter is redundant and incorrect for iTerm2.

File: `Sources/Window/WindowManager+TerminalContext.swift:224`

Replace:
```swift
        let lsofOutput = runShellCommand("/usr/sbin/lsof", args: ["-p", String(terminalPID), "-c", "Terminal"])
```

With:
```swift
        let lsofOutput = runShellCommand("/usr/sbin/lsof", args: ["-p", String(terminalPID)])
```

- [ ] **Step 2: Build and verify**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -10`
Expected:
  - Exit code: 0

- [ ] **Step 3: Deploy and test**
Run: `bash scripts/dev-build.sh 2>&1 | tail -20`
Expected:
  - Exit code: 0

- [ ] **Step 4: 提交**
Run: `git add Sources/Window/WindowManager+TerminalContext.swift && git commit -m "fix(terminal): remove Terminal-specific lsof filter for iTerm2 compatibility"`
