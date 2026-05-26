import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Port Normalization")
struct PortNormalizationTests {

    @Test("normalizePort: value in valid range unchanged")
    func validPort() {
        #expect(ClaudeHookPreferences.normalizePort(8080) == 8080)
    }

    @Test("normalizePort: default port unchanged")
    func defaultPort() {
        #expect(ClaudeHookPreferences.normalizePort(39277) == 39277)
    }

    @Test("normalizePort: minimum valid port 1024")
    func minPort() {
        #expect(ClaudeHookPreferences.normalizePort(1024) == 1024)
    }

    @Test("normalizePort: maximum valid port 65535")
    func maxPort() {
        #expect(ClaudeHookPreferences.normalizePort(65535) == 65535)
    }

    @Test("normalizePort: below minimum clamped to 1024")
    func belowMin() {
        #expect(ClaudeHookPreferences.normalizePort(80) == 1024)
    }

    @Test("normalizePort: zero clamped to 1024")
    func zero() {
        #expect(ClaudeHookPreferences.normalizePort(0) == 1024)
    }

    @Test("normalizePort: negative clamped to 1024")
    func negative() {
        #expect(ClaudeHookPreferences.normalizePort(-1) == 1024)
    }

    @Test("normalizePort: above maximum clamped to 65535")
    func aboveMax() {
        #expect(ClaudeHookPreferences.normalizePort(70000) == 65535)
    }

    @Test("normalizePort: boundary 1023 clamped to 1024")
    func justBelowMin() {
        #expect(ClaudeHookPreferences.normalizePort(1023) == 1024)
    }

    @Test("normalizePort: boundary 65536 clamped to 65535")
    func justAboveMax() {
        #expect(ClaudeHookPreferences.normalizePort(65536) == 65535)
    }
}
