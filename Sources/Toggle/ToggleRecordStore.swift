import Foundation
import CoreGraphics

/// Protocol abstracting toggle record data access — enables test mocking.
///
/// B180：协议去隔离——conformer 的 SQLite 读写经 WindowWorkExecutor 串行队列 +
/// sqlite WAL 串行模式保护；主线程（⌃Q toggle）与窗口作业线程不再同线程。
/// 协议不隔离时 conformance 会跨入主线程隔离产生 data-race 警告。
protocol ToggleRecordStore: Sendable {
    func load(windowID: UInt32) -> ToggleRecord?
    func loadByPID(pid: Int32) -> ToggleRecord?
    func clear(windowID: UInt32)
}

// ToggleEngine already conforms via its existing methods.
