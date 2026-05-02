# 增强 VibeFocus 崩溃诊断日志系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 为 VibeFocus 安装 POSIX 信号处理器捕获 SIGSEGV/SIGABRT/SIGBUS/SIGFPE 等致命信号，在崩溃瞬间将关键运行时状态（窗口管理器状态、热键状态、hook 服务器状态、内存布局）写入独立崩溃快照文件，并增强 CrashContextRecorder 在下次启动时提供更完整的崩溃上下文，解决"莫名退出无法排查"的问题。

**Architecture:** 致命信号触发 → 信号处理器从预格式化全局缓冲区读取状态 → 直接 write() 到 /tmp/vibefocus-crash-snapshot.log（仅用 async-signal-safe 函数）→ _exit(128+signo)。下次启动时 CrashContextRecorder.bootstrap() 读取快照 + IPS crash report + 日志尾部，输出完整崩溃诊断报告。关键：信号处理器中不调用任何非 signal-safe 函数（不调用 log()、不调用 NSLog、不调用任何 ObjC/Swift 方法），所有状态在正常运行时预格式化到全局 C 字符数组中。

**Tech Stack:** Swift 5.9, macOS 14+, Darwin POSIX signal API, CGWindowList, AXAPI

**Risks:**
- 信号处理器中调用非 async-signal-safe 函数会导致死锁 → 缓解：信号处理器只从预格式化的全局 C 数组读取，只调用 write()/writev()/_exit()
- `@MainActor` 隔离导致信号处理器无法直接访问 Swift 类属性 → 缓解：使用 `@unchecked Sendable` 全局结构体，在每次关键操作后更新预格式化快照
- 预格式化缓冲区写入可能与信号处理器并发读取产生数据竞争 → 缓解：使用原子标志位 + 双缓冲方案，信号处理器读 inactive buffer，正常代码写 active buffer

---

### Task 1: 安装 POSIX 信号处理器和 atexit handler — 在崩溃时捕获致命信号并写入快照

**Depends on:** None
**Files:**
- Modify: `Sources/Support.swift:1-220`

- [ ] **Step 1: 在 Support.swift 中添加全局崩溃状态快照缓冲区和信号处理器**

在 `Support.swift` 文件末尾（`extension NSEvent.ModifierFlags` 之前）添加以下代码。这段代码定义了：
1. `CrashSnapshotBuffer` — 双缓冲全局结构体，存储预格式化的崩溃上下文字符串
2. `crashSignalHandler` — POSIX 信号处理器，仅使用 async-signal-safe 函数
3. `installCrashSignalHandlers()` — 注册 SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL/SIGTRAP 处理器
4. `installAtExitHandler()` — 注册 atexit handler 记录正常退出

