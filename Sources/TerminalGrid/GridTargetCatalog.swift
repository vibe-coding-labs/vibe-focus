import CoreGraphics
import Foundation

// MARK: - 网格目标（屏幕/工作区）编解码 + 目录构建
/// 用户反馈（2026-09-06）：编排总是落在主屏，无法选择目标。这里把"编排目标"
/// 建模为可持久化字符串：主屏 / 焦点屏 / 指定屏 / 指定屏的指定工作区（yabai Space）。
/// 目录构建为纯函数（输入屏幕与 space 快照），设置页与控制器共享同一事实源。

/// 目标选择编码：
/// - `main`                    跟随系统主屏
/// - `focused`                 焦点窗口所在屏
/// - `d<displayID>`            指定屏（该屏当前可见工作区）
/// - `d<displayID>s<spaceIdx>` 指定屏的指定工作区（spaceIdx 为 yabai 全局索引）
enum GridTargetCode: Equatable {
    case main
    case focused
    case display(displayID: UInt32)
    case displaySpace(displayID: UInt32, spaceIndex: Int)

    var code: String {
        switch self {
        case .main:
            return "main"
        case .focused:
            return "focused"
        case .display(let displayID):
            return "d\(displayID)"
        case .displaySpace(let displayID, let spaceIndex):
            return "d\(displayID)s\(spaceIndex)"
        }
    }

    static func parse(_ raw: String?) -> GridTargetCode? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "main" { return .main }
        if raw == "focused" { return .focused }
        guard raw.hasPrefix("d") else { return nil }
        let body = raw.dropFirst()
        if let sIdx = body.firstIndex(of: "s") {
            guard let displayID = UInt32(body[..<sIdx]),
                  let spaceIndex = Int(body[body.index(after: sIdx)...]), spaceIndex > 0 else {
                return nil
            }
            return .displaySpace(displayID: displayID, spaceIndex: spaceIndex)
        }
        guard let displayID = UInt32(body) else { return nil }
        return .display(displayID: displayID)
    }

    /// 显式指定的 displayID（main/focused 无固定屏，返回 nil）
    var explicitDisplayID: UInt32? {
        switch self {
        case .main, .focused:
            return nil
        case .display(let displayID), .displaySpace(let displayID, _):
            return displayID
        }
    }
}

/// 设置页 Picker 的一个选项
struct GridTargetOption: Equatable, Identifiable {
    let target: GridTargetCode
    let label: String
    /// space 选项：是否目标屏当前可见工作区；屏级/自动选项恒 true（无需切换）
    let isActiveSpace: Bool
    var id: String { target.code }
}

enum GridTargetCatalog {

    /// 屏幕快照输入（脱离 NSScreen 便于单测）
    struct ScreenInput: Equatable {
        let displayID: UInt32
        let name: String
        let width: Int
        let height: Int
        let isMain: Bool
        /// yabai display 索引（1-based）；yabai 不可用时 nil
        let yabaiDisplayIndex: Int?
    }

    /// 工作区快照输入（yabai query --spaces 的最小投影）
    struct SpaceInput: Equatable {
        let yabaiIndex: Int
        let yabaiDisplayIndex: Int
        let isVisible: Bool
    }

    /// 构建目标目录：自动选项（主屏/焦点屏）+ 每块屏 + 每屏工作区细分。
    /// spaces 为空（yabai 不可用/查询失败/单工作区）→ 只到屏幕级，功能不降级缺失。
    /// 重名屏自动追加 #displayID 消歧。
    static func options(screens: [ScreenInput], spaces: [SpaceInput]) -> [GridTargetOption] {
        var result: [GridTargetOption] = [
            GridTargetOption(target: .main, label: "主屏（跟随系统主显示器）", isActiveSpace: true),
            GridTargetOption(target: .focused, label: "焦点窗口所在屏", isActiveSpace: true)
        ]
        let duplicatedNames = Set(screens.map { $0.name }.filter { name in screens.filter { $0.name == name }.count > 1 })
        for screen in screens {
            let mainTag = screen.isMain ? "（主）" : ""
            let nameSuffix = duplicatedNames.contains(screen.name) ? " #\(screen.displayID)" : ""
            let dims = "\(screen.width)×\(screen.height)"
            let screenSpaces = spaces
                .filter { $0.yabaiDisplayIndex == screen.yabaiDisplayIndex }
                .sorted { $0.yabaiIndex < $1.yabaiIndex }
            let activeSpace = screenSpaces.first { $0.isVisible }
            // 屏级选项 = 该屏当前可见工作区（选择后无需切换直接编排）
            var screenLabel = "\(screen.name)\(nameSuffix) \(dims)\(mainTag)"
            if let activeSpace {
                screenLabel += " · Space \(activeSpace.yabaiIndex)"
            }
            result.append(GridTargetOption(
                target: .display(displayID: screen.displayID),
                label: screenLabel,
                isActiveSpace: true
            ))
            for space in screenSpaces {
                result.append(GridTargetOption(
                    target: .displaySpace(displayID: screen.displayID, spaceIndex: space.yabaiIndex),
                    label: "　└ Space \(space.yabaiIndex)\(space.isVisible ? "（当前）" : "")",
                    isActiveSpace: space.isVisible
                ))
            }
        }
        return result
    }
}
