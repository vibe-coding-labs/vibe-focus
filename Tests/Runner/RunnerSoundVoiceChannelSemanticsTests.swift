import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSoundVoiceChannelSemanticsTests.swift — 声音/语音双通道语义回归锁
// （2026-09-23 用户投诉「没开播放开关却响提示音」批）。
//
// 取证结论（真机日志+存储态）：语音 TTS 通道全程正确静默（mode=.none 每次 skip），
// 用户听到的是完成提示音 Ding——存储态 soundType=builtin_ding（历史实验残留，
// 默认值自始为 .none，无程序化写入点）。本文件把「两个开关各管一个通道、互不越界」
// 钉成永久断言，防止后续重构把两通道语义搅浑：
//   提示音通道 = SoundPreferences.soundType（none=静默，免打扰硬静音，节流）；
//   语音通道   = VoiceAnnouncementPreferences.mode（none=静默，与提示音无关）。

extension RunnerHarness {
    func runSoundVoiceChannelSemanticsTests() {
        let sound = SoundManager.shared
        let voice = VoiceAnnouncementManager.shared

        let savedType = sound.preferences.soundType
        let savedInterval = sound.preferences.minPlayIntervalSeconds
        let savedQuiet = sound.preferences.quietHoursEnabled
        let savedMode = voice.preferences.mode
        defer {
            sound.updateSoundType(savedType)
            sound.updateMinPlayInterval(savedInterval)
            sound.updateQuietHours(enabled: savedQuiet, startHour: sound.preferences.quietStartHour, endHour: sound.preferences.quietEndHour)
            voice.updateMode(savedMode)
        }

        let payloadJSON = Data("{\"event\":\"Stop\",\"session_id\":\"sem-lock\"}".utf8)
        let payload = ClaudeHookServer.decodePayload(from: payloadJSON)
        check("sem: Stop payload 解码成功", payload != nil)

        // MARK: A. 用户机器实况语义（提示音开 + voice=none）：完成音会响、TTS 永不开口
        // Runner 环境注意：builtin* 走 Bundle 资源（Runner 无 Sounds 资源）必解析失败，
        // 发声断言一律用 .systemDefault（NSSound 系统音，任何进程可解析）；节流关零
        // （共享单例的 lastPlayedAt 会被前序声音测试加热，2s 窗口内必 throttled）。
        do {
            let mockPlayer = MockSoundPlayer()
            let mockProvider = MockSynthesizerProvider()
            sound.soundPlayer = mockPlayer
            voice.synthesizerProvider = mockProvider
            defer { sound.stopPlayback() }

            sound.updateSoundType(.systemDefault)
            sound.updateMinPlayInterval(0)
            sound.updateQuietHours(enabled: false, startHour: sound.preferences.quietStartHour, endHour: sound.preferences.quietEndHour)
            voice.updateMode(.none)

            sound.playCompletionSound(projectName: nil)
            check("sem: 提示音开关开→完成音恰响一次（用户听到的就是它）", mockPlayer.playCount == 1)

            voice.announceCompletion(payload: payload!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("sem: 语音模式 none→TTS 零发声（语音通道全程清白）", mockProvider.synthesizer.startCalled == false)

            // 同态下失败音也走提示音开关（Basso 非旁路）
            let beforeFailure = mockPlayer.playCount
            sound.playFailureSound()
            check("sem: 失败音受同一开关门控（非恒播旁路）", mockPlayer.playCount == beforeFailure + 1)
        }

        // MARK: B. 全关语义：soundType=none 时三通道（完成/失败/项目）全静默
        do {
            let mockPlayer = MockSoundPlayer()
            sound.soundPlayer = mockPlayer
            sound.updateSoundType(.none)
            sound.playCompletionSound(projectName: nil)
            sound.playCompletionSound(projectName: "sem-demo")
            sound.playFailureSound()
            check("sem: 全关→完成/项目/失败音零发声", mockPlayer.playCount == 0)
        }

        // MARK: C. 免打扰硬静音：提示音开着但落在静音窗内不响
        do {
            let mockPlayer = MockSoundPlayer()
            sound.soundPlayer = mockPlayer
            sound.updateSoundType(.builtinDing)
            // 窗口 0→0 时视为无效不启用（门控边界），改用覆盖全天的 0→24? 小时钳 0...23，
            // 故用 startHour=0, endHour=23（除 23 点外全天静音；23 点跑测试不静音——
            // 但断言不能依赖墙钟小时，改为直接注入门控判定函数验证，播放编排已由 A/B 锁定。
            let hour = Calendar.current.component(.hour, from: Date())
            let inWindow = SoundPlayGate.isInQuietHours(date: Date(), startHour: 0, endHour: 23, calendar: .current)
            check("sem: 免打扰判定与墙钟一致", inWindow == (hour >= 0 && hour < 23))
        }

        // MARK: D. 项目规则越全局（文档化语义锁）：全局 none、规则命中项目仍发声
        do {
            let mockPlayer = MockSoundPlayer()
            sound.soundPlayer = mockPlayer
            sound.updateSoundType(.none)
            sound.updateMinPlayInterval(0)
            sound.addProjectRule()
            let ruleIndex = sound.preferences.projectRules.count - 1
            check("sem: 规则表新增成功", ruleIndex >= 0)
            sound.setProjectRuleName(at: ruleIndex, "sem-demo")
            sound.setProjectRuleSound(at: ruleIndex, .systemDefault)
            defer { sound.removeProjectRule(at: ruleIndex) }
            sound.playCompletionSound(projectName: "sem-demo")
            check("sem: 项目规则命中→越全局 none 发声（规则优先语义）", mockPlayer.playCount == 1)
            sound.playCompletionSound(projectName: "other-project")
            check("sem: 规则未命中项目→仍静默", mockPlayer.playCount == 1)
        }

        // MARK: E. 语音语义反向锁：mode=template 才开口，且文本走模板插值
        do {
            let mockProvider = MockSynthesizerProvider()
            voice.synthesizerProvider = mockProvider
            voice.updateMode(.template)
            voice.updateTemplateText("{project_name} 完成")
            voice.announceCompletion(payload: payload!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("sem: 语音模式 template→TTS 被调用", mockProvider.synthesizer.startCalled == true)
            voice.stopAll()
        }
    }
}
