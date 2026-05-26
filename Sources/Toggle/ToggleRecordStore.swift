import Foundation
import CoreGraphics

/// Protocol abstracting toggle record data access — enables test mocking.
protocol ToggleRecordStore: Sendable {
    func load(windowID: UInt32) -> ToggleRecord?
    func loadByPID(pid: Int32) -> ToggleRecord?
    func clear(windowID: UInt32)
}

// ToggleEngine already conforms via its existing methods.
