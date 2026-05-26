import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpacePreferences UserDefaults Roundtrip", .serialized)
struct SpacePreferencesTests {

    private func saveAndRestore(key: String, _ block: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        block()
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - integrationEnabled

    @Test("integrationEnabled default is true when key absent")
    func integrationEnabledDefault() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            UserDefaults.standard.removeObject(forKey: SpacePreferences.integrationEnabledKey)
            #expect(SpacePreferences.integrationEnabled == true)
        }
    }

    @Test("integrationEnabled returns false when set to false")
    func integrationEnabledFalse() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            SpacePreferences.integrationEnabled = false
            #expect(SpacePreferences.integrationEnabled == false)
        }
    }

    @Test("integrationEnabled returns true when set to true")
    func integrationEnabledTrue() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            SpacePreferences.integrationEnabled = true
            #expect(SpacePreferences.integrationEnabled == true)
        }
    }

    // MARK: - restoreStrategy

    @Test("restoreStrategy default is switchToOriginal when key absent")
    func restoreStrategyDefault() {
        saveAndRestore(key: SpacePreferences.restoreStrategyKey) {
            UserDefaults.standard.removeObject(forKey: SpacePreferences.restoreStrategyKey)
            #expect(SpacePreferences.restoreStrategy == .switchToOriginal)
        }
    }

    @Test("restoreStrategy roundtrip switchToOriginal")
    func restoreStrategySwitchToOriginal() {
        saveAndRestore(key: SpacePreferences.restoreStrategyKey) {
            SpacePreferences.restoreStrategy = .switchToOriginal
            #expect(SpacePreferences.restoreStrategy == .switchToOriginal)
        }
    }

    @Test("restoreStrategy roundtrip pullToCurrent")
    func restoreStrategyPullToCurrent() {
        saveAndRestore(key: SpacePreferences.restoreStrategyKey) {
            SpacePreferences.restoreStrategy = .pullToCurrent
            #expect(SpacePreferences.restoreStrategy == .pullToCurrent)
        }
    }

    @Test("restoreStrategy falls back to switchToOriginal for invalid raw value")
    func restoreStrategyInvalidFallback() {
        saveAndRestore(key: SpacePreferences.restoreStrategyKey) {
            UserDefaults.standard.set("invalidValue", forKey: SpacePreferences.restoreStrategyKey)
            #expect(SpacePreferences.restoreStrategy == .switchToOriginal)
        }
    }

    // MARK: - key stability

    @Test("integrationEnabledKey is stable")
    func integrationEnabledKeyStable() {
        #expect(SpacePreferences.integrationEnabledKey == "spaceIntegrationEnabled")
    }

    @Test("restoreStrategyKey is stable")
    func restoreStrategyKeyStable() {
        #expect(SpacePreferences.restoreStrategyKey == "spaceRestoreStrategy")
    }
}
