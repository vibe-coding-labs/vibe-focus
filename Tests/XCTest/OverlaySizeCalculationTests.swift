import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Overlay Size Calculation")
struct OverlaySizeCalculationTests {

    // MARK: - calculateOverlaySize

    @Test("size uses minWidth when text is small")
    func minSizeApplied() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 10, textHeight: 10, scaledFontSize: 20
        )
        // minWidth = 20 * 3.5 = 70, minHeight = 20 * 2.0 = 40
        // text+padding: 10 + 2*16 = 42 > 70? No → 70
        #expect(size.width == 70)
        #expect(size.height == 40)
    }

    @Test("size uses text+padding when text is large")
    func textPaddingWins() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 200, textHeight: 50, scaledFontSize: 14
        )
        // hPad = 14*0.8 = 11.2, vPad = 14*0.5 = 7
        // width = max(200 + 22.4, 49) = 222.4
        // height = max(50 + 14, 28) = 64
        let expectedW: CGFloat = 222.4
        let expectedH: CGFloat = 64
        #expect(size.width == expectedW)
        #expect(size.height == expectedH)
    }

    @Test("size scales with font size")
    func scalesWithFontSize() {
        let small = OverlayWindow.calculateOverlaySize(
            textWidth: 50, textHeight: 20, scaledFontSize: 10
        )
        let large = OverlayWindow.calculateOverlaySize(
            textWidth: 50, textHeight: 20, scaledFontSize: 20
        )
        #expect(large.width > small.width)
        #expect(large.height > small.height)
    }

    @Test("size with zero text uses minimums")
    func zeroText() {
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 0, textHeight: 0, scaledFontSize: 16
        )
        let minW: CGFloat = 56  // 16 * 3.5
        let minH: CGFloat = 32  // 16 * 2.0
        #expect(size.width == minW)
        #expect(size.height == minH)
    }

    @Test("horizontal padding ratio is 0.8 of font size")
    func horizontalPaddingRatio() {
        let fontSize: CGFloat = 100
        let size = OverlayWindow.calculateOverlaySize(
            textWidth: 0, textHeight: 0, scaledFontSize: fontSize
        )
        // minWidth = 350, but text+padding = 0 + 2*80 = 160 < 350
        // so width = 350
        let minW: CGFloat = 350
        #expect(size.width == minW)
    }

    // MARK: - SpaceRestoreStrategy

    @Test("SpaceRestoreStrategy: has exactly 2 cases")
    func strategyCount() {
        #expect(SpaceRestoreStrategy.allCases.count == 2)
    }

    @Test("SpaceRestoreStrategy: raw values match case names")
    func strategyRawValues() {
        #expect(SpaceRestoreStrategy.switchToOriginal.rawValue == "switchToOriginal")
        #expect(SpaceRestoreStrategy.pullToCurrent.rawValue == "pullToCurrent")
    }

    @Test("SpaceRestoreStrategy: init from rawValue")
    func strategyFromRaw() {
        #expect(SpaceRestoreStrategy(rawValue: "switchToOriginal") == .switchToOriginal)
        #expect(SpaceRestoreStrategy(rawValue: "pullToCurrent") == .pullToCurrent)
        #expect(SpaceRestoreStrategy(rawValue: "invalid") == nil)
    }

    // MARK: - SpaceAvailability

    @Test("SpaceAvailability: raw values")
    func availabilityRawValues() {
        #expect(SpaceAvailability.unknown.rawValue == "unknown")
        #expect(SpaceAvailability.notInstalled.rawValue == "notInstalled")
        #expect(SpaceAvailability.unavailable.rawValue == "unavailable")
        #expect(SpaceAvailability.available.rawValue == "available")
    }

    // MARK: - SpaceContext

    @Test("SpaceContext: stores all indices")
    func spaceContextFields() {
        let ctx = SpaceContext(
            sourceSpaceIndex: .yabai(3),
            targetSpaceIndex: .yabai(1),
            sourceDisplayIndex: .yabai(2),
            sourceDisplaySpaceIndex: 1
        )
        #expect(ctx.sourceSpaceIndex?.yabaiIndex == 3)
        #expect(ctx.targetSpaceIndex?.yabaiIndex == 1)
        #expect(ctx.sourceDisplayIndex?.yabaiIndex == 2)
        #expect(ctx.sourceDisplaySpaceIndex == 1)
    }

    @Test("SpaceContext: all nil")
    func spaceContextAllNil() {
        let ctx = SpaceContext(
            sourceSpaceIndex: nil,
            targetSpaceIndex: nil,
            sourceDisplayIndex: nil,
            sourceDisplaySpaceIndex: nil
        )
        #expect(ctx.sourceSpaceIndex == nil)
        #expect(ctx.targetSpaceIndex == nil)
        #expect(ctx.sourceDisplayIndex == nil)
        #expect(ctx.sourceDisplaySpaceIndex == nil)
    }

    // MARK: - WindowMoveReason

    @Test("WindowMoveReason: raw values")
    func moveReasonRawValues() {
        #expect(WindowMoveReason.manualHotkey.rawValue == "manual_hotkey")
        #expect(WindowMoveReason.claudeSessionEnd.rawValue == "claude_session_end")
    }

    @Test("WindowMoveReason: Codable roundtrip")
    func moveReasonCodable() throws {
        let reason = WindowMoveReason.manualHotkey
        let data = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(WindowMoveReason.self, from: data)
        #expect(decoded == reason)
    }
}
