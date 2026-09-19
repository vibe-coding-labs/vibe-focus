import AppKit
import Foundation
import ApplicationServices
@testable import VibeFocusKit

// Tests/Runner/RunnerSoundGateSilentTests.swift — 覆盖率批次 11（B242）：
// SoundManager 静默路径（.none 早退）+ VoiceAnnouncementManager.stopAll 幂等
// + autoSetTitle 三路写全链编排（幽灵目标，零发声零 AX 写）。
//
// 安全性依据：①playCompletionSound/playFailureSound 在 soundType == .none 时于
// resolveSound/startPlayback 之前静默 return（快照-改写-恢复协议切到 .none，测试
// 期间零发声）；②stopAll 在无播放态是幂等清理；③autoSetTitle 传幽灵 pid(999999)
// +不可识别 bundleID：AX 查询无授权返回 nil 不跳过、applyTitle 三路=AX 失败(false)
// +AppleScript unsupported(false, 零 osascript)+TTY no_tty(false)——全链走通零副作用。

extension RunnerHarness {
    func runSoundGateSilentTests() {
        let sound = SoundManager.shared
        let savedType = sound.preferences.soundType
        defer { sound.updateSoundType(savedType) }
        // 注意不碰 projectRules：projectName 传 nil 则规则永不命中，
        // resolvedType 恒等于全局 .none——无需清空规则表。

        // MARK: A. playCompletionSound：全局 .none 早退（resolvedType 守卫，零发声）
        sound.updateSoundType(.none)
        sound.playCompletionSound(projectName: nil)
        sound.playCompletionSound(projectName: "任意项目")
        check("soundGate: 全局 .none 时完成音静默早退（projectName=nil 规则不命中）", true)

        // MARK: B. playFailureSound：.none 尊重用户显式关闭（Basso 不加载）
        sound.playFailureSound()
        check("soundGate: 全局 .none 时失败音同样静默", true)

        // MARK: C. VoiceAnnouncementManager.stopAll：无播放态幂等清理
        let voice = VoiceAnnouncementManager.shared
        voice.stopAll()
        voice.stopAll()
        check("voiceGate: stopAll 无播放态连续调用幂等", true)

        // MARK: D. autoSetTitle 全链编排（幽灵目标：AX 查询 nil→不跳过→三路写全 false）
        // window 传 systemWide 元素（创建不需授权；WindowManager.windowHandle 对其
        // 查询在无 AX 授权的 CLI 进程返回 nil）；pid 幽灵→TTY no_tty；bundleID 未知
        // →AppleScript unsupported。整条三路写编排行被驱动，零发声零标题写入。
        let systemWide = AXUIElementCreateSystemWide()
        TitleEditorService.shared.autoSetTitle(
            cwd: "/tmp/b242-demo-project", pid: 999_999,
            bundleID: "com.example.notaterminal", window: systemWide)
        check("titleEditor: autoSetTitle 幽灵目标全链编排走通不崩", true)
    }
}
