import Foundation

// RestoreSpaceTargetResolver.swift — restore 源屏/源 space 目标解析（纯函数，无 IO）
//
// 2026-11-03 引入，起因：用户主诉「工作区 2 的窗口还原时落到工作区 3 的对应位置」。
// 取证链上有三个既有缺口：
//   1. record.sourceSpace 是 **toggle 时刻的 yabai 全局索引**。yabai 的 index 按全部
//      space 的顺序编号，任一屏增删 space 都会让其后的 space 整体位移；拿旧索引当
//      还原目标即落到相邻工作区。
//   2. record.sourceDispSpace 是 display-local 序号（该屏第几个工作区，与用户在
//      Mission Control / 胶囊上看到的编号一致）。fresh topology 下按本地序号回译出的
//      全局索引，才是用户语义里的「原工作区」。
//   3. 预切回决策读的是 2s 查询缓存（visibleSpaceIndex(ignoreCache:false)）——
//      toggle 与 restore 间隔短时，缓存里的「源屏可见 space」是切走前的旧值，
//      决策会误判 notNeeded 而跳过切回。
//
// 本解析器只做纯判定：输入 record 字段 + fresh topology + origFrame 的几何屏，
// 输出实际要切回的 display/space 与取证素材。IO 仍归 SpaceController（见
// RestoreSpaceChanneling.querySpaceTopology / sourceDisplayForFrame）。
enum RestoreSpaceTargetResolver {

    /// 解析结果（全部字段进 restore 取证日志；Runner 分支穷尽锁定）。
    struct Resolution: Equatable {
        /// 实际下发的 yabai display 索引（几何屏优先，失败回退 record）
        let displayIndex: Int
        /// 实际下发的 yabai 全局 space 索引（display-local 回译优先）
        let spaceIndex: Int
        /// record 里的原始全局索引（可能因 space 增删而漂移）
        let recordedSpaceIndex: Int
        /// record 里的 display-local 序号（1-based，0=无信息）
        let recordedLocalSpace: Int
        /// fresh topology 里该屏当前可见 space（nil=拓扑里没有该屏）
        let visibleSpaceIndex: Int?
        /// 该 display 是否出现在 fresh topology 中（false=屏号漂移/已拔屏）
        let displayInTopology: Bool
        /// 解析出的目标 space 是否真的位于所选 display（false=本地序号失配/跨屏漂移，
        /// 切过去会落到别的屏的工作区，调用方应如实降级而不是盲切）
        let spaceOnDisplay: Bool
        /// 按本地序号回译后是否与 recorded 全局索引不同（true=索引已漂移）
        let spaceIndexShifted: Bool
        /// display 取自几何屏还是 record（取证用）
        let displaySource: DisplaySource
        /// 几何屏与 record 屏不一致（同一块屏的 yabai 索引漂移，或窗口已跨屏）
        let displayMismatch: Bool

        enum DisplaySource: String, Equatable {
            case geometry
            case recorded
        }
    }

