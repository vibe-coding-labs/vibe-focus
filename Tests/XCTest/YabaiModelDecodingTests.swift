import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Yabai Model Decoding")
struct YabaiModelDecodingTests {

    // MARK: - YabaiSpaceInfo

    @Test("YabaiSpaceInfo: decodes from JSON with all fields")
    func spaceInfoFull() throws {
        let json = """
        {"id": 123, "index": 1, "display": 2, "is-visible": true}
        """
        let space = try JSONDecoder().decode(YabaiSpaceInfo.self, from: Data(json.utf8))
        #expect(space.id == 123)
        #expect(space.index == 1)
        #expect(space.display == 2)
        #expect(space.isVisible == true)
    }

    @Test("YabaiSpaceInfo: is-visible maps from snake_case")
    func spaceInfoCodingKey() throws {
        let json = """
        {"is-visible": false}
        """
        let space = try JSONDecoder().decode(YabaiSpaceInfo.self, from: Data(json.utf8))
        #expect(space.isVisible == false)
    }

    @Test("YabaiSpaceInfo: handles missing optional fields")
    func spaceInfoMissingOptionals() throws {
        let json = "{}"
        let space = try JSONDecoder().decode(YabaiSpaceInfo.self, from: Data(json.utf8))
        #expect(space.id == nil)
        #expect(space.index == nil)
        #expect(space.display == nil)
        #expect(space.isVisible == nil)
    }

    @Test("YabaiSpaceInfo: decodes array of spaces")
    func spaceInfoArray() throws {
        let json = """
        [{"id": 1, "index": 1, "display": 1, "is-visible": true},
         {"id": 2, "index": 2, "display": 1, "is-visible": false},
         {"id": 3, "index": 3, "display": 2, "is-visible": true}]
        """
        let spaces = try JSONDecoder().decode([YabaiSpaceInfo].self, from: Data(json.utf8))
        #expect(spaces.count == 3)
        #expect(spaces[1].isVisible == false)
        #expect(spaces[2].display == 2)
    }

    // MARK: - YabaiWindowInfo

    @Test("YabaiWindowInfo: decodes from JSON with all fields")
    func windowInfoFull() throws {
        let json = """
        {"id": 42, "pid": 1234, "app": "Terminal", "title": "bash",
         "space": 2, "display": 1, "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080},
         "is-floating": true}
        """
        let window = try JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        #expect(window.id == 42)
        #expect(window.pid == 1234)
        #expect(window.app == "Terminal")
        #expect(window.title == "bash")
        #expect(window.space == 2)
        #expect(window.display == 1)
        #expect(window.isFloating == true)

        let frame = try #require(window.frame)
        #expect(frame.x == 0)
        #expect(frame.w == 1920)
    }

    @Test("YabaiWindowInfo: is-floating maps correctly")
    func windowInfoFloatingKey() throws {
        let json = """
        {"is-floating": false}
        """
        let window = try JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        #expect(window.isFloating == false)
    }

    @Test("YabaiWindowInfo: is-floating nil means not floating")
    func windowInfoFloatingNil() throws {
        let json = "{}"
        let window = try JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        #expect(window.isFloating == false)
    }

    @Test("YabaiWindowInfo: frame.cgRect converts correctly")
    func windowInfoFrameConversion() throws {
        let json = """
        {"frame": {"x": 100.5, "y": 200.5, "w": 800.0, "h": 600.0}}
        """
        let window = try JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        let frame = try #require(window.frame)
        let rect = frame.cgRect
        #expect(rect.origin.x == 100.5)
        #expect(rect.origin.y == 200.5)
        #expect(rect.width == 800.0)
        #expect(rect.height == 600.0)
    }

    @Test("YabaiWindowInfo: nil frame when not in JSON")
    func windowInfoNoFrame() throws {
        let json = "{}"
        let window = try JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
        #expect(window.frame == nil)
    }

    // MARK: - visibleSpaceIndex filtering logic (mirrors SpaceController.visibleSpaceIndex)

    @Test("visibleSpaceIndex filtering: finds visible space on display 1")
    func visibleSpaceFilterDisplay1() throws {
        let spaces = try makeTestSpaces()
        let display1Visible = spaces.filter { $0.display == 1 && $0.isVisible == true }
        #expect(display1Visible.count == 1)
        #expect(display1Visible.first?.index == 1)
    }

    @Test("visibleSpaceIndex filtering: finds visible space on display 2")
    func visibleSpaceFilterDisplay2() throws {
        let spaces = try makeTestSpaces()
        let display2Visible = spaces.filter { $0.display == 2 && $0.isVisible == true }
        #expect(display2Visible.count == 1)
        #expect(display2Visible.first?.index == 3)
    }

    @Test("visibleSpaceIndex filtering: no visible space on display returns empty")
    func visibleSpaceFilterNone() throws {
        let spaces = try makeTestSpaces()
        let display3Visible = spaces.filter { $0.display == 3 && $0.isVisible == true }
        #expect(display3Visible.isEmpty)
    }

    private func makeTestSpaces() throws -> [YabaiSpaceInfo] {
        let json = """
        [{"id": 1, "index": 1, "display": 1, "is-visible": true},
         {"id": 2, "index": 2, "display": 1, "is-visible": false},
         {"id": 3, "index": 3, "display": 2, "is-visible": true},
         {"id": 4, "index": 4, "display": 2, "is-visible": false},
         {"id": 5, "index": 5, "display": 3, "is-visible": false}]
        """
        return try JSONDecoder().decode([YabaiSpaceInfo].self, from: Data(json.utf8))
    }

    // MARK: - YabaiDisplayInfo

    @Test("YabaiDisplayInfo: decodes from JSON with index and frame")
    func displayInfoFull() throws {
        let json = """
        {"index": 1, "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080}}
        """
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == 1)
        #expect(display.frame != nil)
        #expect(display.frame?.x == 0)
        #expect(display.frame?.y == 0)
        #expect(display.frame?.w == 1920)
        #expect(display.frame?.h == 1080)
    }

    @Test("YabaiDisplayInfo: decodes from JSON with negative coordinates (secondary display)")
    func displayInfoSecondaryScreen() throws {
        let json = """
        {"index": 2, "frame": {"x": -1920, "y": 0, "w": 1920, "h": 1080}}
        """
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == 2)
        #expect(display.frame?.x == -1920)
    }

    @Test("YabaiDisplayInfo: handles nil optional fields")
    func displayInfoMissingOptionals() throws {
        let json = "{}"
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.index == nil)
        #expect(display.frame == nil)
    }

    @Test("YabaiDisplayInfo: decodes array of displays")
    func displayInfoArray() throws {
        let json = """
        [{"index": 1, "frame": {"x": 0, "y": 0, "w": 1920, "h": 1080}},
         {"index": 2, "frame": {"x": 1920, "y": 0, "w": 2560, "h": 1440}}]
        """
        let displays = try JSONDecoder().decode([YabaiDisplayInfo].self, from: Data(json.utf8))
        #expect(displays.count == 2)
        #expect(displays[0].frame?.w == 1920)
        #expect(displays[1].frame?.w == 2560)
    }

    @Test("YabaiDisplayInfo.Frame: fractional coordinates preserved")
    func displayInfoFractionalCoords() throws {
        let json = """
        {"frame": {"x": 100.5, "y": 200.25, "w": 800.125, "h": 600.0625}}
        """
        let display = try JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(json.utf8))
        #expect(display.frame?.x == 100.5)
        #expect(display.frame?.y == 200.25)
        #expect(display.frame?.w == 800.125)
        #expect(display.frame?.h == 600.0625)
    }
}
