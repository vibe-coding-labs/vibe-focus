import Testing
import Foundation
@testable import VibeFocusKit

@Suite("LANHookPreferences", .serialized)
struct LANBindingTests {

    // MARK: - remoteBindings type conversion

    @Test("remoteBindings returns empty dict when nothing stored")
    func remoteBindingsEmpty() {
        let saved = LANHookPreferences.remoteBindings
        LANHookPreferences.remoteBindings = [:]
        defer { LANHookPreferences.remoteBindings = saved }

        let result = LANHookPreferences.remoteBindings
        #expect(result.isEmpty)
    }

    @Test("remoteBindings stores and retrieves UInt32 values")
    func remoteBindingsUInt32() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        LANHookPreferences.remoteBindings = ["machine-a": UInt32(42)]
        let result = LANHookPreferences.remoteBindings
        #expect(result["machine-a"] != nil)
        #expect(result["machine-a"]! != nil)
        #expect(result["machine-a"]!! == 42)
    }

    @Test("remoteBindings setter drops nil values since UserDefaults cannot store nil in dict")
    func remoteBindingsNilValuesDropped() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        // Setting a nil value means "pending but no window selected yet"
        // The setter only stores non-nil window IDs, so nil values are dropped
        LANHookPreferences.remoteBindings = ["machine-b": nil]
        let result = LANHookPreferences.remoteBindings
        #expect(result.isEmpty)
    }

    @Test("remoteBindings filters out nil entries when writing (only stores non-nil)")
    func remoteBindingsFiltersNilOnWrite() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        // The setter only writes non-nil values to UserDefaults
        LANHookPreferences.remoteBindings = ["pending": nil]
        // When reading back, UserDefaults won't have the key since nil was dropped
        let result = LANHookPreferences.remoteBindings
        #expect(result.isEmpty)
    }

    // MARK: - activeRemoteBindings

    @Test("activeRemoteBindings filters out nil values")
    func activeRemoteBindingsFiltersNil() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        // nil values are not persisted by setter, so only active entries remain
        LANHookPreferences.remoteBindings = [
            "active": UInt32(42),
            "pending": nil
        ]
        let active = LANHookPreferences.activeRemoteBindings
        #expect(active.count == 1)
        #expect(active["active"] == 42)
    }

    @Test("activeRemoteBindings returns all when all have window IDs")
    func activeRemoteBindingsAllActive() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        LANHookPreferences.remoteBindings = [
            "a": UInt32(1),
            "b": UInt32(2),
            "c": UInt32(3)
        ]
        let active = LANHookPreferences.activeRemoteBindings
        #expect(active.count == 3)
        #expect(active["a"] == 1)
        #expect(active["b"] == 2)
        #expect(active["c"] == 3)
    }

    @Test("activeRemoteBindings returns empty dict when nothing stored")
    func activeRemoteBindingsEmpty() {
        let saved = LANHookPreferences.remoteBindings
        LANHookPreferences.remoteBindings = [:]
        defer { LANHookPreferences.remoteBindings = saved }

        let active = LANHookPreferences.activeRemoteBindings
        #expect(active.isEmpty)
    }

    // MARK: - lanMode

    @Test("lanMode can be set and read")
    func lanModeSetAndGet() {
        let saved = LANHookPreferences.lanMode
        defer { LANHookPreferences.lanMode = saved }

        LANHookPreferences.lanMode = true
        #expect(LANHookPreferences.lanMode == true)

        LANHookPreferences.lanMode = false
        #expect(LANHookPreferences.lanMode == false)
    }

    @Test("default lanMode is false")
    func defaultLanMode() {
        #expect(LANHookPreferences.defaultLanMode == false)
    }

    // MARK: - Key constants

    @Test("remoteBindingsKey is consistent")
    func keyConsistency() {
        #expect(LANHookPreferences.lanModeKey == "claudeHookLanMode")
        #expect(LANHookPreferences.remoteBindingsKey == "claudeHookRemoteBindings")
    }

    // MARK: - UInt32 edge values

    @Test("remoteBindings handles max UInt32 window ID")
    func remoteBindingsMaxUInt32() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        LANHookPreferences.remoteBindings = ["max": UInt32.max]
        let result = LANHookPreferences.remoteBindings
        #expect(result["max"] != nil)
        #expect(result["max"]! != nil)
        #expect(result["max"]!! == UInt32.max)
    }

    @Test("remoteBindings handles zero window ID")
    func remoteBindingsZeroUInt32() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        // UInt32(0) may be stored as Int in UserDefaults
        LANHookPreferences.remoteBindings = ["zero": UInt32(0)]
        let result = LANHookPreferences.remoteBindings
        #expect(result["zero"] != nil)
        #expect(result["zero"]! != nil)
        #expect(result["zero"]!! == 0)
    }

    @Test("activeRemoteBindings preserves UInt32 values")
    func activeRemoteBindingsPreservesValues() {
        let saved = LANHookPreferences.remoteBindings
        defer { LANHookPreferences.remoteBindings = saved }

        LANHookPreferences.remoteBindings = ["machine": UInt32(12345)]
        let active = LANHookPreferences.activeRemoteBindings
        #expect(active["machine"] == 12345)
    }
}
