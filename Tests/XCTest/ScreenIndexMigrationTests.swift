import Testing
import Foundation
import SwiftUI
@testable import VibeFocusKit

@Suite("ScreenIndexPreferences Migration")
struct ScreenIndexMigrationTests {

    private func makeLegacyJSON(
        isEnabled: Bool = true,
        position: String = "topRight",
        fontSize: CGFloat = 48,
        opacity: CGFloat = 0.8,
        panelScale: CGFloat? = nil,
        panelMargin: CGFloat? = nil
    ) -> Data {
        var dict: [String: Any] = [
            "isEnabled": isEnabled,
            "position": position,
            "fontSize": fontSize,
            "opacity": opacity,
            "textColor": ["red": 1.0, "green": 1.0, "blue": 1.0, "opacity": 1.0],
            "backgroundColor": ["red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.6]
        ]
        if let panelScale { dict["panelScale"] = panelScale }
        if let panelMargin { dict["panelMargin"] = panelMargin }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test("loadLegacyPreferences decodes valid legacy JSON")
    func legacyDecodeValid() throws {
        let data = makeLegacyJSON()
        let result = ScreenIndexPreferences.loadLegacyPreferences(from: data)
        let prefs = try #require(result)
        #expect(prefs.isEnabled == true)
        #expect(prefs.position == .topRight)
        #expect(prefs.fontSize == 48)
        #expect(prefs.usePerScreenSpaceIndexing == true)
    }

    @Test("loadLegacyPreferences defaults panelScale to 1.0 when missing")
    func legacyDefaultPanelScale() throws {
        let data = makeLegacyJSON()
        let prefs = try #require(ScreenIndexPreferences.loadLegacyPreferences(from: data))
        #expect(prefs.panelScale == 1.0)
    }

    @Test("loadLegacyPreferences defaults panelMargin to 20 when missing")
    func legacyDefaultPanelMargin() throws {
        let data = makeLegacyJSON()
        let prefs = try #require(ScreenIndexPreferences.loadLegacyPreferences(from: data))
        #expect(prefs.panelMargin == 20)
    }

    @Test("loadLegacyPreferences preserves provided panelScale")
    func legacyCustomPanelScale() throws {
        let data = makeLegacyJSON(panelScale: 1.5)
        let prefs = try #require(ScreenIndexPreferences.loadLegacyPreferences(from: data))
        #expect(prefs.panelScale == 1.5)
    }

    @Test("loadLegacyPreferences preserves provided panelMargin")
    func legacyCustomPanelMargin() throws {
        let data = makeLegacyJSON(panelMargin: 30)
        let prefs = try #require(ScreenIndexPreferences.loadLegacyPreferences(from: data))
        #expect(prefs.panelMargin == 30)
    }

    @Test("loadLegacyPreferences returns nil for invalid JSON")
    func legacyInvalidJSON() {
        let data = Data("not json".utf8)
        #expect(ScreenIndexPreferences.loadLegacyPreferences(from: data) == nil)
    }

    @Test("loadLegacyPreferences returns nil for empty data")
    func legacyEmptyData() {
        let data = Data()
        #expect(ScreenIndexPreferences.loadLegacyPreferences(from: data) == nil)
    }

    @Test("enforcePerScreenSpaceIndexingIfNeeded: already true → unchanged")
    func enforceAlreadyTrue() {
        var prefs = ScreenIndexPreferences.default
        prefs.usePerScreenSpaceIndexing = true
        let result = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(prefs)
        #expect(result.usePerScreenSpaceIndexing == true)
    }

    @Test("enforcePerScreenSpaceIndexingIfNeeded: false → migrated to true")
    func enforceMigratesFalse() {
        var prefs = ScreenIndexPreferences.default
        prefs.usePerScreenSpaceIndexing = false
        let result = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(prefs)
        #expect(result.usePerScreenSpaceIndexing == true)
    }
}
