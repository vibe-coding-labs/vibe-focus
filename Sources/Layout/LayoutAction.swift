import Carbon
import Foundation

// MARK: - 摆位动作
/// Rectangle 式摆位动作（设计对齐 Rectangle，实现为本仓自有纯函数层，见
/// docs/design-rectangle-integration.md）。
enum LayoutAction: String, CaseIterable, Codable, Equatable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case maximize
    case center
    case nextDisplay

    var displayName: String {
        switch self {
        case .leftHalf: return "左半屏"
        case .rightHalf: return "右半屏"
        case .topHalf: return "上半屏"
        case .bottomHalf: return "下半屏"
        case .topLeftQuarter: return "左上四分"
        case .topRightQuarter: return "右上四分"
        case .bottomLeftQuarter: return "左下四分"
        case .bottomRightQuarter: return "右下四分"
        case .maximize: return "最大化"
        case .center: return "居中"
        case .nextDisplay: return "移到下一屏"
        }
    }

    /// Carbon 默认热键（对齐 Rectangle 的 ⌃⌥ 惯例；与主 toggle ⌃Q、标题编辑 Ctrl+T 错开）
    static let defaultBindings: [LayoutAction: HotKeyConfiguration] = [
        .leftHalf: .init(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey)),
        .rightHalf: .init(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey | optionKey)),
        .topHalf: .init(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey | optionKey)),
        .bottomHalf: .init(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey | optionKey)),
        .topLeftQuarter: .init(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey)),
        .topRightQuarter: .init(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey)),
        .bottomLeftQuarter: .init(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey)),
        .bottomRightQuarter: .init(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)),
        .maximize: .init(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey | optionKey)),
        .center: .init(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey)),
        .nextDisplay: .init(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))
    ]

    /// Carbon hotkey id 分配：hotkeySignature 域内与 1=toggle、2=title editor 错开，
    /// 固定槽位 100+index，注册/分派两端共用此映射。
    var carbonHotKeyID: UInt32 {
        guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
        return UInt32(100 + index)
    }

    static func action(forCarbonHotKeyID id: UInt32) -> LayoutAction? {
        guard id >= 100, id < 100 + UInt32(Self.allCases.count) else { return nil }
        return Self.allCases[Int(id - 100)]
    }
}
