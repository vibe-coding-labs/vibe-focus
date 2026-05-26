import Testing
import Foundation
@testable import VibeFocusKit

@Suite("HeaderValue Case-Insensitive Lookup")
@MainActor
struct HeaderValueLookupTests {

    // MARK: - Exact match

    @Test("resolveHeaderValue: exact key match returns value")
    func exactMatch() {
        let headers = ["X-VibeFocus-Token": "abc123"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token") == "abc123")
    }

    @Test("resolveHeaderValue: exact match takes priority over case-insensitive")
    func exactMatchPriority() {
        let headers = ["Key": "exact", "key": "lower"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "Key") == "exact")
    }

    // MARK: - Case-insensitive fallback

    @Test("resolveHeaderValue: case-insensitive match when exact not found")
    func caseInsensitive() {
        let headers = ["x-vibefocus-token": "abc123"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token") == "abc123")
    }

    @Test("resolveHeaderValue: all-lowercase key matches mixed-case lookup")
    func lowercaseKey() {
        let headers = ["content-type": "application/json"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "Content-Type") == "application/json")
    }

    @Test("resolveHeaderValue: all-uppercase key matches lowercase lookup")
    func uppercaseKey() {
        let headers = ["AUTHORIZATION": "Bearer token"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "authorization") == "Bearer token")
    }

    // MARK: - Not found

    @Test("resolveHeaderValue: missing key returns nil")
    func missingKey() {
        let headers = ["Content-Type": "application/json"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-Custom") == nil)
    }

    @Test("resolveHeaderValue: empty headers returns nil")
    func emptyHeaders() {
        #expect(ClaudeHookServer.resolveHeaderValue(from: [:], forKey: "Key") == nil)
    }

    // MARK: - Edge cases

    @Test("resolveHeaderValue: empty key returns nil")
    func emptyKey() {
        let headers = ["": "value"]
        #expect(ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "") == "value")
    }

    @Test("resolveHeaderValue: returns first case-insensitive match")
    func firstMatch() {
        let headers = ["X-Token": "first", "x-token": "second"]
        let result = ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-TOKEN")
        #expect(result == "first" || result == "second")
    }
}