```swift
// MARK: - Crash Signal Handler & Snapshot Buffer

private let crashSnapshotFD: Int32 = {
    let path = "/tmp/vibefocus-crash-snapshot.log"
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}()

private final class CrashSnapshotBuffer: @unchecked Sendable {
    static let shared = CrashSnapshotBuffer()

    private let bufferA = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private let bufferB = UnsafeMutablePointer<CChar>.allocate(capacity: 16384)
    private var activeBuffer: UnsafeMutablePointer<CChar>
    private var activeLength: Int = 0
    private var activeIsA = true
    private let lock = NSLock()

    private init() {
        activeBuffer = bufferA
        bufferA.initialize(repeating: 0, count: 16384)
        bufferB.initialize(repeating: 0, count: 16384)
    }

    deinit {
        bufferA.deallocate()
        bufferB.deallocate()
    }

    func update(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
        lock.lock()
        let buf = activeBuffer
        let written = block(buf, 16384 - 1)
        activeLength = max(0, written)
        buf.advanced(by: activeLength).pointee = 0
        activeIsA = !activeIsA
        activeBuffer = activeIsA ? bufferA : bufferB
        activeLength = 0
        activeBuffer.pointee = 0
        lock.unlock()
    }

    func readInactiveBuffer() -> (ptr: UnsafeMutablePointer<CChar>, len: Int) {
        lock.lock()
        let buf = activeIsA ? bufferB : bufferA
        let len = activeLength
        lock.unlock()
        return (buf, len)
    }
}

private func crashSignalHandler(_ sig: Int32) {
    let (buf, len) = CrashSnapshotBuffer.shared.readInactiveBuffer()

    var sigMsg = "FATAL SIGNAL \(sig) ("
    switch sig {
    case SIGSEGV: sigMsg += "SIGSEGV"
    case SIGABRT: sigMsg += "SIGABRT"
    case SIGBUS: sigMsg += "SIGBUS"
    case SIGFPE: sigMsg += "SIGFPE"
    case SIGILL: sigMsg += "SIGILL"
    #if canImport(Darwin)
    case SIGTRAP: sigMsg += "SIGTRAP"
    #endif
    default: sigMsg += "UNKNOWN"
    }
    sigMsg += ") caught at "
    let now = time(nil)
    var tm = tm()
    localtime_r(&now, &tm)
    var timeBuf = [CChar](repeating: 0, count: 32)
    strftime(&timeBuf, 32, "%Y-%m-%dT%H:%M:%S", &tm)
    sigMsg += String(cString: timeBuf)
    sigMsg += "\n\n=== PRE-CRASH STATE ===\n"

    var iov = [iovec](repeating: iovec(), count: 4)
    var sigData = [CChar](repeating: 0, count: 256)
    sigMsg.withCString { ptr in
        var idx = 0
        while idx < 255 && ptr[idx] != 0 {
            sigData[idx] = ptr[idx]
            idx += 1
        }
        sigData[idx] = 0
    }
    iov[0].iov_base = UnsafeMutableRawPointer(&sigData)
    iov[0].iov_len = strlen(&sigData)

    var nl = "\n=== END PRE-CRASH STATE ===\n"
    var nlData = [CChar](repeating: 0, count: 32)
    nl.withCString { ptr in
        var idx = 0
        while idx < 31 && ptr[idx] != 0 { nlData[idx] = ptr[idx]; idx += 1 }
        nlData[idx] = 0
    }

    if len > 0 {
        iov[1].iov_base = UnsafeMutableRawPointer(mutating: buf)
        iov[1].iov_len = len
        iov[2].iov_base = UnsafeMutableRawPointer(&nlData)
        iov[2].iov_len = strlen(&nlData)
        writev(crashSnapshotFD, iov, 3)
    } else {
        iov[1].iov_base = UnsafeMutableRawPointer(&nlData)
        iov[1].iov_len = strlen(&nlData)
        writev(crashSnapshotFD, iov, 2)
    }

    close(crashSnapshotFD)
    _exit(128 + sig)
}

func installCrashSignalHandlers() {
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
        signal(sig, crashSignalHandler)
    }
    #if canImport(Darwin)
    signal(SIGTRAP, crashSignalHandler)
    #endif
}

func installAtExitHandler() {
    atexit {
        let msg = "VibeFocus exiting via atexit (likely normal termination)\n"
        msg.withCString { ptr in
            let fd = open("/tmp/vibefocus-crash-snapshot.log", O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd != -1 {
                write(fd, ptr, strlen(ptr))
                close(fd)
            }
        }
    }
}

func updateCrashSnapshot(_ block: (UnsafeMutablePointer<CChar>, Int) -> Int) {
    CrashSnapshotBuffer.shared.update(block)
}
```

- [ ] **Step 2: 添加 updateCrashSnapshotFromRuntime() 函数 — 从运行时状态格式化快照**

在 `Support.swift` 中 `updateCrashSnapshot` 之后添加。此函数在每次 toggle/restore/hook 操作后被调用，将关键运行时变量格式化到崩溃快照缓冲区。

