import Foundation

/// 屏幕热插拔防护（纯函数命名空间，非 @MainActor，可被 Standalone 测试直接调用）。
///
/// 背景：refreshSpaceIndices 在主线程取 NSScreen.screens 快照构造 preResolved，
/// 随后派发后台 Task fork yabai（可能耗时数百 ms~2s）。后台期间若发生显示器插拔，
/// NSScreen.screens 变化，但 Task 持有的 preResolved（含 enumerated index）已过期。
/// 回调时 results 携带旧 index 却配新 NSScreen.screens → 错位访问 + 误触发 refreshOverlays
/// 对变化中的 WindowServer 操作 → SIGSEGV。
///
/// 本类型提供两个纯函数：
/// - identityMatches：判定 Task 启动时的屏幕 uuid 集合是否与当前一致（不一致则丢弃整个结果）
/// - filterStale：对 results 做防御性二次过滤，剔除已消失屏幕的条目（applyRefreshResults 内使用）
enum ScreenHotplugGuard {

    /// 判定后台 Task 启动时捕获的屏幕 uuid 集合（preUUIDs）是否与当前实时屏幕（currentUUIDs）一致。
    ///
    /// 使用集合相等（而非数组相等）：NSScreen.screens 的顺序在屏幕重排时可能变化，
    /// 但只要屏幕集合不变（稳态切屏常态），index 可安全复用。仅当集合元素变化（插拔）才判定不一致。
    ///
    /// - Returns: `true` 表示未发生热插拔，results 安全可用；`false` 表示期间发生插拔，必须丢弃。
    static func identityMatches(preUUIDs: Set<UUID>, currentUUIDs: Set<UUID>) -> Bool {
        preUUIDs == currentUUIDs
    }

    /// 防御性二次过滤：剔除 results 中 uuid 已不在 liveUUIDs（当前屏幕）的条目。
    ///
    /// 即便上游守卫放行（集合相等），applyRefreshResults 内仍以此做单条目防御，
    /// 防止极少数「集合瞬间相等但单个 result 指向已失效 NSScreen」的窄窗口。
    /// 返回仅含 live 屏幕的 results 子集。
    static func filterStale(
        _ results: [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)],
        liveUUIDs: Set<UUID>
    ) -> [(index: Int, uuid: UUID, displayIndex: Int?, spaceIndex: Int?)] {
        results.filter { liveUUIDs.contains($0.uuid) }
    }
}
