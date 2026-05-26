import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Space & Overlay Enums")
struct SpaceEnumTests {

    // MARK: - SpaceAvailability

    @Test("SpaceAvailability raw values")
    func spaceAvailabilityRawValues() {
        #expect(SpaceAvailability.unknown.rawValue == "unknown")
        #expect(SpaceAvailability.notInstalled.rawValue == "notInstalled")
        #expect(SpaceAvailability.unavailable.rawValue == "unavailable")
        #expect(SpaceAvailability.available.rawValue == "available")
    }

    // MARK: - SpaceRestoreStrategy

    @Test("SpaceRestoreStrategy has two cases")
    func spaceRestoreStrategyCases() {
        #expect(SpaceRestoreStrategy.allCases.count == 2)
    }

    @Test("SpaceRestoreStrategy raw values")
    func spaceRestoreStrategyRawValues() {
        #expect(SpaceRestoreStrategy.switchToOriginal.rawValue == "switchToOriginal")
        #expect(SpaceRestoreStrategy.pullToCurrent.rawValue == "pullToCurrent")
    }

    // MARK: - IndexPosition

    @Test("IndexPosition has 6 cases")
    func indexPositionCases() {
        #expect(IndexPosition.allCases.count == 6)
    }

    @Test("IndexPosition raw values match case names")
    func indexPositionRawValues() {
        #expect(IndexPosition.topLeft.rawValue == "topLeft")
        #expect(IndexPosition.topCenter.rawValue == "topCenter")
        #expect(IndexPosition.topRight.rawValue == "topRight")
        #expect(IndexPosition.bottomLeft.rawValue == "bottomLeft")
        #expect(IndexPosition.bottomCenter.rawValue == "bottomCenter")
        #expect(IndexPosition.bottomRight.rawValue == "bottomRight")
    }

    @Test("IndexPosition displayName returns Chinese strings")
    func indexPositionDisplayNames() {
        for pos in IndexPosition.allCases {
            #expect(!pos.displayName.isEmpty)
        }
    }

    @Test("IndexPosition icon returns SF Symbol names")
    func indexPositionIcons() {
        for pos in IndexPosition.allCases {
            #expect(!pos.icon.isEmpty)
        }
    }

    @Test("IndexPosition Codable roundtrip")
    func indexPositionCodable() throws {
        for pos in IndexPosition.allCases {
            let data = try JSONEncoder().encode(pos)
            let decoded = try JSONDecoder().decode(IndexPosition.self, from: data)
            #expect(decoded == pos)
        }
    }

    // MARK: - SpacePreferences defaults

    @Test("SpacePreferences default values")
    func spacePreferencesDefaults() {
        #expect(SpacePreferences.defaultIntegrationEnabled == true)
        #expect(SpacePreferences.defaultRestoreStrategy == .switchToOriginal)
    }

    // MARK: - LogLevel

    @Test("LogLevel raw values")
    func logLevelRawValues() {
        #expect(LogLevel.debug.rawValue == "DEBUG")
        #expect(LogLevel.info.rawValue == "INFO")
        #expect(LogLevel.warn.rawValue == "WARN")
        #expect(LogLevel.error.rawValue == "ERROR")
    }
}