    /// 解析目标 display/space。
    ///
    /// - Parameters:
    ///   - recordedSpace: record.sourceSpace（toggle 时刻全局索引，0=无信息）
    ///   - recordedDisplay: record.sourceYabaiDisp（toggle 时刻 display 索引，0=无信息）
    ///   - recordedLocalSpace: record.sourceDispSpace（display-local 序号，1-based，0=无信息）
    ///   - geometricDisplay: origFrame 当前几何归属的 yabai display（nil=映射失败）
    ///   - spaces: fresh space 拓扑（nil/空=查询失败或 yabai 不可用）
    /// - Returns: nil 表示无法解析（无 space 上下文或拓扑不可用），调用方走旧路径。
    static func resolve(
        recordedSpace: Int,
        recordedDisplay: Int,
        recordedLocalSpace: Int,
        geometricDisplay: Int?,
        spaces: [YabaiSpaceInfo]?
    ) -> Resolution? {
        guard recordedSpace > 0, let spaces, !spaces.isEmpty else { return nil }

        let knownDisplays = Set(spaces.compactMap(\.display))
        var candidates: [(index: Int, source: Resolution.DisplaySource)] = []
        if let geometricDisplay, geometricDisplay > 0 {
            candidates.append((geometricDisplay, .geometry))
        }
        if recordedDisplay > 0 {
            candidates.append((recordedDisplay, .recorded))
        }
        // 优先取 fresh topology 里存在的屏；都不存在时仍保留候选（用于如实上报「屏号已漂移」）。
        let chosen = candidates.first(where: { knownDisplays.contains($0.0) }) ?? candidates.first
        guard let chosen else { return nil }

        let onDisplay = spacesOnDisplay(chosen.0, in: spaces)
        let displayInTopology = !onDisplay.isEmpty
        let visibleSpace = onDisplay.first(where: { $0.isVisible == true })?.index
        let resolvedSpace: Int
        let shifted: Bool
        if displayInTopology,
           recordedLocalSpace > 0,
           recordedLocalSpace <= onDisplay.count,
           let localIndex = onDisplay[recordedLocalSpace - 1].index {
            resolvedSpace = localIndex
            shifted = localIndex != recordedSpace
        } else {
            resolvedSpace = recordedSpace
            shifted = false
        }
        let displayMismatch = geometricDisplay.map { $0 > 0 && recordedDisplay > 0 && $0 != recordedDisplay } ?? false
        let spaceOnDisplay = displayInTopology && onDisplay.contains { $0.index == resolvedSpace }

        return Resolution(
            displayIndex: chosen.0,
            spaceIndex: resolvedSpace,
            recordedSpaceIndex: recordedSpace,
            recordedLocalSpace: recordedLocalSpace,
            visibleSpaceIndex: visibleSpace,
            displayInTopology: displayInTopology,
            spaceOnDisplay: spaceOnDisplay,
            spaceIndexShifted: shifted,
            displaySource: chosen.1,
            displayMismatch: displayMismatch
        )
    }

    /// 指定 display 上的 space，按 yabai 全局索引升序（本地序号 = 数组下标 + 1）。
    static func spacesOnDisplay(_ displayIndex: Int, in spaces: [YabaiSpaceInfo]) -> [YabaiSpaceInfo] {
        spaces
            .filter { $0.display == displayIndex && $0.index != nil }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// fresh topology 的紧凑取证串：`idx:id@disp/v|h,...`（按全局索引升序）。
    /// 例：`1:id1@d1/v,2:id5@d2/h,3:id6@d2/v`。nil → `"nil"`。
    static func describeTopology(_ spaces: [YabaiSpaceInfo]?) -> String {
        guard let spaces else { return "nil" }
        return spaces
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }
            .map { space in
                let index = space.index.map(String.init) ?? "?"
                let id = space.id.map(String.init) ?? "?"
                let display = space.display.map(String.init) ?? "?"
                let visibility = space.isVisible == true ? "v" : "h"
                return "\(index):id\(id)@d\(display)/\(visibility)"
            }
            .joined(separator: ",")
    }

    /// 解析结果的取证串：`display=2<geometry>;space=4(recorded 3,local 2,shifted);visible=4;inTopology=true;mismatch=false`。
    static func describe(_ resolution: Resolution?) -> String {
        guard let resolution else { return "unresolved" }
        let display = "\(resolution.displayIndex)<\(resolution.displaySource.rawValue)>"
        let space = "\(resolution.spaceIndex)(recorded \(resolution.recordedSpaceIndex),local \(resolution.recordedLocalSpace),shifted \(resolution.spaceIndexShifted))"
        let visible = resolution.visibleSpaceIndex.map(String.init) ?? "nil"
        return "display=\(display);space=\(space);visible=\(visible);inTopology=\(resolution.displayInTopology);onDisplay=\(resolution.spaceOnDisplay);mismatch=\(resolution.displayMismatch)"
    }
}
