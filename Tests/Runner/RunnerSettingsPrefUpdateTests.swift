import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsPrefUpdateTests.swift — 覆盖率批次 8（B238）：
// VoiceAnnouncementManager / SoundManager 的 update* 偏好转发族 + ScreenMinimapView 求值。
//
// update* 族语义=「preferences 属性写 → didSet → 持久化+广播」，零音频/零网络副作用
// （发声口 speak/playAudioFile/previewSound 诚实留白），测试走快照-改写-恢复协议：
// 改前快照 manager.preferences 全字段，改后逐字段写回，不污染跨测试偏好语义。
// ScreenMinimapView 零单例零 EnvironmentObject，init+body 顶层（GeometryReader 包装）
// 可求值；ForEach/screenView 内层属渲染期，留白。

extension RunnerHarness {
    func runSettingsPrefUpdateTests() {
        // MARK: A. VoiceAnnouncementManager 偏好转发族
        let voice = VoiceAnnouncementManager.shared
        let savedVoice = (
            mode: voice.preferences.mode,
            templateText: voice.preferences.templateText,
            audioFilePath: voice.preferences.audioFilePath,
            volume: voice.preferences.volume,
            speechRate: voice.preferences.speechRate,
            llmApiBase: voice.preferences.llmApiBase,
            llmApiKey: voice.preferences.llmApiKey,
            llmModel: voice.preferences.llmModel,
            llmMaxChars: voice.preferences.llmMaxChars
        )
        // preferences 为 private(set)：恢复一律走 update 转发（与被测通道同路）。
        defer {
            voice.updateMode(savedVoice.mode)
            voice.updateTemplateText(savedVoice.templateText)
            voice.updateAudioFilePath(savedVoice.audioFilePath)
            voice.updateVolume(savedVoice.volume)
            voice.updateSpeechRate(savedVoice.speechRate)
            voice.updateLLMApiBase(savedVoice.llmApiBase)
            voice.updateLLMApiKey(savedVoice.llmApiKey)
            voice.updateLLMModel(savedVoice.llmModel)
            voice.updateLLMMaxChars(savedVoice.llmMaxChars)
        }

        voice.updateMode(.llmSummary)
        voice.updateTemplateText("任务完成：{content}")
        voice.updateAudioFilePath("/tmp/b238-voice.wav")
        voice.updateVolume(0.7)
        voice.updateSpeechRate(180)
        voice.updateLLMApiBase("http://127.0.0.1:9")
        voice.updateLLMApiKey("b238-key")
        voice.updateLLMModel("b238-model")
        voice.updateLLMMaxChars(88)
        check("voicePrefs: 九个 update 转发全部落账（didSet 持久化通道）",
              voice.preferences.mode == .llmSummary
              && voice.preferences.templateText == "任务完成：{content}"
              && voice.preferences.audioFilePath == "/tmp/b238-voice.wav"
              && abs(voice.preferences.volume - 0.7) < 1e-6
              && abs(voice.preferences.speechRate - 180) < 1e-6
              && voice.preferences.llmApiBase == "http://127.0.0.1:9"
              && voice.preferences.llmApiKey == "b238-key"
              && voice.preferences.llmModel == "b238-model"
              && voice.preferences.llmMaxChars == 88)
        voice.updateAudioFilePath(nil)
        check("voicePrefs: 清空音频路径（nil 覆盖）", voice.preferences.audioFilePath == nil)

        // MARK: B. SoundManager 偏好转发族 + 项目规则 CRUD
        let sound = SoundManager.shared
        let savedSoundType = sound.preferences.soundType
        let savedCustomPath = sound.preferences.customSoundPath
        let savedVolume = sound.preferences.volume
        let savedMinInterval = sound.preferences.minPlayIntervalSeconds
        let savedQuietEnabled = sound.preferences.quietHoursEnabled
        let savedQuietStart = sound.preferences.quietStartHour
        let savedQuietEnd = sound.preferences.quietEndHour
        // projectRules 在测试内自还原（add 后 remove 同一条）；其余走 update 转发恢复。
        defer {
            sound.updateSoundType(savedSoundType)
            sound.updateCustomSoundPath(savedCustomPath)
            sound.updateVolume(savedVolume)
            sound.updateMinPlayInterval(savedMinInterval)
            sound.updateQuietHours(enabled: savedQuietEnabled,
                                   startHour: savedQuietStart,
                                   endHour: savedQuietEnd)
        }

        sound.updateSoundType(.builtinDing)
        sound.updateCustomSoundPath("/tmp/b238-sound.wav")
        sound.updateVolume(0.4)
        sound.updateMinPlayInterval(30)
        sound.updateQuietHours(enabled: true, startHour: 22, endHour: 8)
        check("soundPrefs: 五个 update 转发落账（节流钳制/免打扰小时钳 0~23）",
              sound.preferences.soundType == .builtinDing
              && sound.preferences.customSoundPath == "/tmp/b238-sound.wav"
              && abs(sound.preferences.volume - 0.4) < 1e-6
              && sound.preferences.minPlayIntervalSeconds == 30
              && sound.preferences.quietHoursEnabled
              && sound.preferences.quietStartHour == 22
              && sound.preferences.quietEndHour == 8)

        let initialRuleCount = sound.preferences.projectRules.count
        sound.addProjectRule()
        sound.setProjectRuleName(at: initialRuleCount, "b238-project")
        sound.setProjectRuleSound(at: initialRuleCount, .builtinPing)
        check("soundPrefs: 项目规则增-改名-改音",
              sound.preferences.projectRules.count == initialRuleCount + 1
              && sound.preferences.projectRules.last?.projectName == "b238-project"
              && sound.preferences.projectRules.last?.soundRawValue == CompletionSoundType.builtinPing.rawValue)
        sound.removeProjectRule(at: initialRuleCount)
        check("soundPrefs: 项目规则删除还原数量",
              sound.preferences.projectRules.count == initialRuleCount)

        // MARK: C. ScreenMinimapView（零单例零环境对象；双屏样例布局）
        let screens: [ScreenLayoutMapper.InputScreen] = [
            ScreenLayoutMapper.InputScreen(
                displayID: 1, name: "Built-in",
                cocoaFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isMain: true,
                spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true)],
                yabaiDisplayIndex: 1),
            ScreenLayoutMapper.InputScreen(
                displayID: 2, name: "P40UG",
                cocoaFrame: CGRect(x: 0, y: 1117, width: 3440, height: 1440), isMain: false,
                spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true),
                         ScreenLayoutMapper.InputSpace(yabaiIndex: 2, isVisible: false)],
                yabaiDisplayIndex: 2)
        ]
        let minimapDefault = ScreenMinimapView(
            screens: screens, selected: nil, gridPreviewRows: 3, gridPreviewCols: 4,
            height: 216, onSelect: { _ in })
        let minimapSelected = ScreenMinimapView(
            screens: screens, selected: .displaySpace(displayID: 2, spaceIndex: 2),
            gridPreviewRows: 2, gridPreviewCols: 3, height: 120, onSelect: { _ in })
        check("minimap: 双态实例构建不崩（默认高/选中态小高）", true)
        let _ = minimapDefault.body
        let _ = minimapSelected.body
        check("minimap: body（GeometryReader 包装）求值无异常", true)
    }
}
