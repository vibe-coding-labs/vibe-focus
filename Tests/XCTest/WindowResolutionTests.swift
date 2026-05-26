import Testing
import Foundation
@testable import VibeFocusKit

@Suite("Window Resolution Decision")
@MainActor
struct WindowResolutionTests {

    let validIdentity = WindowIdentity(
        windowID: 42, pid: 1234,
        bundleIdentifier: "com.apple.Terminal",
        appName: "Terminal", title: "bash"
    )

    // MARK: - Binding verified → return binding identity

    @Test("decideWindowResolution: binding verified → returns binding identity")
    func bindingVerified() {
        let result = HookEventHandler.decideWindowResolution(
            hasBinding: true,
            bindingVerified: true,
            bindingIdentity: validIdentity
        )
        if case .binding(let identity) = result {
            #expect(identity.windowID == 42)
        } else {
            #expect(Bool(false), "Expected .binding, got \(String(describing: result))")
        }
    }

    // MARK: - Binding not verified → nil

    @Test("decideWindowResolution: binding not verified → nil")
    func bindingNotVerified() {
        let result = HookEventHandler.decideWindowResolution(
            hasBinding: true,
            bindingVerified: false,
            bindingIdentity: validIdentity
        )
        #expect(result == nil)
    }

    // MARK: - No binding → nil

    @Test("decideWindowResolution: no binding → nil")
    func noBinding() {
        let result = HookEventHandler.decideWindowResolution(
            hasBinding: false,
            bindingVerified: false,
            bindingIdentity: nil
        )
        #expect(result == nil)
    }
}