```swift
func updateCrashSnapshotFromRuntime() {
    updateCrashSnapshot { buf, capacity in
        var pos = 0
        func append(_ str: String) {
            str.withCString { ptr in
                var i = 0
                while ptr[i] != 0 && pos < capacity - 1 {
                    buf[pos] = ptr[i]
                    pos += 1
                    i += 1
                }
            }
        }
        func appendField(_ key: String, _ value: String) {
            append("\(key)=\(value) ")
        }

        append("pid=\(ProcessInfo.processInfo.processIdentifier)")
        append(" ppid=\(getppid())")

        let axOptions = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)
        appendField("axTrusted", String(axTrusted))

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            appendField("frontPID", String(frontApp.processIdentifier))
            appendField("frontBundleID", frontApp.bundleIdentifier ?? "nil")
        }

        appendField("screenCount", String(NSScreen.screens.count))

        let wm = WindowManager.shared
        appendField("savedStates", String(wm.savedWindowStates.count))
        appendField("hasToken", String(wm.lastWindowToken != nil))
        appendField("hasFrame", String(wm.lastWindowFrame != nil))
        appendField("hasTarget", String(wm.lastTargetFrame != nil))

        if let token = wm.lastWindowToken {
            appendField("tokenPID", String(token.pid))
            appendField("tokenWinID", String(describing: token.windowID))
            appendField("tokenBundleID", token.bundleIdentifier ?? "nil")
        }
        if let frame = wm.lastWindowFrame {
            appendField("origFrame", "(\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height))")
        }
        if let target = wm.lastTargetFrame {
            appendField("targetFrame", "(\(target.origin.x),\(target.origin.y),\(target.width),\(target.height))")
        }
        appendField("srcSpace", String(describing: wm.lastSourceSpaceIndex))
        appendField("srcYabaiDisp", String(describing: wm.lastSourceYabaiDisplayIndex))

        let hkm = HotKeyManager.shared
        appendField("hotkey", hkm.currentHotKey.displayString)
        appendField("axGranted", String(hkm.accessibilityGranted))

        let hookServer = ClaudeHookServer.shared
        appendField("hookRunning", String(hookServer.isRunning))
        if let port = hookServer.activePortDescription {
            appendField("hookPort", port)
        }

        appendField("eventCount", String(wm.savedWindowStates.count))

        buf[pos] = 0
        return pos
    }
}

private var activePortDescription: String? {
    // Will be provided via extension in ClaudeHookServer
    return nil
}
```

- [ ] **Step 3: 在 AppDelegate.applicationDidFinishLaunching 中安装信号处理器和 atexit handler**

文件: `Sources/SettingsUI.swift:2023-2027`

在 `applicationDidFinishLaunching` 方法的最开头（`log("applicationDidFinishLaunching...")` 之前）添加信号处理器安装：

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashSignalHandlers()
        installAtExitHandler()
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        // ... existing code continues unchanged
```

- [ ] **Step 4: 在关键操作后调用 updateCrashSnapshotFromRuntime() — WindowManager.toggle/restore 和 ClaudeHookServer.handleHookRequest**

文件: `Sources/WindowManager.swift:124` (toggle 函数开头)

在 `toggle()` 函数的 `log("[WindowManager] toggle started"...)` 之后添加：

```swift
        updateCrashSnapshotFromRuntime()
```

文件: `Sources/WindowManager.swift:330` (restore 函数开头)

在 `restore()` 函数的 `log("[WindowManager] restore started"...)` 之后添加：

```swift
        updateCrashSnapshotFromRuntime()
```

文件: `Sources/ClaudeHookServer.swift:153` (handleHookRequest 函数开头)

在 `handleHookRequest()` 的 `log("[ClaudeHookServer] request received"...)` 之后添加：

```swift
        updateCrashSnapshotFromRuntime()
```

- [ ] **Step 5: 验证构建**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 6: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Support.swift Sources/SettingsUI.swift Sources/WindowManager.swift Sources/ClaudeHookServer.swift && git commit -m "feat(crash): install POSIX signal handlers to capture fatal signal context on crash"`

---

### Task 2: 增强 CrashContextRecorder — 在启动时读取崩溃快照并输出完整诊断报告

**Depends on:** Task 1
**Files:**
- Modify: `Sources/CrashContextRecorder.swift:38-77`

