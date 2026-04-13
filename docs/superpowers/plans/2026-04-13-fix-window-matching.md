# Fix Window Matching - SessionStart Binding & Terminal Context

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the root cause of window matching failures: SessionStart binds wrong terminal tab 75% of the time in multi-session scenarios, causing cascading failures in Stop (moves wrong window) and UserPromptSubmit (can't find saved state).

**Architecture:** Hook forwarder captures terminal context (TTY/PPID/TERM_SESSION_ID) → VibeFocus resolves TTY to window → SessionStart binds correct window → Stop/UserPromptSubmit use correct binding. The fix replaces JXA-based TTY resolution (broken by macOS Automation TCC) with CGWindowList + process info matching, and improves SessionStart fallback ordering.

**Tech Stack:** Swift 5, macOS CGWindowList API, POSIX process info (ps/lsof)

**Risks:**
- `lsof` might be slow for TTY-to-CWD resolution → mitigated by caching and using `ps` first
- Multiple tabs with same cwd basename could mismatch → mitigated by using full cwd path + terminal app PID filtering
- NSAppleScript attempt might also fail due to TCC → mitigated by keeping CGWindowList as primary path

---

## Log Analysis Evidence

### Bug 1: JXA -2700 Error (100% failure rate)
```
osascript failed (exit 1, scriptLength=550): execution error: Error: Error: Application can't be found. (-2700)
```
Every `findWindowByTerminalContext` call triggers 3 JXA scripts, all fail. Root cause: macOS Automation TCC permission not granted to VibeFocus.app. `osascript` launched from VibeFocus.app process can't send Apple Events to Terminal.app.

### Bug 2: SessionStart binds wrong window (75% wrong)
```
SessionStart bound cwd=/Users/.../Sleepy title="amz_book_outside — ✳ Claude Code..." windowID=96
SessionStart bound cwd=/Users/.../vibe-focus title="Sleepy — ⠂ Claude Code..." windowID=84
```
In multi-session scenarios, `captureFocusedWindowIdentity()` captures whichever terminal tab is currently focused, not the one that just started a Claude Code session.

### Bug 3: UserPromptSubmit sessionID mismatch (100% failure rate)
```
UserPromptSubmit no sessionID match, trying shouldRestoreCurrentWindow fallback
UserPromptSubmit no matching saved state savedStatesCount=2
```
Because SessionStart bound wrong window → Stop moves wrong window → saved state has wrong sessionID association → UserPromptSubmit can't find matching state.

### Bug 4: Stop moves wrong window
```
Stop triggered cwd=Sleepy sessionID=99a9eff2
Stop moving window windowID=96 title="amz_book_outside..."
```
Session `99a9eff2` (Sleepy) should use window 84 but Stop used window 96 (amz_book_outside tab) because the SessionStart binding was wrong.

---

### Task 1: Replace JXA TTY Matching with CGWindowList + Process Info

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManagerSupport.swift:319-435` (replace `findWindowByTTY`, `findTerminalAppWindowByTTY`, `findiTerm2WindowByTTY`)

- [ ] **Step 1: Replace `findWindowByTTY` with CGWindowList-based TTY resolution**

Replace the JXA-based TTY matching in `Sources/WindowManagerSupport.swift:319-335`. The new approach:
1. Get foreground process on TTY via `ps -t ttys001 -o pid=`
2. Get CWD of that process via `lsof -p <pid> -Fn`
3. Find Terminal/iTerm windows via CGWindowList
4. Match by CWD basename in window title

```swift
// Sources/WindowManagerSupport.swift:319-335 (replace findWindowByTTY method)

/// 通过 TTY 查找 Terminal.app / iTerm2 窗口
/// 新方案：使用 CGWindowList + 进程信息匹配，避免 JXA（macOS Automation TCC 限制）
private func findWindowByTTY(_ tty: String) -> WindowIdentity? {
    let fullTTY = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

    // 1. 获取该 TTY 上的前台进程
    guard let foregroundPID = getForegroundProcessOnTTY(fullTTY) else {
        log(
            "[WindowManager] findWindowByTTY: no foreground process on TTY",
            level: .warn,
            fields: ["tty": fullTTY]
        )
        return nil
    }

    // 2. 获取该进程的 CWD
    let processCWD = getCWDOfProcess(foregroundPID)

    // 3. 在 CGWindowList 中查找 Terminal.app 窗口
    if let identity = findTerminalWindowByCWDMatch(processCWD: processCWD, tty: fullTTY) {
        return identity
    }

    return nil
}

/// 通过 ps 命令获取指定 TTY 上的前台进程 PID
private func getForegroundProcessOnTTY(_ fullTTY: String) -> Int32? {
    let ttyName = fullTTY.hasPrefix("/dev/") ? String(fullTTY.dropFirst(5)) : fullTTY
    // ps -t ttys001 -o pid= 获取该 TTY 上所有进程
    // 取最后一个（通常是前台进程）
    let output = runShellCommand("/bin/ps", args: ["-t", ttyName, "-o", "pid="])
    guard let output else { return nil }

    let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 > 1 }

    // 返回最后一个 PID（前台进程）
    return pids.last
}

/// 通过 lsof 获取进程的 CWD
private func getCWDOfProcess(_ pid: Int32) -> String? {
    // lsof -p <pid> -Fn 2>/dev/null | grep "^n/" | head -1
    let output = runShellCommand("/usr/sbin/lsof", args: ["-p", String(pid), "-Fn"])
    guard let output else { return nil }

    let lines = output.components(separatedBy: "\n")
    // lsof -Fn 输出格式: n/Users/cc11001100/github/...
    // 第一个 n 开头的行通常是 CWD
    for line in lines {
        if line.hasPrefix("n/") {
            return String(line.dropFirst(1))
        }
    }
    return nil
}

