import CoreGraphics
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
    private static let hotKeyKey = "inputBubbleHotKeyConfiguration"
    private static let autoShowOnMoveToMainKey = "inputBubbleAutoShowOnMoveToMain"
    private static let userPlacedFrameKey = "inputBubbleUserFrame"

    /// 尺寸合法域与步长（设置页滑杆与 clamp 共用同一事实源）
    static let widthRange: (min: Double, max: Double, step: Double) = (320, 720, 20)
    static let heightRange: (min: Double, max: Double, step: Double) = (100, 300, 10)
    static let defaultWidth: Double = 480
    static let defaultHeight: Double = 150

    /// B175：尺寸变化广播——气泡拖拽落账与设置页滑杆写穿都会触发；
    /// 打开中的气泡面板实时 relayout 与设置页 @State 回写都消费此通知。
    /// 只在值真正变化时发（同值写不广播，联动回路自然收敛）。
    static let sizeDidChangeNotification = Notification.Name("InputBubbleSizeDidChange")

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) != nil
                ? UserDefaults.standard.bool(forKey: enabledKey)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 气泡宽度（pt）。越界/未设置经 clampedWidth 归一；变化时广播 sizeDidChangeNotification。
    static var bubbleWidth: Double {
        get { clampedWidth(UserDefaults.standard.double(forKey: widthKey)) }
        set {
            let normalized = clampedWidth(newValue)
            let changed = normalized != bubbleWidth
            UserDefaults.standard.set(normalized, forKey: widthKey)
            if changed { postSizeDidChange() }
        }
    }

    /// 气泡高度（pt）。越界/未设置经 clampedHeight 归一；变化时广播 sizeDidChangeNotification。
    static var bubbleHeight: Double {
        get { clampedHeight(UserDefaults.standard.double(forKey: heightKey)) }
        set {
            let normalized = clampedHeight(newValue)
            let changed = normalized != bubbleHeight
            UserDefaults.standard.set(normalized, forKey: heightKey)
            if changed { postSizeDidChange() }
        }
    }

    private static func postSizeDidChange() {
        NotificationCenter.default.post(name: sizeDidChangeNotification, object: nil)
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
    /// 快捷键手动唤起不受此开关影响）。
    static var autoShowOnFocus: Bool {
        get {
            UserDefaults.standard.object(forKey: autoShowKey) != nil
                ? UserDefaults.standard.bool(forKey: autoShowKey)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoShowKey) }
    }

    /// B162：唤起热键（默认 ⌘B，设置页可自定义；JSON 持久化，
    /// 解析失败回落 defaultConfig——手写 defaults 不致崩）。
    static var hotKey: HotKeyConfiguration {
        get {
            guard let data = UserDefaults.standard.data(forKey: hotKeyKey),
                  let decoded = try? JSONDecoder().decode(HotKeyConfiguration.self, from: data) else {
                return InputBubbleHotKeyPlan.defaultConfig
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: hotKeyKey)
            }
        }
    }

    /// B162：窗口被移动到主屏（Stop hook 拉回成功）时自动弹出气泡（默认开）。
    static var autoShowOnMoveToMain: Bool {
        get {
            UserDefaults.standard.object(forKey: autoShowOnMoveToMainKey) != nil
                ? UserDefaults.standard.bool(forKey: autoShowOnMoveToMainKey)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoShowOnMoveToMainKey) }
    }

    /// B162：用户拖动气泡后的记忆位置（AppKit 全局坐标 origin；nil = 从未拖过，
    /// 走目标窗锚点）。存 origin 而非整 frame：尺寸随设置实时变化，恢复时重夹取。
    static var userPlacedOrigin: CGPoint? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: userPlacedFrameKey) else { return nil }
            return InputBubbleLayout.decodeFrame(raw).map { $0.origin }
        }
        set {
            guard let origin = newValue else {
                UserDefaults.standard.removeObject(forKey: userPlacedFrameKey)
                return
            }
            UserDefaults.standard.set(
                InputBubbleLayout.encodeFrame(CGRect(origin: origin, size: .zero)),
                forKey: userPlacedFrameKey
            )
        }
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
