import AppKit
import Combine
import Foundation

enum SpaceAvailability: String {
    case unknown
    case notInstalled
    case unavailable
    case available
}

enum SpaceRestoreStrategy: String, CaseIterable {
    case switchToOriginal
    case pullToCurrent
}

struct SpacePreferences {
    static let integrationEnabledKey = "spaceIntegrationEnabled"
    static let restoreStrategyKey = "spaceRestoreStrategy"

    static var integrationEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: integrationEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: integrationEnabledKey)
        }
    }

    static var restoreStrategy: SpaceRestoreStrategy {
        get {
            let raw = UserDefaults.standard.string(forKey: restoreStrategyKey) ?? SpaceRestoreStrategy.switchToOriginal.rawValue
            return SpaceRestoreStrategy(rawValue: raw) ?? .switchToOriginal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: restoreStrategyKey)
        }
    }
}

struct SpaceContext {
    let sourceSpaceIndex: Int?
    let targetSpaceIndex: Int?
    let sourceDisplayIndex: Int?
    let sourceDisplaySpaceIndex: Int?
}

@MainActor
final class SpaceController: ObservableObject {
    static let shared = SpaceController()

    @Published private(set) var availability: SpaceAvailability = .unknown
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var canControlSpaces: Bool = false

    private var lastCheckAt: Date?
    private var cachedYabaiPath: String?
    private var didAttemptScriptingAdditionRecovery = false
    private var scriptingAdditionRecoverySucceeded = false
    private let checkInterval: TimeInterval = 20

