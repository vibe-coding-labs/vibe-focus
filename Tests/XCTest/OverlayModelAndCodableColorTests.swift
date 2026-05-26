import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Overlay Window Label and Size Calculations")
@MainActor
struct OverlayCalculationEdgeCaseTests {

    // MARK: - calculateOverlayLabel

    @Test("calculateOverlayLabel: screen index is 1-based (adds 1)")
    func oneBasedScreenIndex() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 0, spaceIndex: 3) == "1-3")
    }

    @Test("calculateOverlayLabel: single digit space index")
    func singleDigitSpace() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 1, spaceIndex: 5) == "2-5")
    }

    @Test("calculateOverlayLabel: double digit indices")
    func doubleDigitIndices() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 10, spaceIndex: 99) == "11-99")
    }

    @Test("calculateOverlayLabel: zero space index")
    func zeroSpaceIndex() {
        #expect(OverlayWindow.calculateOverlayLabel(screenIndex: 0, spaceIndex: 0) == "1-0")
    }

    // MARK: - calculateOverlaySize

    @Test("calculateOverlaySize: respects minimum width")
    func minimumWidth() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 10, textHeight: 10, scaledFontSize: 20
        )
        let expectedMinWidth = 20 * 3.5
        #expect(size.width >= expectedMinWidth)
    }

    @Test("calculateOverlaySize: respects minimum height")
    func minimumHeight() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 10, textHeight: 10, scaledFontSize: 20
        )
        let expectedMinHeight = 20 * 2.0
        #expect(size.height >= expectedMinHeight)
    }

    @Test("calculateOverlaySize: uses text dimensions when larger than minimum")
    func textDimensionsExceedMin() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 500, textHeight: 200, scaledFontSize: 20
        )
        let padding = 20 * 0.8
        #expect(size.width >= 500 + padding * 2)
        let vPadding = 20 * 0.5
        #expect(size.height >= 200 + vPadding * 2)
    }

    @Test("calculateOverlaySize: scales with font size")
    func scalesWithFontSize() {
        let small = OverlayWindow.calculateOverlaySize(textWidth: 50, textHeight: 20, scaledFontSize: 12)
        let large = OverlayWindow.calculateOverlaySize(textWidth: 50, textHeight: 20, scaledFontSize: 48)
        #expect(large.width > small.width)
        #expect(large.height > small.height)
    }

    // MARK: - calculateOverlayOrigin

    @Test("calculateOverlayOrigin: topRight position")
    func topRightOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topRight,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: 10
        )
        #expect(origin.x == screenFrame.maxX - windowSize.width - 10)
        #expect(origin.y == screenFrame.maxY - windowSize.height - 10)
    }

    @Test("calculateOverlayOrigin: bottomLeft position")
    func bottomLeftOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .bottomLeft,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: 10
        )
        #expect(origin.x == screenFrame.minX + 10)
        #expect(origin.y == screenFrame.minY + 10)
    }

    @Test("calculateOverlayOrigin: topCenter position")
    func topCenterOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topCenter,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: 10
        )
        #expect(origin.x == screenFrame.midX - windowSize.width / 2)
        #expect(origin.y == screenFrame.maxY - windowSize.height - 10)
    }

    @Test("calculateOverlayOrigin: bottomRight position")
    func bottomRightOrigin() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .bottomRight,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: 10
        )
        #expect(origin.x == screenFrame.maxX - windowSize.width - 10)
        #expect(origin.y == screenFrame.minY + 10)
    }

    @Test("calculateOverlayOrigin: negative margin clamped to 0")
    func negativeMarginClamped() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topLeft,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: -10
        )
        #expect(origin.x == screenFrame.minX)
        #expect(origin.y == screenFrame.maxY - windowSize.height)
    }

    @Test("calculateOverlayOrigin: secondary display with negative coordinates")
    func secondaryDisplay() {
        let screenFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let windowSize = CGSize(width: 100, height: 50)
        let origin = OverlayWindow.calculateOverlayOrigin(
            position: .topRight,
            screenFrame: screenFrame,
            windowSize: windowSize,
            margin: 10
        )
        #expect(origin.x == screenFrame.maxX - windowSize.width - 10)
        #expect(origin.x < 0)
    }
}