/// 在 CGWindowList 中通过 CWD 匹配 Terminal.app 窗口
private func findTerminalWindowByCWDMatch(processCWD: String?, tty: String) -> WindowIdentity? {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    let cwdBasename = processCWD?
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .components(separatedBy: "/")
        .last?
        .lowercased()

    // Terminal.app 和 iTerm2 的进程名
    let terminalAppNames: Set<String> = ["Terminal", "iTerm2"]

    var candidates: [(windowID: UInt32, pid: pid_t, appName: String, title: String, cwdMatch: Bool)] = []

    for info in windowList {
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { continue }

        guard let windowID = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else {
            continue
        }

        let appName = info[kCGWindowOwnerName as String] as? String ?? ""
        let title = info["kCGWindowName"] as? String ?? info["name"] as? String ?? ""

        guard terminalAppNames.contains(appName) else { continue }

        let cwdMatch: Bool
        if let cwdBasename, !cwdBasename.isEmpty {
            cwdMatch = title.lowercased().contains(cwdBasename)
        } else {
            cwdMatch = false
        }

        candidates.append((windowID, pid, appName, title, cwdMatch))
    }

    // 优先匹配 CWD basename 在标题中的窗口
    if let cwdBasename, !cwdBasename.isEmpty {
        if let match = candidates.first(where: { $0.cwdMatch }) {
            let bundleID = NSRunningApplication(processIdentifier: match.pid)?.bundleIdentifier
            log(
                "[WindowManager] findWindowByTTY matched via CWD in title",
                fields: [
                    "tty": tty,
                    "cwdBasename": cwdBasename,
                    "app": match.appName,
                    "title": truncateForLog(match.title, limit: 80),
                    "windowID": String(match.windowID)
                ]
            )
            return WindowIdentity(
                windowID: match.windowID,
                pid: match.pid,
                bundleIdentifier: bundleID,
                appName: match.appName,
                windowNumber: nil,
                title: match.title,
                capturedAt: Date()
            )
        }
    }

    // 如果只有一个终端窗口，直接使用
    if candidates.count == 1, let match = candidates.first {
        let bundleID = NSRunningApplication(processIdentifier: match.pid)?.bundleIdentifier
        log(
            "[WindowManager] findWindowByTTY: only one terminal window, using it",
            fields: [
                "tty": tty,
                "app": match.appName,
                "title": truncateForLog(match.title, limit: 80),
                "windowID": String(match.windowID)
            ]
        )
        return WindowIdentity(
            windowID: match.windowID,
            pid: match.pid,
            bundleIdentifier: bundleID,
            appName: match.appName,
            windowNumber: nil,
            title: match.title,
            capturedAt: Date()
        )
    }

    log(
        "[WindowManager] findWindowByTTY: no CWD match found",
        level: .warn,
        fields: [
            "tty": tty,
            "cwdBasename": cwdBasename ?? "nil",
            "candidateCount": String(candidates.count)
        ]
    )
    return nil
}
```

- [ ] **Step 2: Remove old JXA methods `findTerminalAppWindowByTTY` and `findiTerm2WindowByTTY`**

Delete the old JXA-based methods in `Sources/WindowManagerSupport.swift:361-435`. These are:
- `findTerminalAppWindowByTTY` (lines 361-396)
- `findiTerm2WindowByTTY` (lines 399-435)

These methods used JXA `Application('Terminal')` / `Application('iTerm')` which fails with -2700 from VibeFocus.app process.

- [ ] **Step 3: Commit**

Run: `git add Sources/WindowManagerSupport.swift && git commit -m "fix(window-matching): replace JXA TTY matching with CGWindowList + process info"`

---

### Task 2: Improve SessionStart Window Binding

**Depends on:** Task 1
**Files:**
- Modify: `Sources/ClaudeHookServer.swift:182-239` (handleSessionStart method)

- [ ] **Step 1: Add cwd-based matching as secondary fallback in SessionStart handler**

When terminal context matching fails (which is common), use `findClaudeCodeWindow(cwd:)` before falling back to focused window. This is more reliable in multi-session scenarios because it matches by project name in window title.

File: `Sources/ClaudeHookServer.swift:203-205`

Replace:
```swift
// 回退：捕获当前焦点窗口
if identity == nil {
    identity = WindowManager.shared.captureFocusedWindowIdentity()
}
```

With:
```swift
// 回退策略 1：通过 cwd 项目名匹配窗口（多会话场景更准确）
if identity == nil, let cwd = payload.cwd {
    identity = WindowManager.shared.findClaudeCodeWindow(cwd: cwd)
    if let identity {
        log(
            "[ClaudeHookServer] SessionStart matched via cwd fallback",
            fields: [
                "sessionID": payload.sessionID,
                "cwd": cwd,
                "app": identity.appName ?? "unknown",
                "title": identity.title ?? "untitled",
                "windowID": String(identity.windowID)
            ]
        )
    }
}

// 回退策略 2：捕获当前焦点窗口（最后手段）
if identity == nil {
    identity = WindowManager.shared.captureFocusedWindowIdentity()
}
```

- [ ] **Step 2: Commit**

Run: `git add Sources/ClaudeHookServer.swift && git commit -m "fix(hooks): add cwd-based matching before focused window fallback in SessionStart"`

---

### Task 3: Bump Version and Verify

**Depends on:** Task 1, Task 2
**Files:**
- Modify: `Sources/AppVersion.swift`

- [ ] **Step 1: Bump version to 0.0.18**

File: `Sources/AppVersion.swift`

```swift
import Foundation

enum AppVersion {
    static let current = "0.0.18"
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: Commit**

Run: `git add Sources/AppVersion.swift && git commit -m "release: v0.0.18"`