    private init() {
        // Delay initial check to ensure log function is available
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            NSLog("[SpaceController] Initializing...")
            self?.refreshAvailability(force: true)
        }
    }

    deinit {
        NSLog("[SpaceController] Deinit called")
    }

    private func updateEnabledState() {
        let newValue = SpacePreferences.integrationEnabled && availability == .available
        if isEnabled != newValue {
            isEnabled = newValue
            NSLog("[SpaceController] isEnabled changed to: \(newValue)")
        }
    }

    func refreshAvailabilityIfNeeded() {
        refreshAvailability(force: false)
    }

    func refreshAvailability(force: Bool) {
        log("refreshAvailability called, force=\(force), lastCheckAt=\(String(describing: lastCheckAt))")

        if !force, let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval {
            log("Skipping refresh - within check interval")
            return
        }

        lastCheckAt = Date()
        lastErrorMessage = nil

        log("Looking for yabai...")
        guard let yabaiPath = locateYabai() else {
            log("yabai not found - setting availability to .notInstalled")
            availability = .notInstalled
            canControlSpaces = false
            updateEnabledState()
            return
        }

        log("Found yabai at: \(yabaiPath)")
        cachedYabaiPath = yabaiPath

        log("Running yabai query...")
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]) else {
            log("Failed to run yabai - setting availability to .unavailable")
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = "Unable to launch yabai"
            updateEnabledState()
            return
        }

        log("yabai query result: exitCode=\(result.exitCode), stdout=\(result.stdout.prefix(100)), stderr=\(result.stderr)")

        if result.exitCode == 0 {
            log("yabai available - setting availability to .available")
            availability = .available
            canControlSpaces = true
            lastErrorMessage = nil
            updateEnabledState()
        } else {
            log("yabai query failed - setting availability to .unavailable")
            availability = .unavailable
            canControlSpaces = false
            lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            updateEnabledState()
        }
    }

    func captureSpaceContext(windowID: UInt32, operationID: String? = nil) -> SpaceContext {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return SpaceContext(
                sourceSpaceIndex: nil,
                targetSpaceIndex: nil,
                sourceDisplayIndex: nil,
                sourceDisplaySpaceIndex: nil
            )
        }

        let windowInfo = queryWindow(windowID: windowID)
        let windowSpace = windowInfo?.space
        let windowDisplay = windowInfo?.display
        let spaces = querySpaces()
        let visibleSpaceOnDisplay = visibleSpaceIndex(forDisplayIndex: windowDisplay, spaces: spaces)
        let sourceSpace = preferredSourceSpace(
            windowSpace: windowSpace,
            visibleSpace: visibleSpaceOnDisplay,
            fallbackSpace: nil
        )
        let localSpace = displayLocalSpaceIndex(
            forGlobalSpaceIndex: sourceSpace,
            displayIndex: windowDisplay,
            spaces: spaces
        )

        log(
            "[SpaceController] capture space context",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "sourceSpace": String(describing: sourceSpace),
                "windowSpace": String(describing: windowSpace),
                "visibleSpace": String(describing: visibleSpaceOnDisplay),
                "display": String(describing: windowDisplay),
                "localSpace": String(describing: localSpace)
            ]
        )

        return SpaceContext(
            sourceSpaceIndex: sourceSpace,
            targetSpaceIndex: visibleSpaceOnDisplay,
            sourceDisplayIndex: windowDisplay,
            sourceDisplaySpaceIndex: localSpace
        )
    }

    func currentSpaceIndex() -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let space = queryFocusedSpace() else {
            return nil
        }
        return space.index
    }

    func windowSpaceIndex(windowID: UInt32) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.space
    }

    func globalSpaceIndex(displayIndex: Int, localSpaceIndex: Int) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return nil
        }
        guard let spaces = querySpaces() else {
            return nil
        }

        let spacesOnDisplay = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

        guard localSpaceIndex > 0, localSpaceIndex <= spacesOnDisplay.count else {
            return nil
        }

        return spacesOnDisplay[localSpaceIndex - 1].index
    }

    func displayLocalSpaceIndex(forGlobalSpaceIndex spaceIndex: Int?, displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> Int? {
        guard let spaceIndex, let displayIndex else {
            return nil
        }
        let resolvedSpaces: [YabaiSpaceInfo]
        if let spaces {
            resolvedSpaces = spaces
        } else {
            refreshAvailabilityIfNeeded()
            guard isEnabled, let queried = querySpaces() else {
                return nil
            }
            resolvedSpaces = queried
        }

        let spacesOnDisplay = resolvedSpaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

        for (offset, info) in spacesOnDisplay.enumerated() {
            if info.index == spaceIndex {
                return offset + 1
            }
        }
        return nil
    }

    @discardableResult
    func moveWindow(_ windowID: UInt32, toSpaceIndex spaceIndex: Int, focus: Bool, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot move window to another space because cross-space control is unavailable", operationID: op)
            return false
        }

        // 记录 moveWindow 调用上下文
        let windowBeforeMove = queryWindow(windowID: windowID)
        log(
            "[SpaceController] moveWindow called",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "targetSpace": String(spaceIndex),
                "windowCurrentSpace": String(describing: windowBeforeMove?.space),
                "windowCurrentDisplay": String(describing: windowBeforeMove?.display),
                "focus": String(focus)
            ]
        )

        let moveResult = runYabaiVariants(
            variants: [["-m", "window", "\(windowID)", "--space", "\(spaceIndex)"]],
            operation: "moveWindow(windowID=\(windowID), space=\(spaceIndex))",
            operationID: op
        )
        if moveResult.success {
            // 验证窗口是否真正移到了目标 space
            let windowAfterMove = queryWindow(windowID: windowID)
            let moveVerified = windowAfterMove?.space == spaceIndex
            if !moveVerified {
                log(
                    "[SpaceController] moveWindow yabai succeeded but verification shows window not on target space",
                    level: .warn,
                    fields: [
                        "op": op,
                        "windowID": String(windowID),
                        "targetSpace": String(spaceIndex),
                        "actualSpace": String(describing: windowAfterMove?.space),
                        "note": "yabai move may have async effect, AX frame positioning is authoritative"
                    ]
                )
            }
            if focus {
                _ = focusWindow(windowID, operationID: op)
            }
            return true
        }

        // yabai 失败，尝试原生 CGS API fallback
        if let spaceID = nativeSpaceID(forYabaiIndex: spaceIndex) {
            log(
                "[SpaceController] yabai moveWindow failed, trying native fallback",
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "yabaiIndex": String(spaceIndex),
                    "nativeSpaceID": String(spaceID),
                ]
            )
            if NativeSpaceBridge.moveWindow(windowID, toSpaceID: spaceID) {
                if focus {
                    _ = focusWindow(windowID, operationID: op)
                }
                return true
            }
        } else {
            log(
                "[SpaceController] native fallback skipped: could not resolve spaceID for yabaiIndex=\(spaceIndex)",
                level: .warn,
                fields: [
                    "op": op,
                    "windowID": String(windowID),
                    "targetSpace": String(spaceIndex)
                ]
            )
        }

        markOperationError(
            from: moveResult.failure,
            fallback: "Failed to move window \(windowID) to space \(spaceIndex)",
            operationID: op
        )
        return false
    }

    @discardableResult
    func focusSpace(_ spaceIndex: Int, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot focus another space because cross-space control is unavailable", operationID: op)
            return false
        }

        // 记录 focusSpace 调用的完整上下文
        let preFocusSpace = queryFocusedSpace()?.index
        let targetDisplay = querySpaces()?.first(where: { $0.index == spaceIndex })?.display
        log(
            "[SpaceController] focusSpace called",
            fields: [
                "op": op,
                "targetSpace": String(spaceIndex),
                "targetDisplay": String(describing: targetDisplay),
                "currentSpace": String(describing: preFocusSpace),
                "canControlSpaces": String(canControlSpaces)
            ]
        )

        let variants = [["-m", "space", "--focus", "\(spaceIndex)"]]
        let result = runYabaiVariants(variants: variants, operation: "focusSpace(\(spaceIndex))", operationID: op)
        if result.success {
            return true
        }

        // yabai 失败，使用 CGEvent 键盘事件 fallback
        let steps = calculateFocusSteps(targetSpaceIndex: spaceIndex)
        log(
            "[SpaceController] yabai focusSpace failed, trying CGEvent fallback",
            fields: [
                "op": op,
                "yabaiIndex": String(spaceIndex),
                "targetDisplay": String(describing: targetDisplay),
                "steps": String(steps),
                "hasDisplayCenter": String(displayCenterCG(spaceIndex: spaceIndex) != nil)
            ]
        )

        if steps == 0 {
            log(
                "[SpaceController] CGEvent fallback skipped: steps=0 (already on target space)",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "currentSpace": String(describing: preFocusSpace)
                ]
            )
            return true // 已在目标空间
        }

        // 关键：Ctrl+Left/Right 只影响鼠标所在显示器的空间
        // 用 CGEvent 发送鼠标移动事件（非 CGWarp，后者不更新系统活跃显示器状态）
        let savedCursor = NSEvent.mouseLocation
        let mainScreenHeight = NSScreen.screens[0].frame.height
        let savedCursorCG = CGPoint(x: savedCursor.x, y: mainScreenHeight - savedCursor.y)

        let targetCenterCG = displayCenterCG(spaceIndex: spaceIndex)
        if let center = targetCenterCG {
            // 用 CGEvent 鼠标移动事件（而非 CGWarpMouseCursorPosition）
            // 这样 WindowServer 会真正更新"活跃显示器"状态
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            usleep(50_000) // 50ms 等系统处理鼠标移动
        } else {
            log(
                "[SpaceController] CGEvent fallback: could not determine display center",
                level: .warn,
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex)
                ]
            )
        }

        let success = NativeSpaceBridge.focusSpace(steps: steps, operationID: op)

        // 恢复鼠标位置（用 CGEvent 以确保系统状态同步）
        if let restoreEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: savedCursorCG, mouseButton: .left) {
            restoreEvent.post(tap: .cghidEventTap)
        }

        if success {
            usleep(250_000) // 250ms 等空间切换动画
            // 验证 space 是否真正切换成功
            let postFallbackSpace = queryFocusedSpace()?.index
            let spaceChanged = postFallbackSpace != preFocusSpace
            log(
                "[SpaceController] CGEvent fallback completed",
                fields: [
                    "op": op,
                    "targetSpace": String(spaceIndex),
                    "preFocusSpace": String(describing: preFocusSpace),
                    "postFallbackSpace": String(describing: postFallbackSpace),
                    "spaceChanged": String(spaceChanged),
                    "reachedTarget": String(postFallbackSpace == spaceIndex)
                ]
            )
            return true
        }

        markOperationError(from: result.failure, fallback: "Failed to focus space \(spaceIndex)", operationID: op)
        return false
    }

    @discardableResult
    func focusWindow(_ windowID: UInt32, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }

        let variants = [
            ["-m", "window", "--focus", "\(windowID)"]
        ]
        let result = runYabaiVariants(variants: variants, operation: "focusWindow(\(windowID))", operationID: op)
        if result.success {
            return true
        }
        markOperationError(from: result.failure, fallback: "Failed to focus window \(windowID)", operationID: op)
        return false
    }

    /// 手动触发 scripting-addition 加载（从设置 UI 调用）
    func requestScriptingAdditionLoad() {
        let op = makeOperationID(prefix: "sa-load")
        log(
            "[SpaceController] manual scripting-addition load requested",
            fields: ["op": op]
        )
        // 重置恢复标记，允许重新尝试
        didAttemptScriptingAdditionRecovery = false
        scriptingAdditionRecoverySucceeded = false
        _ = attemptScriptingAdditionRecovery(trigger: "manual", operationID: op)
        // 加载成功后刷新可用性
        if scriptingAdditionRecoverySucceeded {
            refreshAvailability(force: true)
        }
    }

    private func locateYabai() -> String? {
        NSLog("[SpaceController] locateYabai called")

        if let cachedYabaiPath, !cachedYabaiPath.isEmpty {
            log("Using cached yabai path: \(cachedYabaiPath)")
            return cachedYabaiPath
        }

        // First, try common installation paths
        let commonPaths = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
            "/bin/yabai",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent("bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin/yabai")
        ]

        log("Checking common paths: \(commonPaths)")
        for path in commonPaths {
            let exists = FileManager.default.fileExists(atPath: path)
            log("  Path \(path): exists=\(exists)")
            if exists {
                cachedYabaiPath = path
                NSLog("[SpaceController] Found yabai at: \(path)")
                return path
            }
        }

        // Fallback 1: try to find using user's shell environment
        log("Trying to find yabai via user shell...")
        if let shellPath = getYabaiPathFromUserShell() {
            cachedYabaiPath = shellPath
            NSLog("[SpaceController] Found yabai via shell: \(shellPath)")
            return shellPath
        }

        // Fallback 2: try to find using which via bash -l
        log("Trying to find yabai via bash -l...")
        guard let result = runProcess(executable: "/bin/bash", arguments: ["-l", "-c", "which yabai"]),
              result.exitCode == 0 else {
            log("Failed to find yabai via bash -l")
            NSLog("[SpaceController] yabai not found via bash -l")
            return nil
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            log("which yabai returned empty path")
            NSLog("[SpaceController] which yabai returned empty path")
            return nil
        }
        cachedYabaiPath = path
        NSLog("[SpaceController] Found yabai via which: \(path)")
        return path
    }

    private func getYabaiPathFromUserShell() -> String? {
        // Get user's default shell
        let shellTask = Process()
        shellTask.launchPath = "/usr/bin/env"
        shellTask.arguments = ["bash", "-l", "-c", "echo $SHELL"]

        let shellPipe = Pipe()
        shellTask.standardOutput = shellPipe
        shellTask.standardError = Pipe()

        do {
            try shellTask.run()
            shellTask.waitUntilExit()

            let shellData = shellPipe.fileHandleForReading.readDataToEndOfFile()
            guard let userShell = String(data: shellData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userShell.isEmpty else {
                return nil
            }

            // Use user's shell to find yabai
            let whichTask = Process()
            whichTask.launchPath = userShell
            whichTask.arguments = ["-l", "-c", "which yabai"]

            let whichPipe = Pipe()
            whichTask.standardOutput = whichPipe
            whichTask.standardError = Pipe()

            try whichTask.run()
            whichTask.waitUntilExit()

            let pathData = whichPipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: pathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            log("Failed to get yabai path from user shell: \(error)")
        }

        return nil
    }

    private func queryFocusedSpace() -> YabaiSpaceInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiSpaceInfo.self, from: result.stdout)
    }

    private func querySpaces(caller: String = #function) -> [YabaiSpaceInfo]? {
        let startedAt = Date()
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]),
              result.exitCode == 0 else {
            log(
                "[SpaceController] querySpaces failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            return nil
        }
        let spaces = decodeArray(YabaiSpaceInfo.self, from: result.stdout)
        if spaces == nil, !result.stdout.isEmpty {
            log(
                "[SpaceController] querySpaces decode failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "stdoutLen": String(result.stdout.count),
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
        }
        return spaces
    }

    private func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
    }

    private func visibleSpaceIndex(forDisplayIndex displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> Int? {
        guard let displayIndex else {
            return nil
        }
        let resolvedSpaces = spaces ?? querySpaces()
        return resolvedSpaces?.first(where: { $0.display == displayIndex && $0.isVisible == true })?.index
    }

    private func preferredSourceSpace(windowSpace: Int?, visibleSpace: Int?, fallbackSpace: Int?) -> Int? {
        if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
            log("[SpaceController] source space mismatch windowSpace=\(windowSpace) visibleSpace=\(visibleSpace); prefer visibleSpace")
            return visibleSpace
        }
        return windowSpace ?? visibleSpace ?? fallbackSpace
    }

    private func isScriptingAdditionError(_ result: ShellResult) -> Bool {
        let text = "\(result.stdout)\n\(result.stderr)".lowercased()
        return text.contains("scripting-addition")
    }

    private func runYabai(
        arguments: [String],
        operation: String? = nil,
        operationID: String? = nil,
        logSuccess: Bool = false
    ) -> ShellResult? {
        let op = operationID ?? "none"
        guard let yabaiPath = locateYabai() else {
            log(
                "[SpaceController] yabai command skipped: executable not found",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }
        let startedAt = Date()
        guard let result = runProcess(executable: yabaiPath, arguments: arguments) else {
            log(
                "[SpaceController] failed to launch yabai command",
                level: .error,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "args": arguments.joined(separator: " ")
                ]
            )
            return nil
        }

        let durationMs = elapsedMilliseconds(since: startedAt)
        let isSlow = durationMs >= 180

        if result.exitCode != 0 || logSuccess || isSlow {
            let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
            let level: LogLevel = result.exitCode == 0 ? (isSlow ? .warn : .info) : .warn
            log(
                isSlow && result.exitCode == 0 ? "[SpaceController] yabai command slow" : "[SpaceController] yabai command result",
                level: level,
                fields: [
                    "op": op,
                    "operation": operation ?? "unknown",
                    "exitCode": String(result.exitCode),
                    "durationMs": String(durationMs),
                    "args": arguments.joined(separator: " "),
                    "stderr": stderr.isEmpty ? "-" : stderr,
                    "stdout": stdout.isEmpty ? "-" : stdout
                ]
            )
        }

        return result
    }

    private func runYabaiVariants(
        variants: [[String]],
        operation: String,
        operationID: String? = nil
    ) -> (success: Bool, failure: ShellResult?) {
        let op = operationID ?? "none"
        var lastFailure: ShellResult?
        var recoveredOnce = false

        for arguments in variants {
            while true {
                guard let result = runYabai(
                    arguments: arguments,
                    operation: operation,
                    operationID: op,
                    logSuccess: true
                ) else {
                    log(
                        "[SpaceController] operation failed to launch",
                        level: .error,
                        fields: [
                            "op": op,
                            "operation": operation,
                            "args": arguments.joined(separator: " ")
                        ]
                    )
                    break
                }

                if result.exitCode == 0 {
                    return (true, nil)
                }

                lastFailure = result
                let stderr = truncateForLog(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                let stdout = truncateForLog(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), limit: 220)
                log(
                    "[SpaceController] operation failed",
                    level: .warn,
                    fields: [
                        "op": op,
                        "operation": operation,
                        "exitCode": String(result.exitCode),
                        "args": arguments.joined(separator: " "),
                        "stderr": stderr.isEmpty ? "-" : stderr,
                        "stdout": stdout.isEmpty ? "-" : stdout
                    ]
                )

                if !recoveredOnce, isScriptingAdditionError(result), attemptScriptingAdditionRecovery(trigger: operation, operationID: op) {
                    recoveredOnce = true
                    log(
                        "[SpaceController] retrying after scripting-addition recovery",
                        fields: [
                            "op": op,
                            "operation": operation
                        ]
                    )
                    continue
                }

                break
            }
        }

        return (false, lastFailure)
    }

    /// 通过 macOS 原生密码对话框以管理员权限执行 shell 命令
    /// 返回 (success: Bool, output: String)
    @discardableResult
    private func executeWithAdminPrivileges(_ command: String, operationID: String? = nil) -> (Bool, String) {
        let op = operationID ?? "none"
        // 转义命令中的双引号和反斜杠，防止 AppleScript 注入
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = "do shell script \"\(escapedCommand)\" with administrator privileges"
        let appleScript = NSAppleScript(source: scriptSource)

        log(
            "[SpaceController] requesting admin privileges",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120)
            ]
        )

        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict {
            let errorMessage = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[SpaceController] admin privilege execution failed",
                level: .error,
                fields: [
                    "op": op,
                    "command": truncateForLog(command, limit: 120),
                    "errorMessage": errorMessage,
                    "errorNumber": String(errorNumber)
                ]
            )
            return (false, errorMessage)
        }

        let output = result?.stringValue ?? ""
        log(
            "[SpaceController] admin privilege execution succeeded",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120),
                "output": truncateForLog(output, limit: 120)
            ]
        )
        return (true, output)
    }

    private func attemptScriptingAdditionRecovery(trigger: String, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        if didAttemptScriptingAdditionRecovery {
            return scriptingAdditionRecoverySucceeded
        }
        didAttemptScriptingAdditionRecovery = true

        guard let yabaiPath = locateYabai() else {
            log(
                "[SpaceController] scripting-addition recovery skipped: yabai path missing",
                level: .error,
                fields: [
                    "op": op,
                    "trigger": trigger
                ]
            )
            return false
        }

        log(
            "[SpaceController] attempting scripting-addition recovery",
            fields: [
                "op": op,
                "trigger": trigger
            ]
        )

        if let direct = runProcess(executable: yabaiPath, arguments: ["--load-sa"]), direct.exitCode == 0 {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via direct load-sa",
                fields: [
                    "op": op
                ]
            )
            return true
        }

        // 使用 macOS 原生密码对话框请求管理员权限加载 scripting-addition
        let (privSuccess, privOutput) = executeWithAdminPrivileges(
            "\(yabaiPath) --load-sa",
            operationID: op
        )

        if privSuccess {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via admin privileges",
                fields: [
                    "op": op,
                    "output": truncateForLog(privOutput, limit: 120)
                ]
            )
            return true
        }

        log(
            "[SpaceController] scripting-addition recovery failed: admin privilege dialog cancelled or error",
            level: .error,
            fields: [
                "op": op,
                "detail": truncateForLog(privOutput, limit: 220)
            ]
        )
        lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击\"加载\"按钮手动触发。"
        return false
    }

    private func markOperationError(from result: ShellResult?, fallback: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        if let result {
            if isScriptingAdditionError(result) {
                lastErrorMessage = "yabai scripting-addition 不可用，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
                canControlSpaces = false
            } else {
                lastErrorMessage = formatErrorMessage(stdout: result.stdout, stderr: result.stderr)
            }
        } else {
            lastErrorMessage = fallback
        }
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "fallback": fallback,
                "lastError": lastErrorMessage ?? "nil"
            ]
        )
    }

    private func markOperationError(_ message: String, operationID: String? = nil) {
        let op = operationID ?? "none"
        lastErrorMessage = message
        log(
            "[SpaceController] operation error",
            level: .error,
            fields: [
                "op": op,
                "message": message
            ]
        )
    }

    private func runProcess(executable: String, arguments: [String]) -> ShellResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("Failed to run \(executable): \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: String(data: errorData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func decodeSingleOrFirst<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(T.self, from: data) {
            return single
        }
        if let array = try? decoder.decode([T].self, from: data) {
            return array.first
        }
        return nil
    }

    private func decodeArray<T: Decodable>(_ type: T.Type, from text: String) -> [T]? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: data) {
            return array
        }
        return nil
    }

    /// 通过 yabai query 获取 yabai 空间索引对应的 macOS 原生空间 ID
    /// yabai query 不依赖 scripting-addition，始终可用
    private func nativeSpaceID(forYabaiIndex index: Int) -> Int64? {
        guard let spaces = querySpaces() else { return nil }
        let matched = spaces.first { $0.index == index }
        guard let id = matched?.id else { return nil }
        return Int64(id)
    }

    /// 获取目标空间所属显示器的中心点（CG 坐标系，用于 CGWarpMouseCursorPosition）
    private func displayCenterCG(spaceIndex: Int) -> CGPoint? {
        guard let spaces = querySpaces(),
              let targetSpace = spaces.first(where: { $0.index == spaceIndex }),
              let displayIndex = targetSpace.display else { return nil }

        // yabai display index 1 = NSScreen.screens[0], 2 = screens[1], ...
        let screenIndex = displayIndex - 1
        guard screenIndex >= 0, screenIndex < NSScreen.screens.count else { return nil }
        let screen = NSScreen.screens[screenIndex]

        // NSScreen.frame 用 Cocoa 坐标（原点在主屏左下角，Y 向上）
        // CG 坐标原点在主屏左上角，Y 向下
        // 转换：cgY = mainScreenHeight - nsFrame.origin.y - nsFrame.height
        let mainScreenHeight = NSScreen.screens[0].frame.height
        let nsFrame = screen.frame
        return CGPoint(
            x: nsFrame.origin.x + nsFrame.width / 2,
            y: mainScreenHeight - nsFrame.origin.y - nsFrame.height + nsFrame.height / 2
        )
    }

    /// 计算从当前可见空间切换到目标空间需要的 Ctrl+Left/Right 步数
    /// 正数 = 向右（Ctrl+Right），负数 = 向左（Ctrl+Left），0 = 已在目标空间
    private func calculateFocusSteps(targetSpaceIndex: Int) -> Int {
        guard let spaces = querySpaces() else {
            log("[SpaceController] calculateFocusSteps: querySpaces returned nil", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        // 找到目标空间所在的显示器
        guard let targetSpace = spaces.first(where: { $0.index == targetSpaceIndex }) else {
            log("[SpaceController] calculateFocusSteps: target space not found", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }
        guard let displayIndex = targetSpace.display else {
            log("[SpaceController] calculateFocusSteps: target space has no display", level: .warn, fields: ["target": String(targetSpaceIndex)])
            return 0
        }

        // 找到该显示器上所有空间（按 index 排序）
        let displaySpaces = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

        // 找到该显示器上当前可见空间
        guard let currentSpace = displaySpaces.first(where: { $0.isVisible == true }) else {
            log("[SpaceController] calculateFocusSteps: no visible space on display", level: .warn, fields: ["display": String(displayIndex)])
            return 0
        }
        guard let currentIdx = displaySpaces.firstIndex(where: { $0.index == currentSpace.index }) else { return 0 }
        guard let targetIdx = displaySpaces.firstIndex(where: { $0.index == targetSpaceIndex }) else { return 0 }

        let steps = targetIdx - currentIdx
        log(
            "[SpaceController] calculateFocusSteps",
            fields: [
                "target": String(targetSpaceIndex),
                "display": String(displayIndex),
                "displaySpaces": displaySpaces.map { "\($0.index ?? 0):v=\($0.isVisible ?? false)" }.joined(separator: ","),
                "currentIdx": String(currentIdx),
                "targetIdx": String(targetIdx),
                "steps": String(steps),
            ]
        )
        return steps
    }

    private func formatErrorMessage(stdout: String, stderr: String) -> String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        if !trimmedStdout.isEmpty {
            return trimmedStdout
        }
        return "yabai returned empty error output"
    }
}

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct YabaiSpaceInfo: Decodable {
    let id: Int?
    let index: Int?
    let display: Int?
    let isVisible: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case display
        case isVisible = "is-visible"
    }
}

struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
}
