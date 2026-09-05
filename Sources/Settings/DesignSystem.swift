// DesignSystem.swift
// VibeFocus — 设置窗设计体系（色彩 / 圆角 / 共享组件）
// 所有页面共用同一套 token 与组件，替代各区块 ad-hoc 的颜色、圆角、横幅写法；
// 品牌主色在根视图以 .tint 注入，普通控件（开关/滑杆/选择器/按钮）自动跟随。

import AppKit
import SwiftUI

// MARK: - 亮暗自适应颜色

extension Color {
    /// 以 NSColor 动态提供器构造亮 / 暗两套色值（设置窗跟随系统外观）
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    init(light: UInt32, dark: UInt32) {
        self.init(
            light: NSColor(rgbHex: light),
            dark: NSColor(rgbHex: dark)
        )
    }
}

extension NSColor {
    convenience init(rgbHex: UInt32) {
        self.init(
            srgbRed: CGFloat((rgbHex >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgbHex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// MARK: - 色彩 Token
//
// 小红书独立开发者风：奶油暖底 + 珊瑚红主色 + 暖棕墨色 + 柔和暖阴影。
// 全部自定义动态色（不取系统语义色），亮暗两套分别校准。

enum VibeColors {
    // --- 画布层 ---
    /// 窗口底：奶油米色 / 暖棕近黑
    static let background = Color(light: 0xF6F1E7, dark: 0x211C18)
    /// 卡片面：暖白 / 暖深棕
    static let card = Color(light: 0xFFFCF5, dark: 0x2C2721)
    /// 暖发丝线 / 分隔
    static let hairline = Color(
        light: NSColor(rgbHex: 0xE8DDCB),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    /// 标题墨色：暖棕黑 / 暖白（比纯 label 更柔和）
    static let ink = Color(light: 0x40362B, dark: 0xF1E9DE)

    // --- 品牌 ---
    /// 品牌主色：珊瑚朱红（小红书系）
    static let accent = Color(light: 0xE64A33, dark: 0xFF8266)
    /// 品牌渐变第二色：蜜桃橙
    static let accentPeach = Color(light: 0xF49A4A, dark: 0xFFB07A)

    // --- 语义状态色（低饱和暖调） ---
    /// 抹茶绿
    static let success = Color(light: 0x539B6B, dark: 0x8FD6A8)
    /// 蜂蜜琥珀
    static let warning = Color(light: 0xD98E2B, dark: 0xF6C453)
    /// 深砖红（危险动作，比主色更深沉以示区分）
    static let danger = Color(light: 0xC13327, dark: 0xFF7B6E)
    static let neutral = Color(nsColor: .secondaryLabelColor)

    /// 暖棕阴影色（替代纯黑，投影不发灰）
    static let shadow = Color(red: 0.36, green: 0.25, blue: 0.14)

    /// 头部品牌晕染：珊瑚→蜜桃的极淡渐变，只在窗口顶部铺一层空气感
    static var headerWash: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.08), accentPeach.opacity(0.05), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 主按钮渐变：珊瑚→蜜桃
    static var prominentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentPeach],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// 品牌主色的 NSColor 版（AppKit 视图如快捷键录制按钮使用）
    static let accentNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgbHex: isDark ? 0xFF8266 : 0xE64A33)
    }

    /// 窗口底的 NSColor 版（SettingsWindowController 背景与 SwiftUI 根保持一致）
    static let backgroundNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgbHex: isDark ? 0x211C18 : 0xF6F1E7)
    }

    /// 卡片面的 NSColor 版
    static let cardNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgbHex: isDark ? 0x2C2721 : 0xFFFCF5)
    }

    /// 暖发丝线的 NSColor 版
    static let hairlineNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor(rgbHex: 0xE8DDCB)
    }
}

// MARK: - 圆角 Token
// 小红书风整体放大一档圆角，观感更软

enum VibeRadius {
    static let card: CGFloat = 16       // 设置卡片外框
    static let panel: CGFloat = 12      // 卡片内画布 / 横幅
    static let control: CGFloat = 9     // 按钮 / 输入框 / 标签栏
    static let chip: CGFloat = 7        // 小徽标 / 代码块
}

