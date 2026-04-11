import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

@MainActor
extension WindowManager {
    func candidateApplications(for token: WindowToken) -> [NSRunningApplication] {
        var applications: [NSRunningApplication] = []

        func appendIfNeeded(_ app: NSRunningApplication?) {
            guard let app else { return }
            if !applications.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                applications.append(app)
            }
        }

        appendIfNeeded(NSRunningApplication(processIdentifier: token.pid))

        if let bundleIdentifier = token.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                appendIfNeeded(app)
            }
        }

        if let appName = token.appName {
            for app in NSWorkspace.shared.runningApplications where app.localizedName == appName {
                appendIfNeeded(app)
            }
        }

        appendIfNeeded(NSWorkspace.shared.frontmostApplication)
        return applications
    }

    func captureFocusedWindowIdentity() -> WindowIdentity? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        guard let windowAX = focusedWindow(for: frontApp.processIdentifier) else {
            return nil
        }
        guard let windowID = windowHandle(for: windowAX) else {
            return nil
        }
        return WindowIdentity(
            windowID: windowID,
            pid: frontApp.processIdentifier,
            bundleIdentifier: frontApp.bundleIdentifier,
            appName: frontApp.localizedName,
            windowNumber: windowNumber(for: windowAX),
            title: title(of: windowAX),
            capturedAt: Date()
        )
    }

    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            return matched
        }

        return windows.first
    }

    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log(
            "[WindowManager] moveWindowToMainScreen started",
            fields: [
                "op": op,
                "windowID": String(identity.windowID),
                "pid": String(identity.pid),
                "reason": reason.rawValue,
                "sessionID": sessionID ?? "nil"
            ]
        )

        guard hasAccessibilityPermission() else {
            log(
                "moveWindowToMainScreen failed: accessibility not granted",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            notifyAccessibilityPermissionRequired()
            return false
        }

        guard let windowAX = resolveWindow(identity: identity) else {
            log(
                "moveWindowToMainScreen failed: cannot resolve window",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        guard let currentFrame = frame(of: windowAX) else {
            log(
                "moveWindowToMainScreen failed: cannot read current frame",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        guard let currentWindowID = windowHandle(for: windowAX) else {
            log(
                "moveWindowToMainScreen failed: missing stable window handle",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        guard isAttributeSettable(windowAX, attribute: kAXPositionAttribute),
              isAttributeSettable(windowAX, attribute: kAXSizeAttribute) else {
            log(
                "moveWindowToMainScreen failed: window attributes not settable",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        let sourceContext = displayContext(for: currentFrame)
        let spaceCaptureStartAt = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: currentWindowID, operationID: op)
        log(
            "[WindowManager] captured source space context",
            fields: [
                "op": op,
                "durationMs": String(elapsedMilliseconds(since: spaceCaptureStartAt))
            ]
        )

        guard let mainScreen = getMainScreen() else {
            log(
                "moveWindowToMainScreen failed: cannot determine main screen",
                level: .error,
                fields: [
                    "op": op
                ]
            )
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main_apply_frame"),
              let appliedFrame = frame(of: windowAX),
              framesMatch(appliedFrame, targetFrame) else {
            log(
                "moveWindowToMainScreen failed: frame verification mismatch",
                level: .error,
                fields: [
                    "op": op,
                    "targetFrame": String(describing: targetFrame)
                ]
            )
            return false
        }

        let resolvedWindowNumber = windowNumber(for: windowAX) ?? identity.windowNumber
        let resolvedTitle = title(of: windowAX) ?? identity.title
        log(
            "[WindowManager] moveWindowToMainScreen captured state",
            fields: [
                "op": op,
                "sourceSpace": String(describing: spaceContext.sourceSpaceIndex),
                "targetSpace": String(describing: spaceContext.targetSpaceIndex),
                "sourceYabaiDisplay": String(describing: spaceContext.sourceDisplayIndex),
                "sourceDisplaySpace": String(describing: spaceContext.sourceDisplaySpaceIndex),
                "sourceDisplayID": String(describing: sourceContext.displayID),
                "sourceDisplayIndex": String(describing: sourceContext.index),
                "targetDisplayIndex": String(describing: targetDisplayIndex)
            ]
        )
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            windowID: currentWindowID,
            windowNumber: resolvedWindowNumber,
            title: resolvedTitle,
            originalFrame: RectPayload(currentFrame),
            targetFrame: RectPayload(targetFrame),
            sourceSpaceIndex: spaceContext.sourceSpaceIndex,
            targetSpaceIndex: spaceContext.targetSpaceIndex,
            sourceYabaiDisplayIndex: spaceContext.sourceDisplayIndex,
            sourceDisplaySpaceIndex: spaceContext.sourceDisplaySpaceIndex,
            sourceDisplayIndex: sourceContext.index,
            sourceDisplayID: sourceContext.displayID,
            targetDisplayIndex: targetDisplayIndex,
            restoreReason: reason.rawValue,
            sessionID: sessionID,
            savedAt: Date()
        )

        let persistedState = saveWindowState(savedState, window: windowAX)
        hydrateMemory(from: persistedState, window: windowAX)
        log(
            "[WindowManager] moveWindowToMainScreen finished",
            fields: [
                "op": op,
                "savedStateID": persistedState.id,
                "windowID": String(currentWindowID),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return true
    }

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else {
            return []
        }

        return windowsRef as? [AXUIElement] ?? []
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    private func displayIndex(forDisplayID displayID: UInt32?) -> Int? {
        guard let displayID else {
            return nil
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.enumerated().first(where: { _, screen in
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        })?.offset
    }

    private func displayContext(for frame: CGRect) -> (index: Int?, displayID: UInt32?) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for (index, screen) in NSScreen.screens.enumerated() {
            let displayFrame = screen.frame
            if displayFrame.contains(center) || displayFrame.intersects(frame) {
                let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
                return (index, displayID)
            }
        }
        return (nil, nil)
    }

    func moveToMainScreenViaSystemEvents() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("No frontmost app for System Events fallback")
            return
        }

        guard let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            log("System Events fallback could not read front window")
            notifyAccessibilityPermissionRequired()
            return
        }

        guard let mainScreen = getMainScreen() else {
            log("Cannot get main screen for System Events fallback")
            return
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let bundleIdentifier = frontApp.bundleIdentifier
        let appName = frontApp.localizedName ?? snapshot.appName
        let savedState = SavedWindowState(
            id: UUID().uuidString,
            pid: frontApp.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowID: snapshot.windowID,
            windowNumber: nil,
            title: snapshot.title,
            originalFrame: RectPayload(snapshot.frame),
            targetFrame: RectPayload(targetFrame),
            sourceSpaceIndex: nil,
            targetSpaceIndex: nil,
            sourceYabaiDisplayIndex: nil,
            sourceDisplaySpaceIndex: nil,
            sourceDisplayIndex: nil,
            sourceDisplayID: nil,
            targetDisplayIndex: nil,
            restoreReason: WindowMoveReason.manualHotkey.rawValue,
            sessionID: nil,
            savedAt: Date()
        )

        log("System Events snapshot frame: \(snapshot.frame)")
        log("System Events target frame: \(targetFrame)")

        guard systemEventsApply(frame: targetFrame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to move window")
            return
        }

        let persistedState = saveWindowState(savedState)
        hydrateMemory(from: persistedState, window: nil)
        log("✅ MOVED WITH SYSTEM EVENTS FALLBACK")
    }

    func restoreViaSystemEvents() {
        if lastWindowToken == nil || lastWindowFrame == nil || lastTargetFrame == nil {
            if shouldRestoreCurrentWindowViaSystemEvents() == false {
                log("No saved window to restore via System Events")
                return
            }
        }

        guard let token = lastWindowToken,
              let frame = lastWindowFrame,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier),
              snapshot.windowID == token.windowID else {
            log("No active window state to restore via System Events")
            return
        }

        log("Restoring with System Events using window handle match")
        guard systemEventsApply(frame: frame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to restore window")
            return
        }

        resetActiveWindowContext(removeState: true)
        log("✅ RESTORED WITH SYSTEM EVENTS FALLBACK")
    }

    func shouldRestoreCurrentWindowViaSystemEvents() -> Bool {
        guard !savedWindowStates.isEmpty,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            return false
        }

        // 第一级匹配：通过 windowID
        if let currentWindowID = snapshot.windowID,
           let matchedState = savedWindowStates.reversed().first(where: { $0.windowID == currentWindowID }) {
            hydrateMemory(from: matchedState, window: nil)
            log("Detected moved window state via System Events handle: \(currentWindowID)")
            return true
        }

        // 第二级匹配：通过 PID + 窗口标题 + 大致位置
        let positionTolerance: CGFloat = 50.0
        if let matchedState = savedWindowStates.reversed().first(where: { state in
            guard state.pid == frontApp.processIdentifier else { return false }
            let stateTitle = state.title ?? ""
            let currentTitle = snapshot.title ?? ""
            guard stateTitle == currentTitle else { return false }

            // 检查当前位置是否接近保存的 targetFrame
            let targetFrame = state.targetFrame.cgRect
            let xDiff = abs(snapshot.x - targetFrame.origin.x)
            let yDiff = abs(snapshot.y - targetFrame.origin.y)
            return xDiff <= positionTolerance && yDiff <= positionTolerance
        }) {
            hydrateMemory(from: matchedState, window: nil)
            log("Detected moved window state via System Events fallback matching (PID+title+position)")
            return true
        }

        return false
    }

    func systemEventsSnapshot(forPID pid: pid_t) -> ScriptWindowSnapshot? {
        // 先尝试通过 CGWindow 获取 windowID
        let windowID = systemEventsGetWindowID(forPID: pid)

        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        JSON.stringify({
          windowID: null,
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return nil
        }

        // 将从 CGWindow 获取的 windowID 注入结果
        return ScriptWindowSnapshot(
            windowID: windowID,
            appName: snapshot.appName,
            title: snapshot.title,
            x: snapshot.x,
            y: snapshot.y,
            width: snapshot.width,
            height: snapshot.height
        )
    }

    /// 通过 CGWindowList 获取窗口 ID（备用方案）
    private func systemEventsGetWindowID(forPID pid: pid_t) -> UInt32? {
        // 获取该 PID 的所有窗口
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // 找到属于该 PID 且是可见的普通窗口
        for windowInfo in windowList {
            if let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
               windowPID == pid,
               let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 {
                // 过滤掉系统 UI 元素（如菜单栏、Dock）
                let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
                if layer == 0 {
                    return windowID
                }
            }
        }
        return nil
    }

    func systemEventsApply(frame targetFrame: CGRect, toPID pid: pid_t) -> Bool {
        let script = """
        const se = Application('System Events');
        const pid = \(pid);
        const proc = se.applicationProcesses.whose({ unixId: pid })[0];
        if (!proc) throw new Error('NO_PROCESS');
        const win = proc.windows[0];
        if (!win) throw new Error('NO_WINDOW');
        win.position = [\(Int(targetFrame.origin.x.rounded())), \(Int(targetFrame.origin.y.rounded()))];
        win.size = [\(Int(targetFrame.width.rounded())), \(Int(targetFrame.height.rounded()))];
        JSON.stringify({
          appName: proc.name(),
          title: (() => { try { return win.name(); } catch (_) { return ""; } })(),
          x: win.position()[0],
          y: win.position()[1],
          width: win.size()[0],
          height: win.size()[1]
        });
        """

        guard let output = runJXAScript(script),
              let data = output.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ScriptWindowSnapshot.self, from: data) else {
            return false
        }

        return framesMatch(snapshot.frame, targetFrame)
    }

    func windowHandle(for window: AXUIElement) -> UInt32? {
        var windowID: CGWindowID = 0
        let status = _AXUIElementGetWindow(window, &windowID)
        guard status == .success, windowID != 0 else {
            log("Cannot get stable window handle from AXUIElement: \(status.rawValue)")
            return nil
        }
        return windowID
    }

    struct CGWindowSnapshot {
        let windowID: UInt32
        let title: String?
        let frame: CGRect
        let ownerPID: pid_t
        let layer: Int
    }


    func runJXAScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            log("Failed to launch osascript: \(error.localizedDescription)")
            return nil
        }

        if let data = script.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorText = String(data: errorData, encoding: .utf8) ?? "unknown error"
            log("osascript failed (exit \(process.terminationStatus), scriptLength=\(script.count)): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }

        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func windowNumber(for window: AXUIElement) -> Int? {
        var numberRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axWindowNumberAttribute as CFString, &numberRef)
        guard status == .success, let number = numberRef as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard status == .success else {
            return nil
        }
        return titleRef as? String
    }

    func frame(of window: AXUIElement) -> CGRect? {
        var frameRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, axFrameAttribute as CFString, &frameRef)
        guard status == .success, let frameRef else {
            return nil
        }

        let axValue = frameRef as! AXValue
        var frame = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &frame) else {
            return nil
        }
        return frame
    }

    func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        if status != .success {
            log("Settable check failed for \(attribute): \(status.rawValue)")
            return false
        }
        return settable.boolValue
    }

    func apply(
        frame targetFrame: CGRect,
        to window: AXUIElement,
        operationID: String? = nil,
        stage: String = "apply_frame"
    ) -> Bool {
        let op = operationID ?? "none"
        let startedAt = Date()
        var lastAppliedFrame: CGRect?
        let maxAttempts = 3
        let settleDelayMicros: useconds_t = 25_000

        for attempt in 1...maxAttempts {
            var targetSize = CGSize(width: targetFrame.width, height: targetFrame.height)
            guard let sizeValue = AXValueCreate(.cgSize, &targetSize) else {
                return false
            }

            let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            log(
                "[WindowManager] set size result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(sizeResult.rawValue)
                ]
            )
            guard sizeResult == .success else {
                return false
            }

            var targetOrigin = CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y)
            guard let originValue = AXValueCreate(.cgPoint, &targetOrigin) else {
                return false
            }

            let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
            log(
                "[WindowManager] set position result",
                fields: [
                    "op": op,
                    "stage": stage,
                    "attempt": String(attempt),
                    "status": String(positionResult.rawValue)
                ]
            )
            guard positionResult == .success else {
                return false
            }

            usleep(settleDelayMicros)

            if let appliedFrame = frame(of: window) {
                log(
                    "[WindowManager] applied frame snapshot",
                    fields: [
                        "op": op,
                        "stage": stage,
                        "attempt": String(attempt),
                        "frame": String(describing: appliedFrame)
                    ]
                )
                lastAppliedFrame = appliedFrame
                if framesMatch(appliedFrame, targetFrame) {
                    log(
                        "[WindowManager] apply frame matched target",
                        fields: [
                            "op": op,
                            "stage": stage,
                            "attempt": String(attempt),
                            "durationMs": String(elapsedMilliseconds(since: startedAt))
                        ]
                    )
                    return true
                }
            }
        }

        // 如果精确匹配失败，但窗口已成功应用了接近的尺寸（可能是窗口有最小尺寸限制）
        // 我们也认为是成功的
        if let lastFrame = lastAppliedFrame {
            // 检查是否在合理范围内（位置正确，大小接近）
            let positionMatches = abs(lastFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
                                 abs(lastFrame.origin.y - targetFrame.origin.y) <= frameTolerance
            let sizeCloseEnough = abs(lastFrame.width - targetFrame.width) <= frameTolerance * 2 &&
                                 abs(lastFrame.height - targetFrame.height) <= 100 // 允许高度有较大偏差（最小尺寸限制）

            if positionMatches && sizeCloseEnough {
                log(
                    "[WindowManager] apply frame within tolerance",
                    level: .warn,
                    fields: [
                        "op": op,
                        "stage": stage,
                        "frame": String(describing: lastFrame),
                        "target": String(describing: targetFrame),
                        "durationMs": String(elapsedMilliseconds(since: startedAt))
                    ]
                )
                return true
            }
        }

        log(
            "[WindowManager] apply frame failed",
            level: .error,
            fields: [
                "op": op,
                "stage": stage,
                "target": String(describing: targetFrame),
                "lastFrame": String(describing: lastAppliedFrame),
                "durationMs": String(elapsedMilliseconds(since: startedAt))
            ]
        )
        return false
    }

    func axFrame(forVisibleFrameOf screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        // 使用当前屏幕的 frame.maxY 进行坐标转换
        let screenMaxY = screen.frame.maxY
        return CGRect(
            x: visibleFrame.origin.x,
            y: screenMaxY - visibleFrame.maxY,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= frameTolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= frameTolerance &&
        abs(lhs.width - rhs.width) <= frameTolerance &&
        abs(lhs.height - rhs.height) <= frameTolerance
    }

    @discardableResult
    func saveWindowState(_ state: SavedWindowState, window: AXUIElement? = nil) -> SavedWindowState {
        savedWindowStates.removeAll { existing in
            shouldReplaceSavedState(existing, with: state, currentWindow: window)
        }
        savedWindowStates.append(state)
        savedWindowStates.sort { $0.savedAt < $1.savedAt }

        if let window {
            windowElementsByStateID[state.id] = window
        }

        persistSavedWindowStates()
        log("Persisted window states to UserDefaults: \(savedWindowStates.count)")
        return state
    }

    func loadSavedWindowStates() -> [SavedWindowState] {
        guard let data = UserDefaults.standard.data(forKey: savedStatesKey),
              let states = try? JSONDecoder().decode([SavedWindowState].self, from: data) else {
            return []
        }
        return states.filter { $0.windowID != nil }
    }

    func persistSavedWindowStates() {
        guard let data = try? JSONEncoder().encode(savedWindowStates) else {
            log("Failed to encode saved window states")
            return
        }
        UserDefaults.standard.set(data, forKey: savedStatesKey)
    }

    func clearSavedWindowState(id: String?) {
        guard let id else { return }
        savedWindowStates.removeAll { $0.id == id }
        windowElementsByStateID.removeValue(forKey: id)
        persistSavedWindowStates()
        log("Cleared persisted window state: \(id)")
    }

    func resetActiveWindowContext(removeState: Bool) {
        let activeStateID = lastWindowToken?.stateID
        lastWindowElement = nil
        lastWindowToken = nil
        lastWindowFrame = nil
        lastTargetFrame = nil
        lastSourceSpaceIndex = nil
        lastTargetSpaceIndex = nil
        lastSourceYabaiDisplayIndex = nil
        lastSourceDisplaySpaceIndex = nil
        if removeState {
            clearSavedWindowState(id: activeStateID)
        }
    }

    func hydrateMemory(from state: SavedWindowState, window: AXUIElement?) {
        lastWindowElement = window ?? windowElementsByStateID[state.id]
        lastWindowToken = WindowToken(
            stateID: state.id,
            pid: state.pid,
            bundleIdentifier: state.bundleIdentifier,
            appName: state.appName,
            windowID: state.windowID,
            windowNumber: state.windowNumber,
            title: state.title
        )
        lastWindowFrame = state.originalFrame.cgRect
        lastTargetFrame = state.targetFrame.cgRect
        lastSourceSpaceIndex = state.sourceSpaceIndex
        lastTargetSpaceIndex = state.targetSpaceIndex
        lastSourceYabaiDisplayIndex = state.sourceYabaiDisplayIndex
        lastSourceDisplaySpaceIndex = state.sourceDisplaySpaceIndex
    }

    func shouldReplaceSavedState(
        _ existing: SavedWindowState,
        with incoming: SavedWindowState,
        currentWindow: AXUIElement?
    ) -> Bool {
        if existing.id == incoming.id {
            return true
        }

        if let currentWindow,
           let cachedWindow = windowElementsByStateID[existing.id],
           CFEqual(cachedWindow, currentWindow) {
            return true
        }

        guard let existingID = existing.windowID,
              let incomingID = incoming.windowID else {
            return false
        }

        return existingID == incomingID
    }

}
