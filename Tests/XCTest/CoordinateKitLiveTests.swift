import Testing
import AppKit
import Foundation
import CoreGraphics
@testable import VibeFocusKit

@Suite("CoordinateKit Live Screen Methods")
@MainActor
struct CoordinateKitLiveTests {

    @Test("isOnMainScreen(point) returns true for origin point")
    func pointOnMainOrigin() {
        // (0,0) in Quartz is the top-left of the main screen
        let result = CoordinateKit.isOnMainScreen(CGPoint(x: 0, y: 0))
        #expect(result == true)
    }

    @Test("isOnMainScreen(point) returns true for center of main screen")
    func pointOnMainCenter() {
        guard let mainFrame = CoordinateKit.mainScreenQuartzFrame else {
            // No screen info available in test env
            return
        }
        let center = CGPoint(x: mainFrame.midX, y: mainFrame.midY)
        #expect(CoordinateKit.isOnMainScreen(center))
    }

    @Test("isOnMainScreen(rect) returns true for rect centered on main screen")
    func rectOnMain() {
        let rect = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(CoordinateKit.isOnMainScreen(rect))
    }

    @Test("isOnMainScreen(rect) uses center point for detection")
    func rectCenterDetection() {
        // Rect that starts at origin but extends far — center is still on main
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(CoordinateKit.isOnMainScreen(rect))
    }

    @Test("mainScreenQuartzFrame returns a valid frame or nil")
    func mainScreenFrameNotNil() {
        // This test verifies the method runs without crashing
        let frame = CoordinateKit.mainScreenQuartzFrame
        if let frame {
            #expect(frame.width > 0)
            #expect(frame.height > 0)
        }
        // nil is also acceptable in headless test env
    }

    @Test("mainScreenHeight is non-negative")
    func mainScreenHeightNonNegative() {
        let height = CoordinateKit.mainScreenHeight
        #expect(height >= 0)
    }

    @Test("cocoaY(fromQuartzY:) and quartzY(fromCocoaY:) are inverse")
    func coordinateRoundtrip() {
        let quartzY: CGFloat = 500
        let cocoaY = CoordinateKit.cocoaY(fromQuartzY: quartzY)
        let backToQuartz = CoordinateKit.quartzY(fromCocoaY: cocoaY)
        #expect(backToQuartz == quartzY)
    }

    @Test("screenForRect returns a screen for origin rect")
    func screenForOriginRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let screen = CoordinateKit.screenForRect(rect)
        // In test env with screens, should find the main screen
        if NSScreen.screens.count > 0 {
            #expect(screen != nil)
        }
    }
}