// MARK: - 区块图标徽章

/// 卡片标题左侧的小图标徽章：tinted 圆角方块，给每个区块一个可识别的锚点
struct SectionIconChip: View {
    let icon: String
    var tint: Color = VibeColors.accent

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
            )
    }
}

// MARK: - 胶囊标签

/// 元数据小标签：LIVE / 版本号 / Space 编号等中性或着色胶囊
struct CapsuleTag: View {
    let text: String
    var tint: Color = VibeColors.neutral
    var isOutlined = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(isOutlined ? tint : tint.opacity(0.95))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(isOutlined ? Color.clear : tint.opacity(0.10))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(isOutlined ? 0.35 : 0.12), lineWidth: 1)
            )
    }
}

// MARK: - 信息横幅

/// 统一的提示横幅：替代各区块自绘的黄底 / 橙底 / 蓝底 HStack
struct InfoBanner<Accessory: View>: View {
    enum Style {
        case info       // 品牌色：说明 / 工作原理
        case tip        // 琥珀：建议、注意事项
        case warning    // 橙：需要用户处理
        case danger     // 红：错误后果
        case success    // 绿：成功状态说明

        var tint: Color {
            switch self {
            case .info: return VibeColors.accent
            case .tip: return VibeColors.warning
            case .warning: return Color.orange
            case .danger: return VibeColors.danger
            case .success: return VibeColors.success
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .tip: return "lightbulb.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let style: Style
    var title: String?
    let text: String
    /// 尾部操作插槽（如「重置为主屏」按钮）
    var accessory: Accessory

    init(
        style: Style,
        title: String? = nil,
        text: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.style = style
        self.title = title
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 13))
                .foregroundStyle(style.tint)

            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(style.tint)
                }
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                .fill(style.tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                .strokeBorder(style.tint.opacity(0.16), lineWidth: 1)
        )
    }
}

// MARK: - 主按钮样式

/// 渐变主按钮：珊瑚→蜜桃渐变 + 暖色投影 + 悬停微亮 + 按压微暗，用于每页至多一两个核心动作
struct VibeProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                    .fill(VibeColors.prominentGradient)
                    .opacity(isEnabled ? 1 : 0.35)
            )
            .shadow(
                color: VibeColors.accent.opacity(isEnabled ? (isHovered ? 0.38 : 0.26) : 0),
                radius: isHovered ? 9 : 6,
                y: 2
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

extension ButtonStyle where Self == VibeProminentButtonStyle {
    static var vibeProminent: VibeProminentButtonStyle { VibeProminentButtonStyle() }
}

// MARK: - 卡片背景修饰器

/// 统一卡片容器外观：暖白浮起 + 暖发丝描边 + 柔和暖棕投影（小红书风的关键是阴影带暖调、
/// 半径偏大，形成「枕状」蓬松感；暗色模式投影自然弱化）
struct VibeCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                    .fill(VibeColors.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                    .strokeBorder(VibeColors.hairline, lineWidth: 1)
            )
            .shadow(color: VibeColors.shadow.opacity(0.08), radius: 9, y: 3)
    }
}

extension View {
    func vibeCardStyle() -> some View {
        modifier(VibeCardStyle())
    }
}

// MARK: - 点阵画布

/// minimap 背景的点阵网格：设计工具式的「画布」质感
struct DotGridPattern: View {
    var spacing: CGFloat = 18
    var dotSize: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            let rows = Int(size.height / spacing)
            let cols = Int(size.width / spacing)
            let offsetX = (size.width - CGFloat(cols - 1) * spacing) / 2
            let offsetY = (size.height - CGFloat(rows - 1) * spacing) / 2
            let dot = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            for row in 0...max(rows - 1, 0) {
                for col in 0...max(cols - 1, 0) {
                    context.fill(
                        Path(ellipseIn: dot.offsetBy(dx: offsetX + CGFloat(col) * spacing - dotSize / 2,
                                                     dy: offsetY + CGFloat(row) * spacing - dotSize / 2)),
                        with: .color(Color.primary.opacity(0.08))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
