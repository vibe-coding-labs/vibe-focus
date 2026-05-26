import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpaceController Utility Functions")
@MainActor
struct SpaceControllerUtilityTests {

    // MARK: - formatErrorMessage

    @Test("formatErrorMessage: prefers stderr when non-empty")
    func prefersStderr() {
        let result = SpaceController.formatErrorMessage(stdout: "stdout msg", stderr: "stderr msg")
        #expect(result == "stderr msg")
    }

    @Test("formatErrorMessage: falls back to stdout when stderr empty")
    func fallsBackToStdout() {
        let result = SpaceController.formatErrorMessage(stdout: "stdout msg", stderr: "")
        #expect(result == "stdout msg")
    }

    @Test("formatErrorMessage: returns default when both empty")
    func defaultWhenEmpty() {
        let result = SpaceController.formatErrorMessage(stdout: "", stderr: "")
        #expect(result == "yabai returned empty error output")
    }

    @Test("formatErrorMessage: trims whitespace from stderr")
    func trimsStderr() {
        let result = SpaceController.formatErrorMessage(stdout: "  ", stderr: "  error msg  ")
        #expect(result == "error msg")
    }

    @Test("formatErrorMessage: trims whitespace from stdout fallback")
    func trimsStdout() {
        let result = SpaceController.formatErrorMessage(stdout: "  out  ", stderr: "  ")
        #expect(result == "out")
    }

    @Test("formatErrorMessage: whitespace-only treated as empty")
    func whitespaceOnly() {
        let result = SpaceController.formatErrorMessage(stdout: "   ", stderr: "   ")
        #expect(result == "yabai returned empty error output")
    }

    // MARK: - staticDecodeSingleOrFirst

    @Test("decodeSingleOrFirst: decodes single object")
    func decodesSingle() throws {
        let json = """
        {"index": 1, "display": 2, "is-visible": true}
        """
        let result = SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: json)
        let info = try #require(result)
        #expect(info.index == 1)
        #expect(info.display == 2)
    }

    @Test("decodeSingleOrFirst: decodes first from array")
    func decodesFirstFromArray() throws {
        let json = """
        [{"index": 1}, {"index": 2}]
        """
        let result = SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: json)
        let info = try #require(result)
        #expect(info.index == 1)
    }

    @Test("decodeSingleOrFirst: returns nil for invalid JSON")
    func invalidJSON() {
        let result = SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "not json")
        #expect(result == nil)
    }

    @Test("decodeSingleOrFirst: returns nil for empty string")
    func emptyString() {
        let result = SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "")
        #expect(result == nil)
    }

    @Test("decodeSingleOrFirst: returns nil for empty array")
    func emptyArray() {
        let result = SpaceController.staticDecodeSingleOrFirst(YabaiSpaceInfo.self, from: "[]")
        #expect(result == nil)
    }

    // MARK: - decodeArray (instance method via SpaceController.shared)

    @Test("decodeArray: decodes JSON array of spaces")
    func decodeArraySpaces() throws {
        let sc = SpaceController.shared
        let json = """
        [{"index": 1, "display": 1}, {"index": 2, "display": 2}]
        """
        let result = sc.decodeArray(YabaiSpaceInfo.self, from: json)
        let arr = try #require(result)
        #expect(arr.count == 2)
        #expect(arr[0].index == 1)
        #expect(arr[1].display == 2)
    }

    @Test("decodeArray: returns nil for single object (not array)")
    func decodeArraySingleObject() {
        let sc = SpaceController.shared
        let json = """
        {"index": 1, "display": 1}
        """
        let result = sc.decodeArray(YabaiSpaceInfo.self, from: json)
        #expect(result == nil)
    }

    @Test("decodeArray: returns nil for invalid JSON")
    func decodeArrayInvalid() {
        let sc = SpaceController.shared
        let result = sc.decodeArray(YabaiSpaceInfo.self, from: "not json")
        #expect(result == nil)
    }

    @Test("decodeArray: returns empty array for empty JSON array")
    func decodeArrayEmpty() throws {
        let sc = SpaceController.shared
        let result = sc.decodeArray(YabaiSpaceInfo.self, from: "[]")
        let arr = try #require(result)
        #expect(arr.isEmpty)
    }

    @Test("decodeArray: decodes JSON array of windows")
    func decodeArrayWindows() throws {
        let sc = SpaceController.shared
        let json = """
        [{"id": 42, "app": "Terminal"}, {"id": 43, "app": "iTerm2"}]
        """
        let result = sc.decodeArray(YabaiWindowInfo.self, from: json)
        let arr = try #require(result)
        #expect(arr.count == 2)
        #expect(arr[0].id == 42)
        #expect(arr[1].app == "iTerm2")
    }
}
