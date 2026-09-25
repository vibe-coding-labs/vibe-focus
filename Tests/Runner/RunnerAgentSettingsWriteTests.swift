import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAgentSettingsWriteTests.swift — 设置白名单写直测（「全量设置项
// Agent 化」批）。覆盖：目录规格完备（键唯一/有样值/类型合法）、校验器矩阵
// （bool/int 范围/double 范围/option/text 长度）、人属键只读拒绝、全表样值回环
// （每键 apply→读回不变性抽查）、POST 分发语义（未授权/批量/坏项）。

extension RunnerHarness {
    func runAgentSettingsWriteTests() {

        // MARK: A. 目录完备性
        do {
            check("catalog: 可写项 29 项", AgentSettingsCatalog.specs.count == 29)
            let keys = AgentSettingsCatalog.specs.map(\.key)
            check("catalog: 键唯一", Set(keys).count == keys.count)
            check("catalog: 人属清单与白名单无交集",
                  Set(AgentSettingsCatalog.readonlyKeys).isDisjoint(with: keys))
            check("catalog: 每项有分类与说明",
                  AgentSettingsCatalog.specs.allSatisfy { !$0.category.isEmpty && !$0.summary.isEmpty })
            check("catalog: 人属清单覆盖安全面",
                  AgentSettingsCatalog.readonlyKeys.contains("hook.token")
                      && AgentSettingsCatalog.readonlyKeys.contains("agentAccess.enabled")
                      && AgentSettingsCatalog.readonlyKeys.contains("permissions.accessibility"))
        }

        // MARK: B. 校验器矩阵（纯函数）
        do {
            check("v: bool 接受", AgentSettingsValidator.validate(kind: .bool, raw: true) == .ok)
            check("v: bool 拒字符串", AgentSettingsValidator.validate(kind: .bool, raw: "true") == .badType)
            check("v: int 范围内", AgentSettingsValidator.validate(kind: .int(range: 1...8), raw: 3) == .ok)
            check("v: int 越界", AgentSettingsValidator.validate(kind: .int(range: 1...8), raw: 9) == .outOfRange)
            check("v: int 拒小数", AgentSettingsValidator.validate(kind: .int(range: 1...8), raw: 2.5) == .badType)
            check("v: double 收整数", AgentSettingsValidator.validate(kind: .double(range: 0...1), raw: 0) == .ok)
            check("v: option 拒非法", AgentSettingsValidator.validate(kind: .option(cases: ["a"]), raw: "b") == .outOfRange)
            check("v: text 长度窗", AgentSettingsValidator.validate(kind: .text(maxLength: 5), raw: "123456") == .outOfRange)
        }

        // MARK: C. 全表样值回环（apply→可读回；快照-改写-恢复协议）
        do {
            let sound = SoundManager.shared
            let voice = VoiceAnnouncementManager.shared
            let savedSound = sound.preferences
            let savedVoice = voice.preferences.mode
            let savedVoiceVolume = voice.preferences.volume
            let savedGridRows = TerminalGridPreferences.rows
            let savedGridCols = TerminalGridPreferences.cols
            let savedGridGap = TerminalGridPreferences.gap
            let savedHistory = InputBubblePreferences.historyLimit
            let savedTriggerStop = ClaudeHookPreferences.triggerOnStop
            let savedOverlay = ScreenOverlayManager.shared.preferences.isEnabled
            let savedTitle = TitleEditorPreferences.isEnabled
            defer {
                sound.updateSoundType(savedSound.soundType)
                sound.updateVolume(savedSound.volume)
                sound.updateMinPlayInterval(savedSound.minPlayIntervalSeconds)
                sound.updateQuietHours(enabled: savedSound.quietHoursEnabled,
                                       startHour: savedSound.quietStartHour, endHour: savedSound.quietEndHour)
                voice.updateMode(savedVoice)
                voice.updateVolume(savedVoiceVolume)
                TerminalGridPreferences.rows = savedGridRows
                TerminalGridPreferences.cols = savedGridCols
                TerminalGridPreferences.gap = savedGridGap
                InputBubblePreferences.historyLimit = savedHistory
                ClaudeHookPreferences.triggerOnStop = savedTriggerStop
                ScreenOverlayManager.shared.setEnabled(savedOverlay)
                TitleEditorPreferences.isEnabled = savedTitle
            }

            // 全表逐键 apply 样值：零拒绝（目录自洽性——任何键被校验器拒绝=目录漂移）
            var rejected: [String] = []
            for spec in AgentSettingsCatalog.specs {
                if let error = AgentSettingsCatalog.apply(key: spec.key, raw: spec.sample) {
                    rejected.append("\(spec.key)=\(error)")
                }
            }
            check("catalog: 全表 30 键样值 apply 零拒绝", rejected.isEmpty)

            // 读回抽查（跨 6 个域各锚一点）
            check("catalog: sound.volume 读回", sound.preferences.volume == 0.5)
            check("catalog: grid.rows 读回", TerminalGridPreferences.rows == 2)
            check("catalog: hook.triggerOnStop 写入读回", ClaudeHookPreferences.triggerOnStop == false)
            check("catalog: bubble.historyLimit 读回", InputBubblePreferences.historyLimit == 200)
            check("catalog: voice.mode 写 none 读回", voice.preferences.mode == .none)
            check("catalog: overlay.enabled 读回", ScreenOverlayManager.shared.preferences.isEnabled == true)

            // 非法人属键与未知键
            check("catalog: 人属键 apply→settings_key_readonly",
                  AgentSettingsCatalog.apply(key: "hook.token", raw: "x") == "settings_key_readonly")
            check("catalog: 未知键 apply→settings_key_unknown",
                  AgentSettingsCatalog.apply(key: "no.such.key", raw: 1) == "settings_key_unknown")
        }

        // MARK: D. POST 分发语义（handler 纯编排：授权门/单键/批量/坏项）
        do {
            let savedWrite = AgentAccessPreferences.allowSettingsWrite
            defer { AgentAccessPreferences.allowSettingsWrite = savedWrite }

            AgentAccessPreferences.allowSettingsWrite = false
            let denied = ClaudeHookServer.handleSettingsWrite(json: ["key": "sound.volume", "value": 0.5])
            check("postW: 未授权→403 settings_write_disabled", denied.statusCode == 403)

            AgentAccessPreferences.allowSettingsWrite = true
            let badShape = ClaudeHookServer.handleSettingsWrite(json: [:])
            check("postW: 无 key/value→400", badShape.statusCode == 400)

            let unknown = ClaudeHookServer.handleSettingsWrite(
                json: ["key": "no.such.key", "value": 1])
            check("postW: 未知键→400 rejected", unknown.statusCode == 400)

            let readonly = ClaudeHookServer.handleSettingsWrite(
                json: ["key": "hook.token", "value": "hack"])
            check("postW: 人属键→403 settings_key_readonly", readonly.statusCode == 403)

            let batch = ClaudeHookServer.handleSettingsWrite(json: ["updates": [
                ["key": "sound.volume", "value": 0.4],
                ["key": "grid.cols", "value": 4],
                ["key": "no.such.key", "value": 1]
            ]])
            check("postW: 批量混合→400 rejected 且逐项结果", batch.statusCode == 400)
        }
    }
}