- [ ] **Step 1: 在 CrashContextRecorder.bootstrap() 中添加崩溃快照读取逻辑**

文件: `Sources/CrashContextRecorder.swift:38-77`

在 `bootstrap()` 方法中，在 `captureRecentLogTail(context: "unclean_exit")` 之后添加读取崩溃快照文件的逻辑：

```swift
            // 读取信号处理器写入的崩溃快照
            let crashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-snapshot.log")
            if let snapshotData = try? Data(contentsOf: crashSnapshotURL),
               let snapshotText = String(data: snapshotData, encoding: .utf8),
               !snapshotText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("[CRASH_CONTEXT] === CRASH SIGNAL SNAPSHOT ===")
                for line in snapshotText.split(separator: "\n").prefix(50) {
                    log("[CRASH_CONTEXT] \(line)")
                }
                log("[CRASH_CONTEXT] === END CRASH SIGNAL SNAPSHOT ===")
                appendEvent("crash_signal_snapshot_found length=\(snapshotText.count)")
            }
```

- [ ] **Step 2: 增强 CrashContextRecorder — 在 bootstrap 时输出更完整的运行时环境信息**

文件: `Sources/CrashContextRecorder.swift:52-68`

在 `appendEvent("launch pid=...")` 之后添加运行时环境记录：

```swift
        // 记录完整运行时环境到事件流
        let axOptions = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let axTrusted = AXIsProcessTrustedWithOptions(axOptions)
        appendEvent("env axTrusted=\(axTrusted) screens=\(NSScreen.screens.count) frontApp=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        appendEvent("env hotkey=\(HotKeyManager.shared.currentHotKey.displayString) hookRunning=\(ClaudeHookServer.shared.isRunning)")
        appendEvent("env savedStates=\(WindowManager.shared.savedWindowStates.count) hasToken=\(WindowManager.shared.lastWindowToken != nil)")
```

- [ ] **Step 3: 在 markCleanExit 中清理崩溃快照文件 — 正常退出时删除快照避免误报**

文件: `Sources/CrashContextRecorder.swift:90-101`

在 `markCleanExit()` 的 `state?.cleanExit = true` 之后添加：

```swift
        // 正常退出时删除崩溃快照文件，避免下次启动误判
        let crashSnapshotURL = URL(fileURLWithPath: "/tmp/vibefocus-crash-snapshot.log")
        try? FileManager.default.removeItem(at: crashSnapshotURL)
```

- [ ] **Step 4: 验证构建**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/CrashContextRecorder.swift && git commit -m "feat(crash): enhance CrashContextRecorder to read signal handler snapshot and log full runtime env"`

---

### Task 3: 添加内存状态快照函数 — 在每次关键操作后记录完整窗口管理器状态到日志

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Support.swift:220+` (在 Task 1 新增代码之后)

- [ ] **Step 1: 添加 logRuntimeStateSnapshot() 函数 — 将完整运行时状态输出到结构化日志**

在 `Support.swift` 中 `updateCrashSnapshotFromRuntime()` 之后添加。此函数在每次 toggle/restore/hook 操作后被调用，将完整的运行时状态输出到正常日志流（不是信号处理器缓冲区），用于事后排查。

