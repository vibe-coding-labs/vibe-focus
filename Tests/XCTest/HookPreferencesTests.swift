import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ClaudeHookPreferences", .serialized)
struct HookPreferencesTests {

    // MARK: - normalizePort (tested indirectly via endpointURLString and hookCommandExample)

    @Test("endpointURLString with default port uses 39277")
    func endpointURLDefaultPort() {
        let url = ClaudeHookPreferences.endpointURLString(port: 39277)
        #expect(url.contains("127.0.0.1:39277"))
        #expect(url.contains("/claude/hook"))
    }

    @Test("endpointURLString with port below minimum is clamped to 1024")
    func endpointURLPortBelowMin() {
        let url = ClaudeHookPreferences.endpointURLString(port: 80)
        #expect(url.contains("127.0.0.1:1024"))
    }

    @Test("endpointURLString with port above maximum is clamped to 65535")
    func endpointURLPortAboveMax() {
        let url = ClaudeHookPreferences.endpointURLString(port: 99999)
        #expect(url.contains("127.0.0.1:65535"))
    }

    @Test("endpointURLString with port at minimum boundary 1024")
    func endpointURLPortAtMin() {
        let url = ClaudeHookPreferences.endpointURLString(port: 1024)
        #expect(url.contains("127.0.0.1:1024"))
    }

    @Test("endpointURLString with port at maximum boundary 65535")
    func endpointURLPortAtMax() {
        let url = ClaudeHookPreferences.endpointURLString(port: 65535)
        #expect(url.contains("127.0.0.1:65535"))
    }

    @Test("endpointURLString always starts with http://127.0.0.1 and contains /claude/hook")
    func endpointURLStructure() {
        let url = ClaudeHookPreferences.endpointURLString(port: 5000)
        #expect(url.hasPrefix("http://127.0.0.1:"))
        #expect(url.contains("/claude/hook"))
    }

    @Test("endpointURLString with token present includes query parameter")
    func endpointURLTokenQueryFormat() {
        // Regardless of current token state, verify URL format when token is present
        let savedToken = ClaudeHookPreferences.authToken
        ClaudeHookPreferences.authToken = "test-token-123"
        defer { ClaudeHookPreferences.authToken = savedToken }

        let url = ClaudeHookPreferences.endpointURLString(port: 5000)
        #expect(url.contains("?token=test-token-123"))
    }

    // MARK: - hookCommandExample

    @Test("hookCommandExample contains curl POST to correct port")
    func hookCommandExampleContainsPort() {
        let example = ClaudeHookPreferences.hookCommandExample(port: 12345)
        #expect(example.contains("127.0.0.1:12345"))
        #expect(example.contains("/claude/hook"))
        #expect(example.contains("#!/bin/bash"))
    }

    @Test("hookCommandExample without token has no X-VibeFocus-Token header")
    func hookCommandExampleNoToken() {
        let example = ClaudeHookPreferences.hookCommandExample(port: 39277, token: nil)
        #expect(!example.contains("X-VibeFocus-Token"))
    }

    @Test("hookCommandExample with token includes X-VibeFocus-Token header")
    func hookCommandExampleWithToken() {
        let example = ClaudeHookPreferences.hookCommandExample(port: 39277, token: "my-secret")
        #expect(example.contains("X-VibeFocus-Token: my-secret"))
    }

    @Test("hookCommandExample clamps port")
    func hookCommandExampleClampsPort() {
        let example = ClaudeHookPreferences.hookCommandExample(port: 50)
        #expect(example.contains("127.0.0.1:1024"))
    }

    @Test("hookCommandExample contains Content-Type json header")
    func hookCommandExampleContentType() {
        let example = ClaudeHookPreferences.hookCommandExample(port: 39277)
        #expect(example.contains("Content-Type: application/json"))
    }

    // MARK: - generateHooksDict

