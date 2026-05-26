import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Token Validation Logic")
@MainActor
struct TokenValidationTests {

    // MARK: - isTokenValid

    @Test("isTokenValid: nil expected token → valid (no auth required)")
    func nilExpected() {
        #expect(ClaudeHookServer.isTokenValid(expectedToken: nil, providedToken: "anything"))
    }

    @Test("isTokenValid: empty expected token → valid (no auth required)")
    func emptyExpected() {
        #expect(ClaudeHookServer.isTokenValid(expectedToken: "", providedToken: "anything"))
    }

    @Test("isTokenValid: matching tokens → valid")
    func matchingTokens() {
        #expect(ClaudeHookServer.isTokenValid(expectedToken: "secret123", providedToken: "secret123"))
    }

    @Test("isTokenValid: mismatched tokens → invalid")
    func mismatchedTokens() {
        #expect(!ClaudeHookServer.isTokenValid(expectedToken: "secret123", providedToken: "wrong"))
    }

    @Test("isTokenValid: nil provided token when required → invalid")
    func nilProvidedWhenRequired() {
        #expect(!ClaudeHookServer.isTokenValid(expectedToken: "secret123", providedToken: nil))
    }

    @Test("isTokenValid: empty provided token when required → invalid")
    func emptyProvidedWhenRequired() {
        #expect(!ClaudeHookServer.isTokenValid(expectedToken: "secret123", providedToken: ""))
    }

    @Test("isTokenValid: nil provided when no auth required → valid")
    func nilProvidedNoAuth() {
        #expect(ClaudeHookServer.isTokenValid(expectedToken: nil, providedToken: nil))
    }

    @Test("isTokenValid: case-sensitive comparison")
    func caseSensitive() {
        #expect(!ClaudeHookServer.isTokenValid(expectedToken: "ABC", providedToken: "abc"))
    }

    // MARK: - resolveProvidedToken

    @Test("resolveProvidedToken: prefers query token over header")
    func prefersQueryToken() {
        let query = ["token": "query-token"]
        let headers = ["X-VibeFocus-Token": "header-token"]
        #expect(ClaudeHookServer.resolveProvidedToken(query: query, headers: headers) == "query-token")
    }

    @Test("resolveProvidedToken: falls back to header when no query token")
    func fallsBackToHeader() {
        let query: [String: String] = [:]
        let headers = ["X-VibeFocus-Token": "header-token"]
        #expect(ClaudeHookServer.resolveProvidedToken(query: query, headers: headers) == "header-token")
    }

    @Test("resolveProvidedToken: trims whitespace from header token")
    func trimsHeaderToken() {
        let query: [String: String] = [:]
        let headers = ["X-VibeFocus-Token": "  token-with-spaces  "]
        #expect(ClaudeHookServer.resolveProvidedToken(query: query, headers: headers) == "token-with-spaces")
    }

    @Test("resolveProvidedToken: uses case-insensitive header lookup")
    func caseInsensitiveHeader() {
        let query: [String: String] = [:]
        let headers = ["x-vibefocus-token": "lowercase-token"]
        #expect(ClaudeHookServer.resolveProvidedToken(query: query, headers: headers) == "lowercase-token")
    }

    @Test("resolveProvidedToken: empty query and headers → empty string")
    func noTokensAvailable() {
        let result = ClaudeHookServer.resolveProvidedToken(query: [:], headers: [:])
        #expect(result == "")
    }

    // MARK: - Integration: resolveProvidedToken + isTokenValid

    @Test("full token validation flow: query token accepted")
    func fullFlowQueryToken() {
        let expectedToken = "my-secret"
        let provided = ClaudeHookServer.resolveProvidedToken(
            query: ["token": "my-secret"],
            headers: [:]
        )
        #expect(ClaudeHookServer.isTokenValid(expectedToken: expectedToken, providedToken: provided))
    }

    @Test("full token validation flow: header token accepted")
    func fullFlowHeaderToken() {
        let expectedToken = "my-secret"
        let provided = ClaudeHookServer.resolveProvidedToken(
            query: [:],
            headers: ["X-VibeFocus-Token": "my-secret"]
        )
        #expect(ClaudeHookServer.isTokenValid(expectedToken: expectedToken, providedToken: provided))
    }

    @Test("full token validation flow: wrong token rejected")
    func fullFlowWrongToken() {
        let expectedToken = "my-secret"
        let provided = ClaudeHookServer.resolveProvidedToken(
            query: ["token": "wrong"],
            headers: [:]
        )
        #expect(!ClaudeHookServer.isTokenValid(expectedToken: expectedToken, providedToken: provided))
    }
}
