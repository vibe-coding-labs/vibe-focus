import Testing
import Foundation
import SwiftUI
@testable import VibeFocusKit

@Suite("Overlay Signature and Preferences")
@MainActor
struct OverlaySignatureTests {

    @Test("preferenceSignature encodes all fields")
    func signatureEncodesFields() {
        let prefs = ScreenIndexPreferences(
            isEnabled: true, position: .topLeft,
            fontSize: 32, opacity: 0.5,
            textColor: CodableColor(.white),
            backgroundColor: CodableColor(.black),
            panelScale: 1.5, panelMargin: 10,
            yabaiPath: nil, usePerScreenSpaceIndexing: true
        )
        let sig = ScreenOverlayManager.shared.preferenceSignature(prefs)
        #expect(sig.contains("enabled=true"))
        #expect(sig.contains("pos=topLeft"))
        #expect(sig.contains("font=32.0"))
        #expect(sig.contains("opacity=0.50"))
        #expect(sig.contains("scale=1.50"))
        #expect(sig.contains("margin=10.0"))
    }

    @Test("preferenceSignature changes when position differs")
    func signatureDiffersByPosition() {
        let p1 = ScreenIndexPreferences(
            isEnabled: true, position: .topLeft,
            fontSize: 48, opacity: 0.8,
            textColor: CodableColor(.white),
            backgroundColor: CodableColor(.black),
            panelScale: 1.0, panelMargin: 20,
            yabaiPath: nil, usePerScreenSpaceIndexing: true
        )
        let p2 = ScreenIndexPreferences(
            isEnabled: true, position: .bottomRight,
            fontSize: 48, opacity: 0.8,
            textColor: CodableColor(.white),
            backgroundColor: CodableColor(.black),
            panelScale: 1.0, panelMargin: 20,
            yabaiPath: nil, usePerScreenSpaceIndexing: true
        )
        let sig1 = ScreenOverlayManager.shared.preferenceSignature(p1)
        let sig2 = ScreenOverlayManager.shared.preferenceSignature(p2)
        #expect(sig1 != sig2)
    }

    @Test("preferenceSignature consistent for same preferences")
    func signatureConsistent() {
        let prefs = ScreenIndexPreferences.default
        let sig1 = ScreenOverlayManager.shared.preferenceSignature(prefs)
        let sig2 = ScreenOverlayManager.shared.preferenceSignature(prefs)
        #expect(sig1 == sig2)
    }
}