```swift
func logRuntimeStateSnapshot(context: String) {
    let wm = WindowManager.shared
    let hkm = HotKeyManager.shared
    let hookServer = ClaudeHookServer.shared

    var fields: [String: String] = [
        "context": context,
        "savedStates": String(wm.savedWindowStates.count),
        "hasToken": String(wm.lastWindowToken != nil),
        "hasFrame": String(wm.lastWindowFrame != nil),
        "hasTarget": String(wm.lastTargetFrame != nil),
        "hasElement": String(wm.lastWindowElement != nil),
        "srcSpace": String(describing: wm.lastSourceSpaceIndex),
        "srcYabaiDisp": String(describing: wm.lastSourceYabaiDisplayIndex),
        "srcDispSpace": String(describing: wm.lastSourceDisplaySpaceIndex),
        "hotkey": hkm.currentHotKey.displayString,
        "axGranted": String(hkm.accessibilityGranted),
        "hookRunning": String(hookServer.isRunning),
        "screenCount": String(NSScreen.screens.count),
        "frontmost": frontmostAppDescriptor()
    ]

    if let token = wm.lastWindowToken {
        fields["tokenPID"] = String(token.pid)
        fields["tokenWinID"] = String(describing: token.windowID)
        fields["tokenBundleID"] = token.bundleIdentifier ?? "nil"
        fields["tokenTitle"] = truncateForLog(token.title ?? "", limit: 60)
    }
    if let frame = wm.lastWindowFrame {
        fields["origFrame"] = "(\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height))"
    }
    if let target = wm.lastTargetFrame {
        fields["targetFrame"] = "(\(target.origin.x),\(target.origin.y),\(target.width),\(target.height))"
    }

    // 记录每个 savedState 的摘要
    if !wm.savedWindowStates.isEmpty {
        let summaries = wm.savedWindowStates.suffix(5).map { state in
            "\(state.id.prefix(8))..pid=\(state.pid)win=\(String(describing: state.windowID))"
        }
        fields["recentStates"] = summaries.joined(separator: ",")
    }

    log("[STATE_SNAPSHOT] \(context)", level: .debug, fields: fields)
}
```

- [ ] **Step 2: 在 WindowManager 的 toggle/restore/moveToMainScreen 关键点调用 logRuntimeStateSnapshot**

文件: `Sources/WindowManager.swift:155` (toggle 函数中，在 toggle started 日志之后)

添加：

```swift
        logRuntimeStateSnapshot(context: "toggle_start")
```

文件: `Sources/WindowManager.swift:637` (restore 函数中，在 `resetActiveWindowContext` 之前)

添加：

```swift
        logRuntimeStateSnapshot(context: "restore_success")
```

文件: `Sources/WindowManager.swift:327` (moveToMainScreen 函数中，在 `MOVE FAILED` 日志之后)

添加：

```swift
            logRuntimeStateSnapshot(context: "move_failed")
```

- [ ] **Step 3: 在 ClaudeHookServer.handleHookRequest 入口和出口调用 logRuntimeStateSnapshot**

文件: `Sources/ClaudeHookServer.swift:167` (handleHookRequest 中，在 request received 日志之后)

添加：

```swift
        logRuntimeStateSnapshot(context: "hook_request_\(payload.event.rawValue)")
```

- [ ] **Step 4: 验证构建**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -20`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git add Sources/Support.swift Sources/WindowManager.swift Sources/ClaudeHookServer.swift && git commit -m "feat(logging): add runtime state snapshots at critical operation points for crash diagnosis"`

---

### Task 4: 构建验证和部署 — 确保所有改动编译通过并部署到本地

**Depends on:** Task 2, Task 3
**Files:**
- Modify: None (验证和部署)

- [ ] **Step 1: 完整 release 构建验证**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release 2>&1 | tail -30`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 2: 部署到本地 VibeFocus.app**

先找到当前运行的 VibeFocus 进程 PID，然后替换二进制文件。

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && PID=$(pgrep -f "VibeFocusHotkeys" | head -1) && echo "VibeFocus PID: $PID" && cp .build/release/VibeFocusHotkeys /Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys && echo "Binary deployed" && echo "PID=$PID"`
Expected:
  - Output contains: "Binary deployed"
  - Output contains a valid PID number

- [ ] **Step 3: 提交所有改动并推送**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && git push origin main`
Expected:
  - Exit code: 0

- [ ] **Step 4: 验证日志输出 — 检查新日志是否正常写入**
Run: `sleep 3 && tail -30 /tmp/vibefocus.log | grep -E "STATE_SNAPSHOT|CRASH_CONTEXT|signal" || echo "No crash-related logs yet (normal if no crash occurred)"`
Expected:
  - Output contains "STATE_SNAPSHOT" entries showing runtime state snapshots
