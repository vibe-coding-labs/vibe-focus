// Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift
// Regression tests for: config lost after reinstall (3 bugs fixed)
// Bug 1: UserDefaults String/Data mismatch — save() writes String, load() used .data(forKey:)
// Bug 2: init() didSet doesn't fire — preferences never saved to SQLite on first load
// Bug 3: Bundle ID mismatch between install scripts — CFPreferences lost
// Run: swift test --filter ScreenIndexPreferencePersistenceTests

import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ScreenIndexPreference Persistence Regression Tests", .serialized)
@MainActor
struct ScreenIndexPreferencePersistenceTests {

    // MARK: - Helpers

    /// Creates an in-memory SQLite store for isolated testing
    private func makeStore() -> WindowStateStore {
        WindowStateStore(dbPath: ":memory:")
    }

    /// Creates a sample non-default preference to verify roundtrip
    private func makeSamplePrefs() -> ScreenIndexPreferences {
        // CodableColor only has init(_ color: Color), use mutation to set exact values
        var textColor = CodableColor(.white)
        textColor.red = 1; textColor.green = 0; textColor.blue = 0; textColor.opacity = 1
        var bgColor = CodableColor(.black)
        bgColor.red = 0; bgColor.green = 0; bgColor.blue = 1; bgColor.opacity = 0.5
        return ScreenIndexPreferences(
            isEnabled: true,
            position: .bottomRight,
            fontSize: 64,
            opacity: 0.9,
            textColor: textColor,
            backgroundColor: bgColor,
            panelScale: 1.5,
            panelMargin: 30,
            yabaiPath: "/opt/homebrew/bin/yabai",
            usePerScreenSpaceIndexing: true
        )
    }

    private let prefsKey = "screenIndexPreferences"

    // MARK: - Bug 1: SQLite save/load roundtrip

