import Foundation

// Agent 设置目录（design-agent-access.md「全量设置项 Agent 化」批）：
// 整个设置界面的每一项都对 Agent 开放**读**（L0）；**写**走独立授权开关
// `agentAllowSettingsWrite`（默认关）+ 白名单。安全/凭据/热键/授权类
// （改热键、AX 权限、端口/token、LAN、yabai SA、Agent 授权开关自身、MCP 注册、
// hook/Codex 安装卸载、登录项）**永不入写表**——那是人的专属，读侧照常可见。
// 单一事实源：本目录 = GET 全量读 + POST 白名单写 + 校验钳制的唯一出处。

// MARK: - 值类型与规格

enum AgentSettingValueKind: Equatable {
    case bool
    case int(range: ClosedRange<Int>)
    case double(range: ClosedRange<Double>)
    case option(cases: [String])
    case text(maxLength: Int)

    var typeName: String {
        switch self {
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .option: return "option"
        case .text: return "text"
        }
    }
}

struct AgentSettingSpec {
    let key: String
    let category: String
    let kind: AgentSettingValueKind
    let summary: String
    /// 校验通过的代表性样值（Runner 全表回环用）
    let sample: Any
}

// MARK: - 校验（纯函数）

enum AgentSettingsValidator {
    enum Outcome: Equatable {
        case ok
        case badType
        case outOfRange
    }

    static func validate(kind: AgentSettingValueKind, raw: Any) -> Outcome {
        switch kind {
        case .bool:
            return raw is Bool ? .ok : .badType
        case .int(let range):
            guard let n = raw as? Int else { return .badType }
            return range.contains(n) ? .ok : .outOfRange
        case .double(let range):
            if let n = raw as? Double { return range.contains(n) ? .ok : .outOfRange }
            if let n = raw as? Int { return range.contains(Double(n)) ? .ok : .outOfRange }
            return .badType
        case .option(let cases):
            guard let s = raw as? String else { return .badType }
            return cases.contains(s) ? .ok : .outOfRange
        case .text(let maxLength):
            guard let s = raw as? String else { return .badType }
            return (1...maxLength).contains(s.count) ? .ok : .outOfRange
        }
    }
}

// MARK: - 目录

@MainActor
enum AgentSettingsCatalog {

    // MARK: 白名单（agent 可写）

    static let soundTypes = CompletionSoundType.allCases.map(\.rawValue)
    static let voiceModes = VoiceAnnouncementMode.allCases.map(\.rawValue)
    static let overlayPositions = IndexPosition.allCases.map(\.rawValue)

    static let specs: [AgentSettingSpec] = [
        // 提示音
        AgentSettingSpec(key: "sound.type", category: "sound", kind: .option(cases: soundTypes), summary: "完成提示音类型（none=静默）", sample: "builtin_ding"),
        AgentSettingSpec(key: "sound.volume", category: "sound", kind: .double(range: 0...1), summary: "提示音音量", sample: 0.5),
        AgentSettingSpec(key: "sound.minPlayIntervalSeconds", category: "sound", kind: .int(range: 0...600), summary: "两次完成音最小间隔秒（0=不限）", sample: 5),
        AgentSettingSpec(key: "sound.quietHoursEnabled", category: "sound", kind: .bool, summary: "免打扰时段总开关", sample: true),
        AgentSettingSpec(key: "sound.quietStartHour", category: "sound", kind: .int(range: 0...23), summary: "免打扰起始小时", sample: 22),
        AgentSettingSpec(key: "sound.quietEndHour", category: "sound", kind: .int(range: 0...23), summary: "免打扰结束小时", sample: 8),
        // 语音播报
        AgentSettingSpec(key: "voice.mode", category: "voice", kind: .option(cases: voiceModes), summary: "语音播报模式（none=不播）", sample: "none"),
        AgentSettingSpec(key: "voice.templateText", category: "voice", kind: .text(maxLength: 500), summary: "播报文案模板", sample: "{project_name} 完成"),
        AgentSettingSpec(key: "voice.volume", category: "voice", kind: .double(range: 0...1), summary: "TTS 音量", sample: 0.7),
        AgentSettingSpec(key: "voice.speechRate", category: "voice", kind: .int(range: 100...300), summary: "TTS 语速", sample: 180),
        AgentSettingSpec(key: "voice.llmMaxChars", category: "voice", kind: .int(range: 10...100), summary: "LLM 总结最大字数", sample: 30),
        // 输入气泡
        AgentSettingSpec(key: "bubble.enabled", category: "bubble", kind: .bool, summary: "输入气泡总开关", sample: true),
        AgentSettingSpec(key: "bubble.autoShowOnFocus", category: "bubble", kind: .bool, summary: "聚焦目标窗自动弹出", sample: true),
        AgentSettingSpec(key: "bubble.autoShowOnMoveToMain", category: "bubble", kind: .bool, summary: "窗到主屏自动弹出", sample: false),
        AgentSettingSpec(key: "bubble.autoHide", category: "bubble", kind: .bool, summary: "失焦自动隐藏", sample: true),
        AgentSettingSpec(key: "bubble.autoRestoreOnSubmit", category: "bubble", kind: .bool, summary: "提交后自动归位", sample: true),
        AgentSettingSpec(key: "bubble.submitOnEnter", category: "bubble", kind: .bool, summary: "回车提交", sample: true),
        AgentSettingSpec(key: "bubble.historyLimit", category: "bubble", kind: .int(range: 50...10000), summary: "历史上限条数", sample: 200),
        // 终端网格
        AgentSettingSpec(key: "grid.rows", category: "grid", kind: .int(range: 1...8), summary: "网格行数", sample: 2),
        AgentSettingSpec(key: "grid.cols", category: "grid", kind: .int(range: 1...8), summary: "网格列数", sample: 3),
        AgentSettingSpec(key: "grid.gap", category: "grid", kind: .double(range: 0...40), summary: "格间距 px", sample: 8),
        AgentSettingSpec(key: "grid.autoRestoreEnabled", category: "grid", kind: .bool, summary: "开机自动恢复网格", sample: false),
        // 屏幕序号浮层
        AgentSettingSpec(key: "overlay.enabled", category: "overlay", kind: .bool, summary: "屏幕序号角标显隐", sample: true),
        AgentSettingSpec(key: "overlay.position", category: "overlay", kind: .option(cases: overlayPositions), summary: "角标位置", sample: "topRight"),
        // 标题编辑
        AgentSettingSpec(key: "titleEditor.enabled", category: "title", kind: .bool, summary: "标题编辑总开关", sample: true),
        // Hook 触发（行为级；B192 变更留痕已在位）
        AgentSettingSpec(key: "hook.triggerOnStop", category: "hook", kind: .bool, summary: "Stop 完成拉主屏", sample: false),
        AgentSettingSpec(key: "hook.triggerOnSessionEnd", category: "hook", kind: .bool, summary: "SessionEnd 拉主屏", sample: false),
        AgentSettingSpec(key: "hook.autoRestoreOnPromptSubmit", category: "hook", kind: .bool, summary: "提交后归位", sample: true),
        AgentSettingSpec(key: "hook.notifyOnNotification", category: "hook", kind: .bool, summary: "等待输入系统通知", sample: true)
    ]