    @Test("generateHooksDict always includes SessionStart")
    func generateHooksDictAlwaysHasSessionStart() {
        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["SessionStart"] != nil)
    }

    @Test("generateHooksDict includes Stop when triggerOnStop is true")
    func generateHooksDictStopEnabled() {
        let saved = ClaudeHookPreferences.triggerOnStop
        ClaudeHookPreferences.triggerOnStop = true
        defer { ClaudeHookPreferences.triggerOnStop = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["Stop"] != nil)
    }

    @Test("generateHooksDict always includes Stop (remoteOnly handled in handleStop)")
    func generateHooksDictStopAlwaysIncluded() {
        let saved = ClaudeHookPreferences.triggerOnStop
        ClaudeHookPreferences.triggerOnStop = false
        defer { ClaudeHookPreferences.triggerOnStop = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        // Stop 始终注册到 hook 配置，handleStop 内部通过 remoteOnly 区分本地/远程
        #expect(dict["Stop"] != nil)
    }

    @Test("generateHooksDict includes SessionEnd when triggerOnSessionEnd is true")
    func generateHooksDictSessionEndEnabled() {
        let saved = ClaudeHookPreferences.triggerOnSessionEnd
        ClaudeHookPreferences.triggerOnSessionEnd = true
        defer { ClaudeHookPreferences.triggerOnSessionEnd = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["SessionEnd"] != nil)
    }

    @Test("generateHooksDict excludes SessionEnd when triggerOnSessionEnd is false")
    func generateHooksDictSessionEndDisabled() {
        let saved = ClaudeHookPreferences.triggerOnSessionEnd
        ClaudeHookPreferences.triggerOnSessionEnd = false
        defer { ClaudeHookPreferences.triggerOnSessionEnd = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["SessionEnd"] == nil)
    }

    @Test("generateHooksDict includes UserPromptSubmit when autoRestoreOnPromptSubmit is true")
    func generateHooksDictPromptSubmitEnabled() {
        let saved = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = true
        defer { ClaudeHookPreferences.autoRestoreOnPromptSubmit = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["UserPromptSubmit"] != nil)
    }

    @Test("generateHooksDict excludes UserPromptSubmit when autoRestoreOnPromptSubmit is false")
    func generateHooksDictPromptSubmitDisabled() {
        let saved = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = false
        defer { ClaudeHookPreferences.autoRestoreOnPromptSubmit = saved }

        let dict = ClaudeHookPreferences.generateHooksDict()
        #expect(dict["UserPromptSubmit"] == nil)
    }

    @Test("generateHooksDict hook entries contain command type")
    func generateHooksDictEntryStructure() {
        let dict = ClaudeHookPreferences.generateHooksDict()
        guard let entries = dict["SessionStart"] as? [[String: Any]] else {
            Issue.record("SessionStart should be [[String: Any]]")
            return
        }
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry["matcher"] as? String == "")
        guard let hooks = entry["hooks"] as? [[String: Any]] else {
            Issue.record("hooks should be [[String: Any]]")
            return
        }
        #expect(hooks.count == 1)
        #expect(hooks[0]["type"] as? String == "command")
        #expect(hooks[0]["timeout"] as? Int == 10)
    }

    // MARK: - ensureTokenGenerated / authToken

    @Test("ensureTokenGenerated returns a 32-char lowercase hex string")
    func ensureTokenGeneratedFormat() {
        let savedToken = ClaudeHookPreferences.authToken
        ClaudeHookPreferences.authToken = ""
        defer { ClaudeHookPreferences.authToken = savedToken }

        let token = ClaudeHookPreferences.ensureTokenGenerated()
        #expect(token.count == 32)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(token == token.lowercased())
    }

    @Test("ensureTokenGenerated returns existing token if present")
    func ensureTokenGeneratedReusesExisting() {
        let savedToken = ClaudeHookPreferences.authToken
        ClaudeHookPreferences.authToken = "existing-token-1234567890ab"
        defer { ClaudeHookPreferences.authToken = savedToken }

        let token = ClaudeHookPreferences.ensureTokenGenerated()
        #expect(token == "existing-token-1234567890ab")
    }

    @Test("authToken trims whitespace on set")
    func authTokenTrimsWhitespace() {
        let savedToken = ClaudeHookPreferences.authToken
        ClaudeHookPreferences.authToken = "  hello  \n"
        let read = ClaudeHookPreferences.authToken
        #expect(read == "hello")
        ClaudeHookPreferences.authToken = savedToken
    }

    @Test("authToken returns nil for empty string after trimming")
    func authTokenEmptyIsNil() {
        let savedToken = ClaudeHookPreferences.authToken
        ClaudeHookPreferences.authToken = "   \n  "
        #expect(ClaudeHookPreferences.authToken == nil)
        ClaudeHookPreferences.authToken = savedToken
    }

    // MARK: - Default values

    @Test("default port is 39277")
    func defaultPort() {
        #expect(ClaudeHookPreferences.defaultPort == 39277)
    }

    @Test("endpoint path is /claude/hook")
    func endpointPath() {
        #expect(ClaudeHookPreferences.endpointPath == "/claude/hook")
    }

    @Test("default enabled is false")
    func defaultEnabled() {
        #expect(ClaudeHookPreferences.defaultEnabled == false)
    }

    @Test("default autoFocusOnSessionEnd is true")
    func defaultAutoFocus() {
        #expect(ClaudeHookPreferences.defaultAutoFocusOnSessionEnd == true)
    }

    @Test("default triggerOnStop is true")
    func defaultTriggerOnStop() {
        #expect(ClaudeHookPreferences.defaultTriggerOnStop == true)
    }

    @Test("default triggerOnSessionEnd is false")
    func defaultTriggerOnSessionEnd() {
        #expect(ClaudeHookPreferences.defaultTriggerOnSessionEnd == false)
    }

    @Test("default autoRestoreOnPromptSubmit is true")
    func defaultAutoRestore() {
        #expect(ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit == true)
    }

    // MARK: - String.sanitizedForShell

    @Test("sanitizedForShell wraps in single quotes")
    func sanitizedForShellBasic() {
        let result = "hello".sanitizedForShell()
        #expect(result == "'hello'")
    }

    @Test("sanitizedForShell escapes embedded single quotes")
    func sanitizedForShellWithQuote() {
        let result = "it's".sanitizedForShell()
        #expect(result == "'it'\\''s'")
    }

    @Test("sanitizedForShell handles empty string")
    func sanitizedForShellEmpty() {
        let result = "".sanitizedForShell()
        #expect(result == "''")
    }

    @Test("sanitizedForShell handles string with multiple single quotes")
    func sanitizedForShellMultipleQuotes() {
        let result = "a'b'c".sanitizedForShell()
        #expect(result == "'a'\\''b'\\''c'")
    }

    // MARK: - generateHooksJSON output verification

    @Test("generateHooksJSON produces valid JSON with hooks key")
    func generateHooksJSONStructure() throws {
        let json = ClaudeHookPreferences.generateHooksJSON()
        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil)
    }

    @Test("generateHooksJSON: each hook entry has matcher and hooks array")
    func generateHooksJSONEntryDetail() throws {
        let json = ClaudeHookPreferences.generateHooksJSON()
        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        let sessionStartEntries = try #require(hooks["SessionStart"] as? [[String: Any]])
        let entry = try #require(sessionStartEntries.first)
        #expect(entry["matcher"] as? String == "")
        let hookList = try #require(entry["hooks"] as? [[String: Any]])
        let hook = try #require(hookList.first)
        #expect(hook["type"] as? String == "command")
        #expect(hook["command"] as? String != nil)
    }
}
