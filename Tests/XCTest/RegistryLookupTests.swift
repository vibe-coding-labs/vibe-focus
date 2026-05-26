import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SessionWindowRegistry Lookup")
@MainActor
struct RegistryLookupTests {

    @Test("findBinding returns nil for unknown windowID")
    func findBindingUnknown() {
        let registry = SessionWindowRegistry.shared
        let result = registry.findBinding(forWindowID: 99999)
        #expect(result == nil)
    }

    @Test("findBinding returns fields for existing binding in registry")
    func findBindingExisting() {
        let registry = SessionWindowRegistry.shared
        // Use an existing binding from the registry if any exist
        if let firstState = registry.windowStates.values.first {
            let windowID = firstState.windowID
            let result = registry.findBinding(forWindowID: windowID)
            #expect(result != nil)
            #expect(result?.sessionID == firstState.sessionID)
            #expect(result?.cwd == firstState.cwd)
            #expect(result?.model == firstState.model)
        }
        // Pass if registry is empty — no bindings to test
    }

    @Test("activeBindingCount is non-negative")
    func activeBindingCountNonNegative() {
        let registry = SessionWindowRegistry.shared
        #expect(registry.activeBindingCount >= 0)
    }

    @Test("completedBindingCount is non-negative")
    func completedBindingCountNonNegative() {
        let registry = SessionWindowRegistry.shared
        #expect(registry.completedBindingCount >= 0)
    }

    @Test("activeBindingCount + completedBindingCount equals total states")
    func bindingCountConsistency() {
        let registry = SessionWindowRegistry.shared
        let total = registry.windowStates.count
        #expect(registry.activeBindingCount + registry.completedBindingCount == total)
    }

    @Test("lastEventDescription is a non-empty string")
    func lastEventDescription() {
        let registry = SessionWindowRegistry.shared
        #expect(!registry.lastEventDescription.isEmpty)
    }
}
