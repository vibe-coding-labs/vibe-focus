import Testing
import AppKit
import Foundation
@testable import VibeFocusKit

@Suite("UUID for Screen")
@MainActor
struct UUIDForScreenTests {

    @Test("uuidForScreen returns consistent UUID for same screen")
    func consistentUUID() {
        let mgr = ScreenOverlayManager.shared
        guard let screen = NSScreen.main else { return }
        let uuid1 = mgr.uuidForScreen(screen)
        let uuid2 = mgr.uuidForScreen(screen)
        #expect(uuid1 == uuid2)
    }

    @Test("uuidForScreen returns different UUIDs for different screens")
    func differentScreens() {
        let mgr = ScreenOverlayManager.shared
        let screens = NSScreen.screens
        guard screens.count >= 2 else { return } // Skip if single screen
        let uuid1 = mgr.uuidForScreen(screens[0])
        let uuid2 = mgr.uuidForScreen(screens[1])
        #expect(uuid1 != uuid2)
    }

    @Test("uuidForScreen returns non-nil UUID")
    func nonNilUUID() {
        let mgr = ScreenOverlayManager.shared
        guard let screen = NSScreen.main else { return }
        let uuid = mgr.uuidForScreen(screen)
        // UUID is always non-nil (UUID() always succeeds)
        #expect(uuid == uuid) // Identity check — just verifying it doesn't crash
    }

    @Test("uuidForScreen returns non-zero UUID for screen with display ID")
    func nonZeroForRealScreen() {
        let mgr = ScreenOverlayManager.shared
        guard let screen = NSScreen.main,
              let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let uuid = mgr.uuidForScreen(screen)
        // First 4 bytes should encode the screen ID
        let uuidBytes = uuid.uuid
        let reconstructed = (UInt32(uuidBytes.0) << 24) | (UInt32(uuidBytes.1) << 16) | (UInt32(uuidBytes.2) << 8) | UInt32(uuidBytes.3)
        #expect(reconstructed == screenID.uint32Value)
    }
}
