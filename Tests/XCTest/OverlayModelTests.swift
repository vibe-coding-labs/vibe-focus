import Testing
import Foundation
import SwiftUI
@testable import VibeFocusKit

@Suite("Overlay Model Types")
@MainActor
struct OverlayModelTests {

    // MARK: - CodableColor

    @Test("CodableColor Codable roundtrip preserves all channels")
    func codableColorRoundtrip() throws {
        let original = CodableColor(Color(red: 0.5, green: 0.25, blue: 0.75))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodableColor.self, from: data)
        #expect(abs(decoded.red - original.red) < 0.01)
        #expect(abs(decoded.green - original.green) < 0.01)
        #expect(abs(decoded.blue - original.blue) < 0.01)
    }

    @Test("CodableColor init from SwiftUI Color captures opacity")
    func codableColorOpacity() {
        let color = CodableColor(Color.white.opacity(0.5))
        #expect(color.opacity > 0)
        #expect(color.opacity < 1)
    }

    // MARK: - ScreenIndexPreferences

    @Test("ScreenIndexPreferences default values")
    func screenIndexPreferencesDefaults() {
        let d = ScreenIndexPreferences.default
        #expect(d.isEnabled == false)
        #expect(d.position == .topRight)
        #expect(d.fontSize == 48)
        #expect(d.opacity == 0.8)
        #expect(d.panelScale == 1.0)
        #expect(d.panelMargin == 20)
        #expect(d.usePerScreenSpaceIndexing == true)
    }

    @Test("ScreenIndexPreferences Codable roundtrip")
    func screenIndexPreferencesCodable() throws {
        var prefs = ScreenIndexPreferences.default
        prefs.isEnabled = true
        prefs.position = .bottomLeft
        prefs.fontSize = 64
        prefs.opacity = 0.5
        prefs.usePerScreenSpaceIndexing = false

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ScreenIndexPreferences.self, from: data)
        #expect(decoded.isEnabled == true)
        #expect(decoded.position == .bottomLeft)
        #expect(decoded.fontSize == 64)
        #expect(decoded.opacity == 0.5)
        #expect(decoded.usePerScreenSpaceIndexing == false)
    }

    @Test("ScreenIndexPreferences userDefaultsKey is stable")
    func screenIndexPreferencesKey() {
        #expect(ScreenIndexPreferences.userDefaultsKey == "screenIndexPreferences")
    }

    // MARK: - SpaceSnapshot

    @Test("SpaceSnapshot equality")
    func spaceSnapshotEquality() {
        let a = SpaceSnapshot(index: 1, isVisible: true, hasFocus: false)
        let b = SpaceSnapshot(index: 1, isVisible: true, hasFocus: false)
        #expect(a == b)
    }

    @Test("SpaceSnapshot inequality")
    func spaceSnapshotInequality() {
        let a = SpaceSnapshot(index: 1, isVisible: true, hasFocus: false)
        let b = SpaceSnapshot(index: 2, isVisible: true, hasFocus: false)
        #expect(a != b)
    }
}
