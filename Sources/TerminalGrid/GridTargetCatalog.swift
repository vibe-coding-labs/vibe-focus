import CoreGraphics
import Foundation

// MARK: - 网格目标（屏幕/工作区）编解码
/// 把"编排目标"建模为可持久化字符串：主屏 / 焦点屏 / 指定屏 / 指定屏的指定
/// 工作区（yabai Space）。设置页 minimap 点击与控制器解析共用同一事实源。

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
