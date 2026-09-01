import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ScreenIndexPreferences Codable")
struct ScreenIndexPreferencesCodableTests {

    // ScreenIndexPreferences uses CodableColor which requires SwiftUI Color init,
    // so we test via JSON decode/encode roundtrip with known JSON

    @Test("ScreenIndexPreferences: decodes from JSON with all fields")
    func decodeFull() throws {
        let json = """
        {
            "isEnabled": true,
            "position": "bottomLeft",
            "fontSize": 36,
            "opacity": 0.5,
            "textColor": {"red": 1, "green": 1, "blue": 1, "opacity": 1},
            "backgroundColor": {"red": 0, "green": 0, "blue": 0, "opacity": 0.6},
            "panelScale": 1.5,
            "panelMargin": 30,
            "yabaiPath": "/opt/homebrew/bin/yabai",
            "usePerScreenSpaceIndexing": false
        }
        """
        let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: Data(json.utf8))
        #expect(prefs.isEnabled == true)
        #expect(prefs.position == .bottomLeft)
        #expect(prefs.fontSize == 36)
        #expect(prefs.opacity == 0.5)
        #expect(prefs.panelScale == 1.5)
        #expect(prefs.panelMargin == 30)
        #expect(prefs.yabaiPath == "/opt/homebrew/bin/yabai")
        #expect(prefs.usePerScreenSpaceIndexing == false)
    }

    @Test("ScreenIndexPreferences: encode-decode roundtrip")
    func roundtrip() throws {
        let json = """
        {
            "isEnabled": false,
            "position": "topRight",
            "fontSize": 48,
            "opacity": 0.8,
            "textColor": {"red": 1, "green": 1, "blue": 1, "opacity": 1},
            "backgroundColor": {"red": 0, "green": 0, "blue": 0, "opacity": 0.6},
            "panelScale": 1.0,
            "panelMargin": 20,
            "yabaiPath": null,
            "usePerScreenSpaceIndexing": true
        }
        """
        let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ScreenIndexPreferences.self, from: encoded)
        #expect(decoded.isEnabled == prefs.isEnabled)
        #expect(decoded.position == prefs.position)
        #expect(decoded.fontSize == prefs.fontSize)
        #expect(decoded.opacity == prefs.opacity)
        #expect(decoded.panelScale == prefs.panelScale)
        #expect(decoded.yabaiPath == prefs.yabaiPath)
        #expect(decoded.usePerScreenSpaceIndexing == prefs.usePerScreenSpaceIndexing)
    }

    @Test("ScreenIndexPreferences: all positions are valid")
    func allPositionsValid() throws {
        for position in IndexPosition.allCases {
            let json = """
            {
                "isEnabled": true,
                "position": "\(position.rawValue)",
                "fontSize": 48,
                "opacity": 0.8,
                "textColor": {"red": 1, "green": 1, "blue": 1, "opacity": 1},
                "backgroundColor": {"red": 0, "green": 0, "blue": 0, "opacity": 0.6},
                "panelScale": 1.0,
                "panelMargin": 20,
                "usePerScreenSpaceIndexing": true
            }
            """
            let prefs = try JSONDecoder().decode(ScreenIndexPreferences.self, from: Data(json.utf8))
            #expect(prefs.position == position)
        }
    }

    @Test("ScreenIndexPreferences: userDefaultsKey constant")
    func userDefaultsKey() {
        #expect(ScreenIndexPreferences.userDefaultsKey == "screenIndexPreferences")
    }
}