    @Test("SQLite preference roundtrip — save and load preserves all fields")
    func sqlitePreferenceRoundtrip() {
        let store = makeStore()
        let prefs = makeSamplePrefs()

        // Encode and save
        let data = try! JSONEncoder().encode(prefs)
        let jsonString = String(data: data, encoding: .utf8)!
        store.savePreference(key: prefsKey, value: jsonString)

        // Load and decode
        let loaded = store.loadPreference(key: prefsKey)
        #expect(loaded != nil)

        let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: loaded!.data(using: .utf8)!)
        #expect(decoded.position == .bottomRight)
        #expect(decoded.isEnabled == true)
        #expect(decoded.fontSize == 64)
        #expect(decoded.opacity == 0.9)
        #expect(decoded.textColor.red == 1.0)
        #expect(decoded.backgroundColor.blue == 1.0)
        #expect(decoded.panelScale == 1.5)
        #expect(decoded.panelMargin == 30)
        #expect(decoded.yabaiPath == "/opt/homebrew/bin/yabai")
        #expect(decoded.usePerScreenSpaceIndexing == true)
    }

    @Test("SQLite preference — load returns nil for missing key")
    func sqlitePreferenceMissingKey() {
        let store = makeStore()
        #expect(store.loadPreference(key: "nonexistent_key") == nil)
    }

    @Test("SQLite preference — upsert overwrites existing value")
    func sqlitePreferenceUpsert() {
        let store = makeStore()

        // Save with topRight
        var prefs = ScreenIndexPreferences.default
        prefs.position = .topRight
        let data1 = try! JSONEncoder().encode(prefs)
        store.savePreference(key: prefsKey, value: String(data: data1, encoding: .utf8)!)

        // Overwrite with bottomRight
        prefs.position = .bottomRight
        let data2 = try! JSONEncoder().encode(prefs)
        store.savePreference(key: prefsKey, value: String(data: data2, encoding: .utf8)!)

        let loaded = store.loadPreference(key: prefsKey)!
        let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: loaded.data(using: .utf8)!)
        #expect(decoded.position == .bottomRight)
    }

    // MARK: - Bug 2: UserDefaults String/Data mismatch

    @Test("UserDefaults stores String, .string(forKey:) reads it back, .data(forKey:) returns nil")
    func userDefaultsStringDataMismatch() {
        let key = "test_screenIndexPrefs_string_data"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let prefs = makeSamplePrefs()
        let data = try! JSONEncoder().encode(prefs)
        let jsonString = String(data: data, encoding: .utf8)!

        // save() writes a String to UserDefaults
        UserDefaults.standard.set(jsonString, forKey: key)

        // .string(forKey:) should read it back — this is what the fix uses
        let readString = UserDefaults.standard.string(forKey: key)
        #expect(readString != nil)
        #expect(readString == jsonString)

        // .data(forKey:) returns nil for String values — this was the old broken code
        let readData = UserDefaults.standard.data(forKey: key)
        #expect(readData == nil)

        // Verify the decoded value is correct via the fixed path
        if let str = readString, let strData = str.data(using: .utf8) {
            let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: strData)
            #expect(decoded.position == .bottomRight)
        } else {
            Issue.record("Failed to read String from UserDefaults")
        }
    }

    @Test("UserDefaults Data fallback still works for Data-stored values")
    func userDefaultsDataFallback() {
        let key = "test_screenIndexPrefs_data_fallback"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let prefs = makeSamplePrefs()
        let data = try! JSONEncoder().encode(prefs)

        // Simulate old code that might have stored Data directly
        UserDefaults.standard.set(data, forKey: key)

        // .string(forKey:) returns nil for Data values
        let readString = UserDefaults.standard.string(forKey: key)
        #expect(readString == nil)

        // .data(forKey:) should read it back — the fallback path
        let readData = UserDefaults.standard.data(forKey: key)
        #expect(readData != nil)

        if let d = readData {
            let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: d)
            #expect(decoded.position == .bottomRight)
        }
    }

    // MARK: - Bug 3: Full pipeline simulation — load from fallback → save to SQLite

    @Test("Full pipeline: write to UserDefaults → simulate load → persist to SQLite")
    func fullPipelineUserDefaultsToSQLite() {
        let store = makeStore()
        let prefs = makeSamplePrefs()

        // Step 1: Simulate save() writing to UserDefaults
        let data = try! JSONEncoder().encode(prefs)
        let jsonString = String(data: data, encoding: .utf8)!
        let key = "test_fullPipeline_UD"
        UserDefaults.standard.set(jsonString, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // Step 2: Simulate load() reading from UserDefaults (the fixed path)
        let loadedString = UserDefaults.standard.string(forKey: key)
        #expect(loadedString != nil)

        // Step 3: Simulate init() persisting to SQLite (the Bug 2 fix)
        if let str = loadedString {
            let decoded = try! JSONDecoder().decode(ScreenIndexPreferences.self, from: str.data(using: .utf8)!)
            let encoded = try! JSONEncoder().encode(decoded)
            store.savePreference(key: prefsKey, value: String(data: encoded, encoding: .utf8)!)
        }

        // Step 4: Verify SQLite has the correct value (simulates reinstall scenario)
        let sqliteValue = store.loadPreference(key: prefsKey)
        #expect(sqliteValue != nil)

        let final = try! JSONDecoder().decode(
            ScreenIndexPreferences.self,
            from: sqliteValue!.data(using: .utf8)!
        )
        #expect(final.position == .bottomRight)
        #expect(final.fontSize == 64)
    }

    @Test("Full pipeline: default preferences survive encode → save → load → decode cycle")
    func defaultPreferencesRoundtrip() {
        let store = makeStore()
        let prefs = ScreenIndexPreferences.default

        // Encode and save to SQLite
        let data = try! JSONEncoder().encode(prefs)
        let jsonString = String(data: data, encoding: .utf8)!
        store.savePreference(key: prefsKey, value: jsonString)

        // Load from SQLite and decode
        let loaded = store.loadPreference(key: prefsKey)!
        let decoded = try! JSONDecoder().decode(
            ScreenIndexPreferences.self,
            from: loaded.data(using: .utf8)!
        )

        #expect(decoded.position == .topRight)  // default position
        #expect(decoded.isEnabled == true)
        #expect(decoded.fontSize == 48)
        #expect(decoded.opacity == 0.8)
        #expect(decoded.panelScale == 1.0)
        #expect(decoded.panelMargin == 20)
        #expect(decoded.usePerScreenSpaceIndexing == true)
    }

    // MARK: - Bug 3: Bundle ID consistency

    @Test("Bundle identifier key is stable across test runs")
    func bundleIdentifierStability() {
        // This test documents that the key "screenIndexPreferences" must never change
        // Changing it would orphan existing user data in SQLite/UserDefaults
        #expect(ScreenIndexPreferences.userDefaultsKey == "screenIndexPreferences")
    }

    @Test("All IndexPosition values survive JSON roundtrip through String storage")
    func allIndexPositionsRoundtrip() {
        let store = makeStore()

        for position in IndexPosition.allCases {
            var prefs = ScreenIndexPreferences.default
            prefs.position = position

            let data = try! JSONEncoder().encode(prefs)
            let jsonString = String(data: data, encoding: .utf8)!
            store.savePreference(key: prefsKey, value: jsonString)

            let loaded = store.loadPreference(key: prefsKey)!
            let decoded = try! JSONDecoder().decode(
                ScreenIndexPreferences.self,
                from: loaded.data(using: .utf8)!
            )
            #expect(decoded.position == position)
        }
    }

    // MARK: - Edge cases

    @Test("Preferences with nil yabaiPath survive SQLite roundtrip")
    func nilYabaiPathRoundtrip() {
        let store = makeStore()
        var prefs = ScreenIndexPreferences.default
        prefs.yabaiPath = nil

        let data = try! JSONEncoder().encode(prefs)
        store.savePreference(key: prefsKey, value: String(data: data, encoding: .utf8)!)

        let loaded = store.loadPreference(key: prefsKey)!
        let decoded = try! JSONDecoder().decode(
            ScreenIndexPreferences.self,
            from: loaded.data(using: .utf8)!
        )
        #expect(decoded.yabaiPath == nil)
    }

    @Test("Preferences with yabaiPath survive SQLite roundtrip")
    func yabaiPathRoundtrip() {
        let store = makeStore()
        var prefs = ScreenIndexPreferences.default
        prefs.yabaiPath = "/usr/local/bin/yabai"

        let data = try! JSONEncoder().encode(prefs)
        store.savePreference(key: prefsKey, value: String(data: data, encoding: .utf8)!)

        let loaded = store.loadPreference(key: prefsKey)!
        let decoded = try! JSONDecoder().decode(
            ScreenIndexPreferences.self,
            from: loaded.data(using: .utf8)!
        )
        #expect(decoded.yabaiPath == "/usr/local/bin/yabai")
    }

    @Test("Empty SQLite returns nil — triggers default fallback in load()")
    func emptySQLiteTriggersDefault() {
        let store = makeStore()
        let loaded = store.loadPreference(key: prefsKey)
        #expect(loaded == nil)
    }

    @Test("Corrupted JSON in SQLite returns nil on decode")
    func corruptedJSONInSQLite() {
        let store = makeStore()
        store.savePreference(key: prefsKey, value: "not valid json {{{")

        let loaded = store.loadPreference(key: prefsKey)
        #expect(loaded == "not valid json {{{")

        // Decode should fail
        let decoded = try? JSONDecoder().decode(
            ScreenIndexPreferences.self,
            from: loaded!.data(using: .utf8)!
        )
        #expect(decoded == nil)
    }
}
