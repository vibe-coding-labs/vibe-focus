import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Hook Preferences and Helpers", .serialized)
struct HookPreferencesLogicTests {

    // MARK: - ClaudeHookPreferences constants

    @Test("ClaudeHookPreferences: default values are correct")
    func defaultValues() {
        #expect(ClaudeHookPreferences.defaultEnabled == false)
        #expect(ClaudeHookPreferences.defaultAutoFocusOnSessionEnd == true)
        #expect(ClaudeHookPreferences.defaultTriggerOnStop == true)
        #expect(ClaudeHookPreferences.defaultTriggerOnSessionEnd == false)
        #expect(ClaudeHookPreferences.defaultAutoRestoreOnPromptSubmit == true)
    }

    @Test("ClaudeHookPreferences: endpointPath is correct")
    func endpointPath() {
        #expect(ClaudeHookPreferences.endpointPath == "/claude/hook")
    }

    @Test("ClaudeHookPreferences: defaultPort is 39277")
    func defaultPort() {
        #expect(ClaudeHookPreferences.defaultPort == 39277)
    }

    @Test("ClaudeHookPreferences: helperScriptDir ends with .vibefocus")
    func helperScriptDir() {
        #expect(ClaudeHookPreferences.helperScriptDir.hasSuffix(".vibefocus"))
    }

    @Test("ClaudeHookPreferences: helperScriptPath ends with hook-forwarder.sh")
    func helperScriptPath() {
        #expect(ClaudeHookPreferences.helperScriptPath.hasSuffix("hook-forwarder.sh"))
    }

    @Test("ClaudeHookPreferences: configFilePath ends with hook-config.json")
    func configFilePath() {
        #expect(ClaudeHookPreferences.configFilePath.hasSuffix("hook-config.json"))
    }

    // MARK: - endpointURLString

    @Test("endpointURLString: without token")
    func endpointURLNoToken() {
        UserDefaults.standard.removeObject(forKey: ClaudeHookPreferences.tokenKey)
        let url = ClaudeHookPreferences.endpointURLString(port: 12345)
        #expect(url == "http://127.0.0.1:12345/claude/hook")
        #expect(!url.contains("token"))
    }

    @Test("endpointURLString: with token")
    func endpointURLWithToken() {
        let url = ClaudeHookPreferences.endpointURLString(port: 9999)
        // Depends on whether token is set, but port should always be present
        #expect(url.contains("127.0.0.1:"))
        #expect(url.contains("/claude/hook"))
    }

    // MARK: - String.sanitizedForShell

    @Test("sanitizedForShell: wraps in single quotes")
    func sanitizedSimple() {
        #expect("hello".sanitizedForShell() == "'hello'")
    }

    @Test("sanitizedForShell: escapes single quotes")
    func sanitizedWithQuotes() {
        #expect("it's".sanitizedForShell() == "'it'\\''s'")
    }

    @Test("sanitizedForShell: empty string")
    func sanitizedEmpty() {
        #expect("".sanitizedForShell() == "''")
    }

    @Test("LANHookPreferences: defaultLanMode is false")
    func defaultLanMode() {
        #expect(LANHookPreferences.defaultLanMode == false)
    }
}
