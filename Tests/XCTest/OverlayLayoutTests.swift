import Testing
import Foundation
@testable import VibeFocusKit

@Suite("OverlayWindow Layout Logic")
struct OverlayLayoutTests {

    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let windowSize = CGSize(width: 100, height: 60)
    let margin: CGFloat = 20

    // MARK: - calculateOverlayOrigin: all six positions

    @Test("topLeft: margin from top-left corner")
    func topLeft() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topLeft, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = 20
        let expectedY: CGFloat = 1000
        #expect(origin.x == expectedX)
        #expect(origin.y == expectedY)
    }

    @Test("topRight: margin from top-right corner")
    func topRight() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topRight, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = 1800
        #expect(origin.x == expectedX)
        #expect(origin.y == 1000)
    }

    @Test("topCenter: horizontally centered at top")
    func topCenter() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topCenter, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = 910
        #expect(origin.x == expectedX)
        #expect(origin.y == 1000)
    }

    @Test("bottomLeft: margin from bottom-left corner")
    func bottomLeft() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .bottomLeft, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        #expect(origin.x == 20)
        #expect(origin.y == 20)
    }

    @Test("bottomRight: margin from bottom-right corner")
    func bottomRight() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .bottomRight, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = 1800
        #expect(origin.x == expectedX)
        #expect(origin.y == 20)
    }

    @Test("bottomCenter: horizontally centered at bottom")
    func bottomCenter() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .bottomCenter, screenFrame: screen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = 910
        #expect(origin.x == expectedX)
        #expect(origin.y == 20)
    }

    // MARK: - Negative margin clamped to 0

    @Test("negative margin is clamped to 0")
    func negativeMarginClamped() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topRight, screenFrame: screen, windowSize: windowSize, margin: -50
        )
        let expectedX: CGFloat = 1820
        let expectedY: CGFloat = 1020
        #expect(origin.x == expectedX)
        #expect(origin.y == expectedY)
    }

    @Test("zero margin places at screen edge")
    func zeroMargin() {
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topLeft, screenFrame: screen, windowSize: windowSize, margin: 0
        )
        let expectedY: CGFloat = 1020
        #expect(origin.x == 0)
        #expect(origin.y == expectedY)
    }

    // MARK: - Secondary screen with offset origin

    @Test("secondary screen with negative x origin")
    func secondaryScreen() {
        let secondaryScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topRight, screenFrame: secondaryScreen, windowSize: windowSize, margin: margin
        )
        let expectedX: CGFloat = -120
        #expect(origin.x == expectedX)
        #expect(origin.y == 1000)
    }

    // MARK: - calculateOverlayLabel

    @Test("calculateOverlayLabel: screen index is 1-based for display")
    func labelFormat() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 0, spaceIndex: 3) == "1-3")
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 1, spaceIndex: 1) == "2-1")
    }

    @Test("calculateOverlayLabel: zero indices produce 1-1")
    func labelZeroIndices() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 0, spaceIndex: 0) == "1-0")
    }
}
