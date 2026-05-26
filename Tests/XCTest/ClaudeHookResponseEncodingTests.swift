import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ClaudeHookResponse Encoding Details")
struct ClaudeHookResponseEncodingTests {

    private func encode(_ response: ClaudeHookResponse) throws -> [String: Any] {
        let data = try JSONEncoder().encode(response)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("ClaudeHookResponse encodes session_id with snake_case key")
    func sessionIDSncakeCase() throws {
        let response = ClaudeHookResponse(
            ok: true, code: "test", message: "msg",
            sessionID: "sess-42", handled: true
        )
        let json = try encode(response)
        #expect(json["session_id"] as? String == "sess-42")
        #expect(json["sessionID"] == nil)
    }

    @Test("ClaudeHookResponse with nil sessionID omits key")
    func nilSessionID() throws {
        let response = ClaudeHookResponse(
            ok: false, code: "error", message: "fail",
            sessionID: nil, handled: false
        )
        let data = try JSONEncoder().encode(response)
        let jsonString = String(data: data, encoding: .utf8)!
        // JSONEncoder omits nil optional String keys
        #expect(!jsonString.contains("session_id"))
    }

    @Test("ClaudeHookResponse preserves all boolean states")
    func booleanStates() throws {
        let r1 = ClaudeHookResponse(ok: true, code: "c", message: "m", sessionID: nil, handled: true)
        let json1 = try encode(r1)
        #expect(json1["ok"] as? Bool == true)
        #expect(json1["handled"] as? Bool == true)

        let r2 = ClaudeHookResponse(ok: false, code: "c", message: "m", sessionID: nil, handled: false)
        let json2 = try encode(r2)
        #expect(json2["ok"] as? Bool == false)
        #expect(json2["handled"] as? Bool == false)
    }

    @Test("ClaudeHookResponse preserves unicode in message")
    func unicodeMessage() throws {
        let response = ClaudeHookResponse(
            ok: true, code: "ok", message: "窗口已移动到主屏幕",
            sessionID: nil, handled: true
        )
        let json = try encode(response)
        #expect(json["message"] as? String == "窗口已移动到主屏幕")
    }

    @Test("ClaudeHookResponse with empty code and message")
    func emptyStrings() throws {
        let response = ClaudeHookResponse(
            ok: true, code: "", message: "",
            sessionID: "", handled: false
        )
        let json = try encode(response)
        #expect(json["code"] as? String == "")
        #expect(json["message"] as? String == "")
    }

    // MARK: - WindowIdentity encoding key names

    @Test("WindowIdentity encodes windowID as number")
    func windowIDNumber() throws {
        let identity = WindowIdentity(
            windowID: UInt32.max, pid: Int32.min,
            bundleIdentifier: nil, appName: nil, title: nil
        )
        let data = try JSONEncoder().encode(identity)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["windowID"] as? Int == Int(UInt32.max))
    }

    @Test("WindowIdentity encodes nil optionals as omitted keys")
    func nilOptionals() throws {
        let identity = WindowIdentity(
            windowID: 1, pid: 2,
            bundleIdentifier: nil, appName: nil, title: nil
        )
        let data = try JSONEncoder().encode(identity)
        let jsonString = String(data: data, encoding: .utf8)!
        // JSONEncoder omits nil optional keys entirely
        #expect(!jsonString.contains("bundleIdentifier"))
        #expect(!jsonString.contains("appName"))
        #expect(!jsonString.contains("title"))
    }

    @Test("WindowIdentity capturedAt is encoded as date")
    func capturedAtDate() throws {
        let identity = WindowIdentity(
            windowID: 1, pid: 2,
            bundleIdentifier: nil, appName: nil, title: nil
        )
        let data = try JSONEncoder().encode(identity)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["capturedAt"] != nil)
    }
}
