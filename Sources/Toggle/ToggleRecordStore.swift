import Foundation
import CoreGraphics

/// Protocol abstracting toggle record data access — enables test mocking.
///
/// @MainActor：唯一 conformer ToggleEngine 是 @MainActor 类（SQLite 读写不线程安全），
/// 协议不隔离时 conformance 会跨入主线程隔离产生 data-race 警告。
@MainActor
protocol ToggleRecordStore: Sendable {
    func load(windowID: UInt32) -> ToggleRecord?
    func loadByPID(pid: Int32) -> ToggleRecord?
    func clear(windowID: UInt32)
}

// ToggleEngine already conforms via its existing methods.
