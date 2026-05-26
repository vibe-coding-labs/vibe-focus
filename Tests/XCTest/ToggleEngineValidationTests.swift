import Testing
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("ToggleEngine Save Validation")
@MainActor
struct ToggleEngineValidationTests {

    private let mainScreen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("shouldRejectSave: origFrame center on main screen → reject")
    func rejectOrigOnMain() {
        let origFrame = CGRect(x: 500, y: 300, width: 800, height: 600)
        #expect(ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen))
    }

    @Test("shouldRejectSave: origFrame center off screen → allow")
    func allowOrigOffScreen() {
        let origFrame = CGRect(x: 100, y: -1000, width: 800, height: 600)
        #expect(!ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen))
    }

    @Test("shouldRejectSave: origFrame center on secondary screen → allow")
    func allowOrigOnSecondary() {
        let origFrame = CGRect(x: 2000, y: 100, width: 800, height: 600)
        #expect(!ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen))
    }

    @Test("shouldRejectSave: nil mainScreen → allow (cannot validate)")
    func allowNilMainScreen() {
        let origFrame = CGRect(x: 500, y: 300, width: 800, height: 600)
        #expect(!ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: nil))
    }

    @Test("shouldRejectSave: origFrame exactly at origin → reject")
    func rejectAtOrigin() {
        let origFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen))
    }

    @Test("shouldRejectSave: origFrame edge case — center exactly at maxX boundary")
    func edgeCaseCenterAtMaxX() {
        // center at (1920, 540) — CGRect.contains excludes max edge
        let origFrame = CGRect(x: 1520, y: 0, width: 800, height: 1080)
        #expect(!ToggleEngine.shouldRejectSave(origFrame: origFrame, mainScreenFrame: mainScreen))
    }
}
