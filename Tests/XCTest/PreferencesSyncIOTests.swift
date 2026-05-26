import Testing
import Foundation
@testable import VibeFocusKit

@Suite("PreferencesSync I/O")
struct PreferencesSyncIOTests {

    // Use unique keys to avoid polluting real preferences
    private let testPrefix = "com.vibefocus.test."

    // MARK: - PreferenceValue read/write roundtrip

    @Test("readFromUserDefaults: bool roundtrip")
    func boolRoundtrip() {
        let key = testPrefix + "bool"
        PreferenceValue.bool(true).writeToUserDefaults(key: key)
        let result = PreferenceValue.readFromUserDefaults(key: key)
        if case .bool(let v) = result {
            #expect(v == true)
        } else {
            #expect(Bool(false), "Expected .bool, got \(String(describing: result))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults: bool false roundtrip")
    func boolFalseRoundtrip() {
        let key = testPrefix + "boolFalse"
        PreferenceValue.bool(false).writeToUserDefaults(key: key)
        // Note: UserDefaults returns false for missing keys too,
        // but our readFromUserDefaults checks type first
        let result = PreferenceValue.readFromUserDefaults(key: key)
        if case .bool(let v) = result {
            #expect(v == false)
        } else {
            #expect(Bool(false), "Expected .bool, got \(String(describing: result))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults: int roundtrip")
    func intRoundtrip() {
        let key = testPrefix + "int"
        PreferenceValue.int(42).writeToUserDefaults(key: key)
        let result = PreferenceValue.readFromUserDefaults(key: key)
        if case .int(let v) = result {
            #expect(v == 42)
        } else {
            #expect(Bool(false), "Expected .int, got \(String(describing: result))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults: string roundtrip")
    func stringRoundtrip() {
        let key = testPrefix + "string"
        PreferenceValue.string("hello").writeToUserDefaults(key: key)
        let result = PreferenceValue.readFromUserDefaults(key: key)
        if case .string(let v) = result {
            #expect(v == "hello")
        } else {
            #expect(Bool(false), "Expected .string, got \(String(describing: result))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults: data roundtrip")
    func dataRoundtrip() {
        let key = testPrefix + "data"
        let original = Data("test-bytes".utf8)
        PreferenceValue.data(original).writeToUserDefaults(key: key)
        let result = PreferenceValue.readFromUserDefaults(key: key)
        if case .data(let v) = result {
            #expect(v == original)
        } else {
            #expect(Bool(false), "Expected .data, got \(String(describing: result))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults: missing key returns nil")
    func missingKeyReturnsNil() {
        let key = testPrefix + "nonexistent.\(UUID().uuidString)"
        let result = PreferenceValue.readFromUserDefaults(key: key)
        #expect(result == nil)
    }

    // MARK: - configFilePath

    @Test("configFilePath: ends with .vibefocus/config.json")
    func configFilePath() {
        #expect(PreferencesSync.configFilePath.hasSuffix(".vibefocus/config.json"))
    }

    @Test("configFilePath: starts with home directory")
    func configFilePathHomeDir() {
        #expect(PreferencesSync.configFilePath.hasPrefix(NSHomeDirectory()))
    }
}
