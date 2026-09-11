import Foundation

/// 输入气泡功能偏好（B129 开关 + B133 设置页：尺寸/回车默认行为）。
/// 热键三通道（CGEventTap/Carbon/fallback monitor）都在 isEnabled 闸门后；
/// 数值读取经 clamp 归一（defaults 手写越界不影响 UI 与注入）。
enum InputBubblePreferences {
    private static let enabledKey = "inputBubbleEnabled"
    private static let widthKey = "inputBubbleWidth"
    private static let heightKey = "inputBubbleHeight"
    private static let submitOnEnterKey = "inputBubbleSubmitOnEnter"
    private static let autoShowKey = "inputBubbleAutoShowOnFocus"
    private static let defaultPrefixKey = "inputBubbleDefaultPrefix"

    /// 尺寸合法域与步长（设置页滑杆与 clamp 共用同一事实源）
    static let widthRange: (min: Double, max: Double, step: Double) = (320, 720, 20)
    static let heightRange: (min: Double, max: Double, step: Double) = (100, 300, 10)
    static let defaultWidth: Double = 480
    static let defaultHeight: Double = 150

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) != nil
                ? UserDefaults.standard.bool(forKey: enabledKey)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 气泡宽度（pt）。越界/未设置经 clampedWidth 归一。
    static var bubbleWidth: Double {
        get { clampedWidth(UserDefaults.standard.double(forKey: widthKey)) }
        set { UserDefaults.standard.set(clampedWidth(newValue), forKey: widthKey) }
    }

    /// 气泡高度（pt）。越界/未设置经 clampedHeight 归一。
    static var bubbleHeight: Double {
        get { clampedHeight(UserDefaults.standard.double(forKey: heightKey)) }
        set { UserDefaults.standard.set(clampedHeight(newValue), forKey: heightKey) }
    }

    /// Enter 默认行为：false（默认，B161）=Enter 换行、⌘Enter 注入并提交；
    /// true=Enter 注入并提交、⌘Enter 仅粘贴。
    static var submitOnEnter: Bool {
        get {
            UserDefaults.standard.object(forKey: submitOnEnterKey) != nil
                ? UserDefaults.standard.bool(forKey: submitOnEnterKey)
                : false
        }
        set { UserDefaults.standard.set(newValue, forKey: submitOnEnterKey) }
    }

    /// B161：气泡打开时预填的默认前缀（如 "/goal "，重复性输入免手打；原样保留尾随空格）。
    static var defaultPrefix: String {
        get { UserDefaults.standard.string(forKey: defaultPrefixKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: defaultPrefixKey) }
    }

    /// B160：焦点落到活跃 Claude 会话所在终端窗时自动弹出气泡（默认开；
    /// ⌥⌘B 手动唤起不受此开关影响）。
    static var autoShowOnFocus: Bool {
        get {
            UserDefaults.standard.object(forKey: autoShowKey) != nil
                ? UserDefaults.standard.bool(forKey: autoShowKey)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoShowKey) }
    }

    // MARK: - 归一（纯函数，Runner 直测）

    /// 步进取整 + 范围钳制；未设置（0）与越界值回落默认。
    static func clampedWidth(_ raw: Double) -> Double {
        clamped(raw, range: widthRange, fallback: defaultWidth)
    }

    static func clampedHeight(_ raw: Double) -> Double {
        clamped(raw, range: heightRange, fallback: defaultHeight)
    }

    private static func clamped(_ raw: Double, range: (min: Double, max: Double, step: Double), fallback: Double) -> Double {
        guard raw > 0 else { return fallback }
        let stepped = range.step > 0 ? (raw / range.step).rounded() * range.step : raw
        return min(max(stepped, range.min), range.max)
    }
}