    static let writable: [String: AgentSettingSpec] = {
        Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0) })
    }()

    // MARK: 永久人属（读得到、改不了；POST 到这些键 = 403 settings_key_readonly）

    static let readonlyKeys: [String] = [
        "hotkey.main", "hotkey.bubble", "hotkey.layoutEnabled",
        "permissions.accessibility", "loginItem.enabled",
        "yabai.integration", "yabai.saAvailable",
        "hook.enabled", "hook.port", "hook.token", "hook.lanMode",
        "codex.installed", "mcp.registeredClaude", "mcp.registeredCodex",
        "agentAccess.enabled", "agentAccess.allowWindowOps",
        "agentAccess.allowCreateWindows", "agentAccess.allowSettingsWrite",
        "bubble.hotKey", "bubble.width", "bubble.height", "titleEditor.hotKeyEnabled",
        "sound.customSoundPath", "voice.llmApiBase", "voice.llmApiKey", "voice.llmModel"
    ]

    // MARK: 读全量（GET /api/v1/settings 的 data 段）

    static func readAll() -> [String: Any] {
        let sound = SoundManager.shared.preferences
        let voice = VoiceAnnouncementManager.shared.preferences
        let bubble = { () -> [String: Any] in
            [
                "enabled": InputBubblePreferences.isEnabled,
                "autoShowOnFocus": InputBubblePreferences.autoShowOnFocus,
                "autoShowOnMoveToMain": InputBubblePreferences.autoShowOnMoveToMain,
                "autoHide": InputBubblePreferences.autoHide,
                "autoRestoreOnSubmit": InputBubblePreferences.autoRestoreOnSubmit,
                "submitOnEnter": InputBubblePreferences.submitOnEnter,
                "historyLimit": InputBubblePreferences.historyLimit
            ]
        }()
        let data: [String: Any] = [
            "writable": specs.map { [
                "key": $0.key,
                "type": $0.kind.typeName,
                "category": $0.category,
                "summary": $0.summary
            ] },
            "readonly": readonlyKeys,
            "hook": [
                "triggerOnStop": ClaudeHookPreferences.triggerOnStop,
                "triggerOnSessionEnd": ClaudeHookPreferences.triggerOnSessionEnd,
                "autoRestoreOnPromptSubmit": ClaudeHookPreferences.autoRestoreOnPromptSubmit,
                "notifyOnNotification": ClaudeHookPreferences.notifyOnNotification
            ],
            "grid": [
                "rows": TerminalGridPreferences.rows,
                "cols": TerminalGridPreferences.cols,
                "autoRestoreEnabled": TerminalGridPreferences.autoRestoreEnabled
            ],
            "sound": [
                "soundType": sound.soundType.rawValue,
                "volume": sound.volume,
                "quietHoursEnabled": sound.quietHoursEnabled,
                "quietStartHour": sound.quietStartHour,
                "quietEndHour": sound.quietEndHour,
                "minPlayIntervalSeconds": sound.minPlayIntervalSeconds
            ],
            "voice": [
                "mode": voice.mode.rawValue,
                "templateText": voice.templateText,
                "volume": voice.volume,
                "speechRate": voice.speechRate,
                "llmMaxChars": voice.llmMaxChars
            ],
            "bubble": bubble,
            "overlayEnabled": ScreenOverlayManager.shared.preferences.isEnabled
        ]
        return data
    }

    // MARK: 应用（写侧唯一入口；返回 nil=成功，否则失败原因）

    static func apply(key: String, raw: Any) -> String? {
        guard let spec = writable[key] else {
            return readonlyKeys.contains(key) ? "settings_key_readonly" : "settings_key_unknown"
        }
        guard AgentSettingsValidator.validate(kind: spec.kind, raw: raw) == .ok else {
            return "settings_value_invalid"
        }
        switch key {
        // 提示音
        case "sound.type":
            SoundManager.shared.updateSoundType(CompletionSoundType(rawValue: raw as! String)!)
        case "sound.volume":
            SoundManager.shared.updateVolume(Float(truncating: raw as! NSNumber))
        case "sound.minPlayIntervalSeconds":
            SoundManager.shared.updateMinPlayInterval(raw as! Int)
        case "sound.quietHoursEnabled":
            SoundManager.shared.updateQuietHours(enabled: raw as! Bool, startHour: SoundManager.shared.preferences.quietStartHour, endHour: SoundManager.shared.preferences.quietEndHour)
        case "sound.quietStartHour":
            SoundManager.shared.updateQuietHours(enabled: SoundManager.shared.preferences.quietHoursEnabled, startHour: raw as! Int, endHour: SoundManager.shared.preferences.quietEndHour)
        case "sound.quietEndHour":
            SoundManager.shared.updateQuietHours(enabled: SoundManager.shared.preferences.quietHoursEnabled, startHour: SoundManager.shared.preferences.quietStartHour, endHour: raw as! Int)
        // 语音
        case "voice.mode":
            VoiceAnnouncementManager.shared.updateMode(VoiceAnnouncementMode(rawValue: raw as! String)!)
        case "voice.templateText":
            VoiceAnnouncementManager.shared.updateTemplateText(raw as! String)
        case "voice.volume":
            VoiceAnnouncementManager.shared.updateVolume(Float(truncating: raw as! NSNumber))
        case "voice.speechRate":
            VoiceAnnouncementManager.shared.updateSpeechRate(Float(truncating: raw as! NSNumber))
        case "voice.llmMaxChars":
            VoiceAnnouncementManager.shared.updateLLMMaxChars(raw as! Int)
        // 气泡
        case "bubble.enabled": InputBubblePreferences.isEnabled = raw as! Bool
        case "bubble.autoShowOnFocus": InputBubblePreferences.autoShowOnFocus = raw as! Bool
        case "bubble.autoShowOnMoveToMain": InputBubblePreferences.autoShowOnMoveToMain = raw as! Bool
        case "bubble.autoHide": InputBubblePreferences.autoHide = raw as! Bool
        case "bubble.autoRestoreOnSubmit": InputBubblePreferences.autoRestoreOnSubmit = raw as! Bool
        case "bubble.submitOnEnter": InputBubblePreferences.submitOnEnter = raw as! Bool
        case "bubble.historyLimit": InputBubblePreferences.historyLimit = raw as! Int
        // 网格
        case "grid.rows": TerminalGridPreferences.rows = raw as! Int
        case "grid.cols": TerminalGridPreferences.cols = raw as! Int
        case "grid.gap": TerminalGridPreferences.gap = Double(truncating: raw as! NSNumber)
        case "grid.autoRestoreEnabled": TerminalGridPreferences.autoRestoreEnabled = raw as! Bool
        // 浮层
        case "overlay.enabled": ScreenOverlayManager.shared.setEnabled(raw as! Bool)
        case "overlay.position":
            if let pos = IndexPosition(rawValue: raw as! String) {
                ScreenOverlayManager.shared.updatePosition(pos)
            }
        // 标题编辑
        case "titleEditor.enabled": TitleEditorPreferences.isEnabled = raw as! Bool
        // Hook 触发（各自带变更留痕）
        case "hook.triggerOnStop": ClaudeHookPreferences.triggerOnStop = raw as! Bool
        case "hook.triggerOnSessionEnd": ClaudeHookPreferences.triggerOnSessionEnd = raw as! Bool
        case "hook.autoRestoreOnPromptSubmit": ClaudeHookPreferences.autoRestoreOnPromptSubmit = raw as! Bool
        case "hook.notifyOnNotification": ClaudeHookPreferences.notifyOnNotification = raw as! Bool
        default:
            return "settings_key_unknown"
        }
        // 统一留痕：agent 触发的设置变更落 INFO 行（可日志考古归因）
        log("[AgentSettings] setting changed by agent", level: .info, fields: [
            "key": key,
            "value": "\(raw)"
        ])
        return nil
    }
}
