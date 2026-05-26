import Testing
import Foundation
@testable import VibeFocusKit

@Suite("CodableColor and YabaiDisplayInfo")
struct CodableColorAndYabaiDisplayTests {

    // MARK: - CodableColor Codable roundtrip

    private func decodeColor(_ json: String) throws -> CodableColor {
        try JSONDecoder().decode(CodableColor.self, from: Data(json.utf8))
    }

    @Test("CodableColor: Codable roundtrip preserves all channels")
    func codableRoundtrip() throws {
        let json = """
        {"red": 0.5, "green": 0.25, "blue": 0.75, "opacity": 0.9}
        """
        let color = try decodeColor(json)
        let data = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(CodableColor.self, from: data)
        #expect(decoded.red == 0.5)
        #expect(decoded.green == 0.25)
        #expect(decoded.blue == 0.75)
        #expect(decoded.opacity == 0.9)
    }

    @Test("CodableColor: JSON keys are named correctly")
    func jsonKeys() throws {
        let json = """
        {"red": 1, "green": 0, "blue": 0, "opacity": 1}
        """
        let color = try decodeColor(json)
        let data = try JSONEncoder().encode(color)
        let jsonObj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(jsonObj?["red"] != nil)
        #expect(jsonObj?["green"] != nil)
        #expect(jsonObj?["blue"] != nil)
        #expect(jsonObj?["opacity"] != nil)
    }

    @Test("CodableColor: zero values")
    func zeroValues() throws {
        let json = """
        {"red": 0, "green": 0, "blue": 0, "opacity": 0}
        """
        let color = try decodeColor(json)
        #expect(color.red == 0)
        #expect(color.opacity == 0)
    }

    @Test("CodableColor: full white")
    func fullWhite() throws {
        let json = """
        {"red": 1, "green": 1, "blue": 1, "opacity": 1}
        """
        let color = try decodeColor(json)
        #expect(color.red == 1)
        #expect(color.green == 1)
        #expect(color.blue == 1)
        #expect(color.opacity == 1)
    }

    @Test("CodableColor: mutation preserves values through encode/decode")
    func mutationRoundtrip() throws {
        var color = try decodeColor("{\"red\": 0, \"green\": 0, \"blue\": 0, \"opacity\": 1}")
        color.red = 0.5
        color.blue = 0.8
        let data = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(CodableColor.self, from: data)
        #expect(decoded.red == 0.5)
        #expect(decoded.blue == 0.8)
    }

    // MARK: - YabaiDisplayInfo decoding

    @Test("YabaiDisplayInfo: decodes with all fields")
    func displayInfoFull() throws {
        let json = """
        {"index": 1, "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080}}
        """
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == 1)
        let frame = try #require(display.frame)
        #expect(frame.x == 0)
        #expect(frame.w == 1920)
    }

    @Test("YabaiDisplayInfo: handles missing optional fields")
    func displayInfoMissingOptionals() throws {
        let json = "{}"
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == nil)
        #expect(display.frame == nil)
    }

    @Test("YabaiDisplayInfo: decodes secondary display with offset")
    func displayInfoSecondary() throws {
        let json = """
        {"index": 2, "frame": {"x": -1920, "y": 0, "w": 1920, "h": 1080}}
        """
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == 2)
        let frame = try #require(display.frame)
        #expect(frame.x == -1920)
    }

    @Test("YabaiDisplayInfo: decodes array")
    func displayInfoArray() throws {
        let json = """
        [{"index": 1, "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080}},
         {"index": 2, "frame": {"x": 1920, "y": 0, "w": 1920, "h": 1080}}]
        """
        let displays = try JSONDecoder().decode([YabaiDisplayInfo].self, from: Data(json.utf8))
        #expect(displays.count == 2)
        #expect(displays[1].frame?.x == 1920)
    }

    // MARK: - ClaudeHookEventType Codable

    @Test("ClaudeHookEventType: Codable roundtrip for all cases")
    func eventTypeCodable() throws {
        for eventType in ClaudeHookEventType.allCases {
            let data = try JSONEncoder().encode(eventType)
            let decoded = try JSONDecoder().decode(ClaudeHookEventType.self, from: data)
            #expect(decoded == eventType)
        }
    }

    @Test("ClaudeHookEventType: raw values match expected strings")
    func eventTypeRawValues() {
        #expect(ClaudeHookEventType.sessionStart.rawValue == "SessionStart")
        #expect(ClaudeHookEventType.stop.rawValue == "Stop")
        #expect(ClaudeHookEventType.sessionEnd.rawValue == "SessionEnd")
        #expect(ClaudeHookEventType.userPromptSubmit.rawValue == "UserPromptSubmit")
    }
}
