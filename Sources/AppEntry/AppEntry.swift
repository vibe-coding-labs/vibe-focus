import SwiftUI
import VibeFocusKit

@main
/// Main application entry point — menu bar resident app with no dock icon.
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }
}
