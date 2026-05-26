import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("ScriptWindowSnapshot")
struct ScriptWindowSnapshotTests {

    private func decode(_ json: String) throws -> WindowManager.ScriptWindowSnapshot {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "test", code: 1)
        }
        return try JSONDecoder().decode(WindowManager.ScriptWindowSnapshot.self, from: data)
    }

    @Test("full JSON roundtrip preserves all fields")
    func fullRoundtrip() throws {
        let snapshot = WindowManager.ScriptWindowSnapshot(
            windowID: 42, appName: "Terminal",
            title: "bash", x: 100, y: 200, width: 800, height: 600
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WindowManager.ScriptWindowSnapshot.self, from: data)
        #expect(decoded.windowID == 42)
        #expect(decoded.appName == "Terminal")
        #expect(decoded.title == "bash")
        #expect(decoded.x == 100)
        #expect(decoded.y == 200)
        #expect(decoded.width == 800)
        #expect(decoded.height == 600)
    }

    @Test("nil windowID decodes from JSON null")
    func nilWindowID() throws {
        let json = """
        {"windowID":null,"appName":"Safari","title":"Page","x":0,"y":0,"width":1920,"height":1080}
        """
        let snapshot = try decode(json)
        #expect(snapshot.windowID == nil)
    }

    @Test("frame computed property matches x/y/width/height")
    func frameProperty() {
        let snapshot = WindowManager.ScriptWindowSnapshot(
            windowID: nil, appName: "App", title: nil,
            x: 50, y: -500, width: 1200, height: 800
        )
        let frame = snapshot.frame
        #expect(frame.origin.x == 50)
        #expect(frame.origin.y == -500)
        #expect(frame.width == 1200)
        #expect(frame.height == 800)
    }

    @Test("negative coordinates for secondary screen")
    func negativeCoordinates() throws {
        let json = """
        {"windowID":99,"appName":"Terminal","title":"vim","x":1920,"y":-1080,"width":800,"height":600}
        """
        let snapshot = try decode(json)
        #expect(snapshot.x == 1920)
        #expect(snapshot.y == -1080)
        let frame = snapshot.frame
        #expect(frame.origin.y < 0)
    }

    @Test("missing title defaults to nil")
    func missingTitle() throws {
        let json = """
        {"windowID":1,"appName":"App","x":0,"y":0,"width":100,"height":100}
        """
        let snapshot = try decode(json)
        #expect(snapshot.title == nil)
    }
}
