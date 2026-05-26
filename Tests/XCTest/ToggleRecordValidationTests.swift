import Testing
import Foundation
@testable import VibeFocusKit

@Suite("ToggleRecord Validation")
struct ToggleRecordValidationTests {

    // mainScreenFrame in Cocoa coordinates (origin bottom-left)
    private let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func makeRecord(
        origFrame: CGRect,
        targetFrame: CGRect
    ) -> ToggleRecord {
        ToggleRecord(
            windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
            origFrame: origFrame,
            sourceSpace: 2, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 1,
            targetFrame: targetFrame,
            targetDisplay: 1,
            toggledAt: Date(),
            sessionID: nil
        )
    }

    // MARK: - isValid: Quartz → Cocoa coordinate conversion

    @Test("isValid: origFrame off-screen, targetFrame on-screen → valid")
    func validRecord() {
        // Quartz: origFrame on secondary display (x=-1920), targetFrame on main (x=0)
        let record = makeRecord(
            origFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: origFrame on-screen → invalid (window not toggled away)")
    func origOnScreen() {
        // Quartz: origFrame center (960, 540) → Cocoa (960, 1080-540=540) → on main screen
        let record = makeRecord(
            origFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: targetFrame off-screen → invalid (window not moved to main)")
    func targetOffScreen() {
        // Quartz: targetFrame center (-960, 540) → Cocoa (-960, 540) → not on main
        let record = makeRecord(
            origFrame: CGRect(x: -3840, y: 0, width: 1920, height: 1080),
            targetFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: both origFrame and targetFrame on-screen → invalid")
    func bothOnScreen() {
        let record = makeRecord(
            origFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            targetFrame: CGRect(x: 500, y: 200, width: 800, height: 600)
        )
        #expect(!record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: origFrame partially off-screen left, center outside → valid")
    func origPartiallyOffScreen() {
        // origFrame center at (-960, 540) → Cocoa (-960, 540) → not contained
        let record = makeRecord(
            origFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: origFrame at exact screen boundary (edge case)")
    func origAtBoundary() {
        // Quartz: origFrame midX=-1, midY=540 → Cocoa (-1, 540) → not contained in [0,0,1920,1080]
        let record = makeRecord(
            origFrame: CGRect(x: -961, y: 0, width: 1920, height: 1080),
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    @Test("isValid: targetFrame at exact screen corner → valid")
    func targetAtCorner() {
        // Quartz: targetFrame midX=960, midY=540 → Cocoa (960, 540) → contained
        let record = makeRecord(
            origFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            targetFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        #expect(record.isValid(mainScreenFrame: mainScreen))
    }

    // MARK: - IndexPosition properties

    @Test("IndexPosition: all cases have Chinese display names")
    func indexPositionDisplayNames() {
        for position in IndexPosition.allCases {
            #expect(!position.displayName.isEmpty)
        }
    }

    @Test("IndexPosition: all cases have SF Symbol icon names")
    func indexPositionIcons() {
        for position in IndexPosition.allCases {
            #expect(!position.icon.isEmpty)
        }
    }

    @Test("IndexPosition: raw values are camelCase")
    func indexPositionRawValues() {
        let expected: Set<String> = [
            "topLeft", "topCenter", "topRight",
            "bottomLeft", "bottomCenter", "bottomRight"
        ]
        let actual = Set(IndexPosition.allCases.map(\.rawValue))
        #expect(actual == expected)
    }

    @Test("IndexPosition: Codable roundtrip")
    func indexPositionCodable() throws {
        for position in IndexPosition.allCases {
            let data = try JSONEncoder().encode(position)
            let decoded = try JSONDecoder().decode(IndexPosition.self, from: data)
            #expect(decoded == position)
        }
    }
}
