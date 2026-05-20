import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - System Events Fallback
// JXA/AppleScript 后备操作：当 AX 不可用时通过 System Events 操作窗口
@MainActor
extension WindowManager {

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
        let origFrame = snapshot.frame

        log("System Events snapshot frame: \(origFrame)")
        log("System Events target frame: \(targetFrame)")

        guard systemEventsApply(frame: targetFrame, toPID: frontApp.processIdentifier) else {
            log("System Events fallback failed to move window")
            return
        }

        // 不保存 sourceSpace=0 的 ToggleRecord — 0 是无效 yabai index，restore 时会切换到错误 Space
        // SystemEvents fallback 无法获取 yabai space 信息，无法安全地支持 toggle-restore
        if let windowID = snapshot.windowID {
            log(
                "[WindowManager] SystemEvents fallback moved window but skipping ToggleEngine.save (no yabai space info)",
                level: .warn,
                fields: ["windowID": String(windowID)]
            )
        }

        log("✅ MOVED WITH SYSTEM EVENTS FALLBACK")
    }

    func restoreViaSystemEvents() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier),
              let windowID = snapshot.windowID else {
            log("No window identified for System Events restore")
            return
        }

        // 从 SQLite 读取 toggle record
        guard let record = ToggleEngine.shared.load(windowID: windowID) else {
            log("No toggle record for window \(windowID) in System Events restore")
            return
        }

        log(
            "[restoreViaSystemEvents] matched window, applying frame",
            level: .debug,
            fields: [
                "windowID": String(windowID),
                "origFrame": "\(Int(record.origFrame.origin.x)),\(Int(record.origFrame.origin.y))"
            ]
        )

        guard systemEventsApply(frame: record.origFrame, toPID: frontApp.processIdentifier) else {
            log("[restoreViaSystemEvents] systemEventsApply failed", level: .error)
            return
        }

        ToggleEngine.shared.clear(windowID: windowID)
        log("✅ RESTORED WITH SYSTEM EVENTS FALLBACK")
    }

    func shouldRestoreCurrentWindowViaSystemEvents() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let snapshot = systemEventsSnapshot(forPID: frontApp.processIdentifier) else {
            return false
        }

        if let currentWindowID = snapshot.windowID,
           let record = ToggleEngine.shared.load(windowID: currentWindowID) {
            guard let mainScreen = getMainScreen() else { return false }
            if !record.isValid(mainScreenFrame: mainScreen.frame) {
                log(
                    "System Events match found but toggle record corrupted, clearing",
                    level: .warn,
                    fields: ["windowID": String(describing: currentWindowID)]
                )
                ToggleEngine.shared.clear(windowID: currentWindowID)
            } else if record.sourceSpace > 0 {
                // sourceSpace=0 是无效 yabai index（SystemEvents fallback 写入的），不支持 restore
                log("Detected valid toggle record via System Events, windowID=\(currentWindowID)")
                return true
            } else {
                log(
                    "System Events found toggle record with sourceSpace=0, clearing (invalid yabai index)",
                    level: .warn,
                    fields: ["windowID": String(currentWindowID)]
                )
                ToggleEngine.shared.clear(windowID: currentWindowID)
            }
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


    func runJXAScript(_ script: String) -> String? {
        guard let result = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript"], stdin: script) else {
            log("Failed to launch osascript")
            return nil
        }
        if result.exitCode != 0 {
            log("osascript failed (exit \(result.exitCode), scriptLength=\(script.count)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
