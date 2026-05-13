import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window State Management
@MainActor
extension WindowManager {

    func loadSavedWindowStates() -> [SavedWindowState] {
        let states = WindowStateStore.shared.loadStates()
        log("Loaded \(states.count) window state(s) from SQLite")
        return states
    }
}
