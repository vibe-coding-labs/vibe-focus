import SwiftUI
import AppKit
import Carbon
import ApplicationServices.HIServices
import CoreFoundation
import Foundation

// MARK: - Window Manager
@MainActor
class WindowManager {
    static let shared = WindowManager()

    let savedStatesKey = "savedWindowStates"
    let spaceController = SpaceController.shared
    var windowElementsByStateID: [String: AXUIElement] = [:]
    var lastWindowElement: AXUIElement?
    var lastWindowToken: WindowToken?
    var lastWindowFrame: CGRect?
    var lastTargetFrame: CGRect?
    var lastSourceSpaceIndex: Int?
    var lastTargetSpaceIndex: Int?
    var lastSourceYabaiDisplayIndex: Int?
    var lastSourceDisplaySpaceIndex: Int?
    var savedWindowStates: [SavedWindowState] = []
    var focusSpaceKnownBroken: Bool = false
    var didPromptForAccessibility = false
    let frameTolerance: CGFloat = 10
    let axWindowNumberAttribute = "AXWindowNumber"
    let axFrameAttribute = "AXFrame"

    struct WindowToken {
        let stateID: String
        let pid: pid_t
        let bundleIdentifier: String?
        let appName: String?
        let windowID: UInt32?
        let windowNumber: Int?
        let title: String?
    }

    struct RectPayload: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct SavedWindowState: Codable {
        let id: String
        let pid: Int32
        let bundleIdentifier: String?
        let appName: String?
        let windowID: UInt32?
        let windowNumber: Int?
        let title: String?
        let originalFrame: RectPayload
        let targetFrame: RectPayload
        let sourceSpaceIndex: Int?
        let targetSpaceIndex: Int?
        let sourceYabaiDisplayIndex: Int?
        let sourceDisplaySpaceIndex: Int?
        let sourceDisplayIndex: Int?
        let sourceDisplayID: UInt32?
        let targetDisplayIndex: Int?
        let restoreReason: String?
        let sessionID: String?
        let savedAt: Date
    }

    struct ScriptWindowSnapshot: Codable {
        let windowID: UInt32?
        let appName: String
        let title: String?
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        var frame: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    init() {
        savedWindowStates = loadSavedWindowStates()
        if !savedWindowStates.isEmpty {
            log("Loaded persisted window states from SQLite: \(savedWindowStates.count)")
        }
        cleanupStaleStatesWithGracePeriod()
    }

    private func cleanupStaleStatesWithGracePeriod() {
        let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let existingWindowIDs = Set(windowList.compactMap { $0["kCGWindowNumber"] as? UInt32 })

        let gracePeriod: TimeInterval = 5 * 60
        let removed = WindowStateStore.shared.cleanupStaleStates(
            existingWindowIDs: existingWindowIDs,
            gracePeriod: gracePeriod
        )

        if removed > 0 {
            savedWindowStates.removeAll { state in
                guard let wid = state.windowID else { return false }
                return !existingWindowIDs.contains(wid)
            }
            log("[WindowManager] cleanup with grace period: removed \(removed) stale state(s)")
        }
    }

    func getCurrentWindowFrame(windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            if let wid = w["kCGWindowNumber"] as? UInt32, wid == windowID {
                if let b = w["kCGWindowBounds"] as? [String: Double] {
                    return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                }
            }
        }
        return nil
    }


    func getMainScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        log(
            "[WindowManager] getMainScreen called",
            level: .debug,
            fields: [
                "mainDisplayID": String(mainDisplayID),
                "screenCount": String(NSScreen.screens.count)
            ]
        )
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let value = screen.deviceDescription[key] as? NSNumber,
               CGDirectDisplayID(value.uint32Value) == mainDisplayID {
                log(
                    "[WindowManager] getMainScreen found match",
                    level: .debug,
                    fields: ["screenNumber": String(value.uint32Value)]
                )
                return screen
            }
        }
        log(
            "[WindowManager] getMainScreen no exact match, using first or main",
            level: .debug,
            fields: ["fallback": NSScreen.screens.first != nil ? "first" : "main"]
        )
        return NSScreen.screens.first ?? NSScreen.main
    }

    func hasAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log(
            "[WindowManager] hasAccessibilityPermission checked",
            level: .debug,
            fields: ["trusted": String(trusted)]
        )
        return trusted
    }

    func notifyAccessibilityPermissionRequired() {
        guard !didPromptForAccessibility else {
            log(
                "[WindowManager] notifyAccessibilityPermissionRequired skipped: already prompted",
                level: .debug
            )
            return
        }

        log(
            "[WindowManager] notifyAccessibilityPermissionRequired: showing prompt",
            level: .debug
        )
        didPromptForAccessibility = true
        NSSound.beep()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }


}
