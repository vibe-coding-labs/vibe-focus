import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Support Utility Functions")
struct SupportUtilityTests {

    @Test("truncateForLog: short string unchanged")
    func truncateShort() {
        let short = "hello"
        #expect(truncateForLog(short, limit: 10) == short)
    }

    @Test("truncateForLog: long string truncated with ellipsis")
    func truncateLong() {
        let long = String(repeating: "a", count: 100)
        let result = truncateForLog(long, limit: 50)
        #expect(result.count <= 53) // 50 + "..."
        #expect(result.hasSuffix("..."))
    }

    @Test("truncateForLog: exact limit unchanged")
    func truncateExactLimit() {
        let text = String(repeating: "x", count: 10)
        #expect(truncateForLog(text, limit: 10) == text)
    }

    @Test("truncateForLog: empty string unchanged")
    func truncateEmpty() {
        #expect(truncateForLog("", limit: 10) == "")
    }

    @Test("makeOperationID: generates unique IDs with prefix")
    func makeOperationIDUnique() {
        let id1 = makeOperationID(prefix: "test")
        let id2 = makeOperationID(prefix: "test")
        #expect(id1.hasPrefix("test-"))
        #expect(id1 != id2)
    }

    @Test("makeOperationID: empty prefix normalizes to 'op'")
    func makeOperationIDEmptyPrefix() {
        let id = makeOperationID(prefix: "")
        #expect(id.hasPrefix("op-"))
    }

    @Test("makeOperationID: default prefix is 'op'")
    func makeOperationIDDefaultPrefix() {
        let id = makeOperationID()
        #expect(id.hasPrefix("op-"))
    }

    @Test("elapsedMilliseconds: returns non-negative value")
    func elapsedMillisecondsNonNegative() {
        let past = Date().addingTimeInterval(-1.0)
        let elapsed = elapsedMilliseconds(since: past)
        #expect(elapsed >= 0)
    }

    @Test("elapsedMilliseconds: future date returns 0")
    func elapsedMillisecondsFuture() {
        let future = Date().addingTimeInterval(10.0)
        let elapsed = elapsedMilliseconds(since: future)
        #expect(elapsed == 0)
    }

    // MARK: - sanitizeFieldValue

    @Test("sanitizeFieldValue: plain text unchanged")
    func sanitizePlain() {
        #expect(sanitizeFieldValue("hello") == "hello")
    }

    @Test("sanitizeFieldValue: escapes backslash")
    func sanitizeBackslash() {
        #expect(sanitizeFieldValue("a\\b") == "a\\\\b")
    }

    @Test("sanitizeFieldValue: escapes newline and tab")
    func sanitizeNewlineTab() {
        let result = sanitizeFieldValue("a\nb\tc")
        #expect(!result.contains("\n"))
        #expect(!result.contains("\t"))
        #expect(result.contains("\\n"))
        #expect(result.contains("\\t"))
    }

    @Test("sanitizeFieldValue: escapes double quotes")
    func sanitizeQuotes() {
        let result = sanitizeFieldValue("say \"hi\"")
        #expect(result.contains("\\\""))
    }

    @Test("sanitizeFieldValue: wraps in quotes when contains spaces")
    func sanitizeSpacesQuoted() {
        let result = sanitizeFieldValue("hello world")
        #expect(result.hasPrefix("\""))
        #expect(result.hasSuffix("\""))
    }

    @Test("sanitizeFieldValue: wraps in quotes when contains equals")
    func sanitizeEqualsQuoted() {
        let result = sanitizeFieldValue("key=value")
        #expect(result.hasPrefix("\""))
    }

    @Test("sanitizeFieldValue: empty string stays empty")
    func sanitizeEmpty() {
        #expect(sanitizeFieldValue("") == "")
    }

    // MARK: - serializeFields

    @Test("serializeFields: empty dict returns empty string")
    func serializeEmpty() {
        #expect(serializeFields([:]) == "")
    }

    @Test("serializeFields: single field")
    func serializeSingle() {
        let result = serializeFields(["key": "value"])
        #expect(result.hasPrefix(" "))
        #expect(result.contains("key=value"))
    }

    @Test("serializeFields: multiple fields sorted by key")
    func serializeSorted() {
        let result = serializeFields(["b": "2", "a": "1"])
        #expect(result.contains("a=1"))
        #expect(result.contains("b=2"))
        let aRange = result.range(of: "a=1")!
        let bRange = result.range(of: "b=2")!
        #expect(aRange.lowerBound < bRange.lowerBound)
    }

    @Test("serializeFields: filters out empty keys")
    func serializeEmptyKey() {
        let result = serializeFields(["": "value", "key": "val"])
        #expect(!result.contains("=value"))
        #expect(result.contains("key=val"))
    }

    // MARK: - LogLevel

    @Test("LogLevel: raw values match expected strings")
    func logLevelRawValues() {
        #expect(LogLevel.debug.rawValue == "DEBUG")
        #expect(LogLevel.info.rawValue == "INFO")
        #expect(LogLevel.warn.rawValue == "WARN")
        #expect(LogLevel.error.rawValue == "ERROR")
    }
}
