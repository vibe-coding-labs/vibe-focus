import Foundation

// MARK: - Space 快照纯类型层
// 本文件是 Overlay 刷新链路的「纯类型与纯函数」层：不依赖 AppKit、不 fork yabai、
// 不持有任何可变状态。I/O 由 ScreenOverlayManager+SpaceQuery.swift 负责，
// 编排由 ScreenOverlayManager+Refresh.swift 负责。

/// 单个 display 的 space 快照（来自 `yabai -m query --spaces --display <n>`）。
///
/// ## 场景
/// - 由 `queryYabaiSpacesAsync(forDisplayIndex:)` 解析产生，仅包含该 display 的 space；
/// - 供 fallback 路径（displayIndex 未全缓存时）逐屏计算 spaceIndex 使用。
///
/// ## 样例
/// `yabai -m query --spaces --display 1` 的单条输出（字段名为 kebab-case）：
/// ```json
/// {"index": 3, "label": "code", "display": 1, "is-visible": true, "has-focus": false, "type": "bsp"}
/// ```
struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

/// 全量 space 快照（含所属 yabai display index），来自 `yabai -m query --spaces`（不带过滤）。
///
/// ## 场景
/// - 由 `queryAllSpacesSnapshotAsync()` 解析产生，是刷新链路「快速路径」的数据源：
///   所有屏 displayIndex 均已缓存时，1 次 fork 拿全量 space，本地按 display 分组即可
///   算出每屏 spaceIndex，替代「focused 1 次 + 每屏 1 次」的 N+1 fork。
/// - 切屏瞬间 WindowServer 繁忙时单次 yabai query 可达 290ms~1s，fork 次数直接决定
///   overlay 编号更新延迟（实测 N+1 → 1 后约 192ms → 27ms）。
///
/// ## 样例
/// ```json
/// [{"index": 1, "display": 1, "is-visible": true,  "has-focus": true},
///  {"index": 2, "display": 1, "is-visible": false, "has-focus": false},
///  {"index": 1, "display": 2, "is-visible": true,  "has-focus": false}]
/// ```
/// 注意 display 是 yabai 的 displayIndex（1 起），不是 CGDirectDisplayID。
struct AllSpaceSnapshot: Equatable {
    let index: Int
    let display: Int
    let isVisible: Bool
    let hasFocus: Bool
}

// MARK: - 每屏可见 space 解析（纯函数，两条刷新路径共用的唯一决策点）

/// 「每屏可见 space 解析」所需的 space 公共形状。
///
/// ## 场景
/// fallback 路径（`SpaceSnapshot`，逐屏查询产物）与快速路径（`AllSpaceSnapshot`，
/// 全量查询按 display 分组）历史上各自内联同一段解析，且默认值语义漂移
/// （nil vs 1）；2026-09-02 抽出 `resolveScreenSpaceIndex` 后以此协议统一数据面。
protocol SpaceIndexResolvable {
    /// yabai 全局 space index（跨 display 连续编号）。
    var index: Int { get }
    /// 该 space 在其所属 display 上是否可见。
    var isVisible: Bool { get }
}

extension SpaceSnapshot: SpaceIndexResolvable {}
extension AllSpaceSnapshot: SpaceIndexResolvable {}

extension SpaceIndexResolvable {

    /// 解析一块 display 上应显示的 space 编号（overlay 屏幕编号，1 起）。
    ///
    /// 优先级（历史两路实现行为收敛，语义以本函数为唯一权威）：
    ///   1) focused space（调用方从全量快照按 `hasFocus` 解出的 yabai 全局 index）
    ///      落在本 display → 按 index 升序的位次；
    ///   2) 否则第一个可见 space 的位次；
    ///   3) 都没有（空列表 / focused 属于别的 display / 全不可见）→ nil，
    ///      由调用方按各自契约收敛（fallback 路径 `?? 1`，快速路径保留 nil 至
    ///      applyRefreshResults `?? 1`——最终默认均为 1，与历史行为一致）。
    ///
    /// ## 场景
    /// - 输入不保证有序（yabai 输出顺序不承诺），函数内部按 index 升序排序后再取位次；
    /// - 分支穷尽锁定：`Tests/Standalone/ScreenSpaceIndexResolutionTests.swift`。
    static func resolveScreenSpaceIndex(from spaces: [Self], focusedSpaceIndex: Int?) -> Int? {
        let sorted = spaces.sorted { $0.index < $1.index }
        if let focused = focusedSpaceIndex,
           let position = sorted.firstIndex(where: { $0.index == focused }) {
            return position + 1
        }
        if let position = sorted.firstIndex(where: { $0.isVisible }) {
            return position + 1
        }
        return nil
    }
}

// MARK: - JSON 解析（纯函数，fixture 可测）

extension SpaceSnapshot {

    /// 解析 `yabai -m query --spaces`（全量或 `--display` 过滤）输出。
    ///
    /// ## 场景
    /// - 两个 async 查询函数共用；解析规则必须与 yabai 实际输出逐字段对齐，
    ///   因此抽成纯函数由 `Tests/Fixtures/yabai-spaces-two-displays.json` 驱动测试。
    ///
    /// ## 防御性解析
    /// yabai 各版本字段类型有漂移历史：`is-visible`/`has-focus` 既有 Bool 也有 Int(0/1)
    /// 两种形态；缺 `index` 的条目跳过（不使整个查询失败）。
    ///
    /// - Parameter jsonArray: `JSONSerialization` 反序列化后的数组（调用方负责 `try?`）。
    /// - Returns: 解析成功的条目；输入为空数组时返回空数组。
    static func parse(from jsonArray: [[String: Any]]) -> [SpaceSnapshot] {
        jsonArray.compactMap { space in
            guard let index = space["index"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return SpaceSnapshot(index: index, isVisible: visible, hasFocus: hasFocus)
        }
    }
}

extension AllSpaceSnapshot {

    /// 解析 `yabai -m query --spaces`（无过滤全量）输出，用于快速路径。
    ///
    /// ## 场景
    /// - 与 `SpaceSnapshot.parse(from:)` 同源同防御规则，额外要求 `display` 字段：
    ///   缺 `index` 或缺 `display` 的条目直接跳过——快速路径按 display 分组，
    ///   没有 display 的条目无法归属任何屏幕。
    static func parse(from jsonArray: [[String: Any]]) -> [AllSpaceSnapshot] {
        jsonArray.compactMap { space in
            guard let index = space["index"] as? Int,
                  let display = space["display"] as? Int else { return nil }
            let visible = (space["is-visible"] as? Bool) ?? ((space["is-visible"] as? Int ?? 0) == 1)
            let hasFocus = (space["has-focus"] as? Bool) ?? ((space["has-focus"] as? Int ?? 0) == 1)
            return AllSpaceSnapshot(index: index, display: display, isVisible: visible, hasFocus: hasFocus)
        }
    }

    /// 把 `Data` 反序列化为对象数组；形状不符（对象/数组嵌套不对）返回 nil。
    ///
    /// ## 场景
    /// - yabai 超时输出空串、权限报错输出非 JSON 时走 nil 分支，查询函数据此
    ///   落到 fallback 或放弃本轮刷新。
    static func parseJSONArray(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }
}

