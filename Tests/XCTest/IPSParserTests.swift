import Testing
import Foundation
@testable import VibeFocusKit

@Suite("IPS JSON Payload Parser")
@MainActor
struct IPSParserTests {

    private func parse(_ input: String) throws -> [String: Any] {
        guard let result = CrashContextRecorder.parseIPSJSONPayload(from: input) else {
            throw TestError("parseIPSJSONPayload returned nil")
        }
        return result
    }

    private struct TestError: Error { let message: String; init(_ m: String) { message = m } }

    @Test("parseIPSJSONPayload: valid two-line input")
    func validTwoLines() throws {
        let input = "header line\n{\"key\": \"value\", \"num\": 42}"
        let payload = try parse(input)
        #expect(payload["key"] as? String == "value")
        #expect(payload["num"] as? Int == 42)
    }

    @Test("parseIPSJSONPayload: skips first line and parses rest as JSON")
    func skipsFirstLine() throws {
        let input = "Java-style IPS header\n{\"captureTime\": \"2025-01-01\", \"exception\": {\"type\": \"SIGSEGV\"}}"
        let payload = try parse(input)
        #expect(payload["captureTime"] as? String == "2025-01-01")
        let exception = payload["exception"] as? [String: Any]
        #expect(exception?["type"] as? String == "SIGSEGV")
    }

    @Test("parseIPSJSONPayload: empty string returns nil")
    func emptyString() {
        let result = CrashContextRecorder.parseIPSJSONPayload(from: "")
        #expect(result == nil)
    }

    @Test("parseIPSJSONPayload: single line returns nil")
    func singleLine() {
        let result = CrashContextRecorder.parseIPSJSONPayload(from: "only one line")
        #expect(result == nil)
    }

    @Test("parseIPSJSONPayload: two lines with invalid JSON returns nil")
    func invalidJSON() {
        let result = CrashContextRecorder.parseIPSJSONPayload(from: "header\nnot json")
        #expect(result == nil)
    }

    @Test("parseIPSJSONPayload: multi-line JSON payload")
    func multiLineJSON() throws {
        let input = "header\n{\n  \"a\": 1,\n  \"b\": 2\n}"
        let payload = try parse(input)
        #expect(payload["a"] as? Int == 1)
        #expect(payload["b"] as? Int == 2)
    }

    @Test("parseIPSJSONPayload: empty JSON object after header")
    func emptyJSONObject() throws {
        let payload = try parse("header\n{}")
        #expect(payload.isEmpty)
    }

    @Test("parseIPSJSONPayload: JSON array returns nil (not a dict)")
    func jsonArrayReturnsNil() {
        let result = CrashContextRecorder.parseIPSJSONPayload(from: "header\n[1, 2, 3]")
        #expect(result == nil)
    }

    @Test("parseIPSJSONPayload: preserves nested structures")
    func nestedStructures() throws {
        let input = "header\n{\"threads\": [{\"frames\": [{\"symbol\": \"main\"}]}]}"
        let payload = try parse(input)
        let threads = payload["threads"] as? [[String: Any]]
        let firstThread = try #require(threads?.first)
        let frames = firstThread["frames"] as? [[String: Any]]
        let firstFrame = try #require(frames?.first)
        #expect(firstFrame["symbol"] as? String == "main")
    }
}
