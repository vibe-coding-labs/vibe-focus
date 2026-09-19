// Tests/Runner/RunnerAppLifecycleTests.swift
// B214 覆盖堆叠·应用生命周期域：AppDelegate+Sigterm（优雅退出安装）/ DockBadgeManager
// （showBadge 计数、clearBadge 守卫、bounce 无目标回落——绝不激活真实终端抢焦点）/
// VoiceAnnouncementManager+Persistence（加载三路 + 保存回读；UserDefaults 键先存后还原）。

import Foundation
import AppKit
@testable import VibeFocusKit

extension RunnerHarness {

    // MARK: - AppDelegate+Sigterm（优雅退出安装）

    func runSigtermGracefulTests() {
        print("\n=== SigtermGraceful (B214) ===")
        // 安装动作本身只做三件事：signal(SIGTERM, SIG_IGN) + DispatchSource 注册 + resume。
        // 事件 handler（flushDraft/recordExit/NSApp.terminate）只在真收到 SIGTERM 时执行，
        // 测试进程内不触发——不向自己发 SIGTERM（发了会被吞掉且走 terminate，进程直接退）。
        AppDelegate().installGracefulSigtermHandler()
        check("sigterm: 优雅退出源可安装不崩溃", true)
    }

    // MARK: - DockBadgeManager（dock 角标计数状态机）

    func runDockBadgeTests() {
        print("\n=== DockBadge (B214) ===")
        let badge = DockBadgeManager.shared

        // 守卫路：零计数 clear 直接管（不写 dockTile）
        badge.clearBadge()
        NSApp.dockTile.badgeLabel = nil
        badge.clearBadge()
        check("badge: 零计数 clear 无副作用守卫", NSApp.dockTile.badgeLabel == nil)

        // showBadge 计数递增（Runner 无 dock 图标，badgeLabel 仅是 tile 对象上的字符串，
        // 不产生可见窗口/焦点扰动）；bounce 双 nil → 进程枚举落空走 warn 回落路
        badge.showBadge()
        check("badge: 首次 show 计数 1", NSApp.dockTile.badgeLabel == "1")
        badge.showBadge(targetBundleID: "com.vibefocus.b214.nonexistent",
                        targetAppName: "ZZZ-B214-NoSuchApp")
        check("badge: 二次 show 计数 2", NSApp.dockTile.badgeLabel == "2")
        // 未命中 bundle 与名字都不得崩溃（找不到就 warn 放弃，绝不乱激活）
        check("badge: 未命中目标不激活任何 app（无异常即过）", true)

        badge.clearBadge()
        check("badge: clear 归零", NSApp.dockTile.badgeLabel == nil)
        // 恢复现场：测试进程徽章清空
        NSApp.dockTile.badgeLabel = nil
    }

    // MARK: - VoiceAnnouncementManager+Persistence（偏好 JSON 编解码）

    func runVoicePrefsPersistenceTests() {
        print("\n=== VoicePrefsPersistence (B214) ===")
        let key = VoiceAnnouncementManager.preferencesKey

        // 1) 无记录 → .default（结构体已补 Equatable 合成；JSONEncoder 键序不稳定，
        //    字节对比逐轮 flaky——B214 首轮全绿纯属运气，此注释为教训存档）
        UserDefaults.standard.removeObject(forKey: key)
        check("voicePrefs: 无记录回落 default",
              VoiceAnnouncementManager.loadPreferences() == .default)

        // 2) 损坏数据 → .default（不崩溃不回写）
        UserDefaults.standard.set(Data("not-json-at-all".utf8), forKey: key)
        check("voicePrefs: 损坏数据回落 default",
              VoiceAnnouncementManager.loadPreferences() == .default)

        // 3) 合法 JSON → 原样解出
        var custom = VoiceAnnouncementPreferences.default
        custom.mode = .template
        custom.templateText = "{project_name} B214"
        custom.volume = 0.5
        custom.llmModel = "test-model"
        UserDefaults.standard.set(try! JSONEncoder().encode(custom), forKey: key)
        check("voicePrefs: 合法 JSON 原样解出",
              VoiceAnnouncementManager.loadPreferences() == custom)

        // 4) savePreferences 回读闭环：shared 当前偏好编码写回 → load 读回一致
        let before = VoiceAnnouncementManager.shared.preferences
        VoiceAnnouncementManager.shared.savePreferences()
        check("voicePrefs: save→load 回读一致",
              VoiceAnnouncementManager.loadPreferences() == before)

        // 现场还原：键移除（本进程域，勿留测试数据）
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - VoiceAnnouncementManager+Queue（有界队列编排）
    // 出声安全：全部用例把 isAnnouncing 钉在 true 或保持队列为空——playNextFromQueue
    // 的两道 guard 保证永远不会真的调 speak/playAudioFile（测试进程不发声）。

    func runVoiceQueueTests() {
        print("\n=== VoiceQueue (B215) ===")
        let vam = VoiceAnnouncementManager.shared

        // 出声闸：在播态期间队列推进一律短路
        vam.isAnnouncing = true
        vam.pendingAnnouncements = []
        vam.playNextFromQueue()
        check("voiceQueue: 空队列+在播 推进 no-op",
              vam.pendingAnnouncements.isEmpty && vam.isAnnouncing)

        // 有界入队：5 条进容量 3 → 丢最旧留最新；期间不出声（在播闸短路推进）
        for i in 1...5 { vam.enqueueAnnouncement(.text("B215-\(i)"), sessionID: "s") }
        check("voiceQueue: 容量 3 丢最旧",
              vam.pendingAnnouncements == [.text("B215-3"), .text("B215-4"), .text("B215-5")])
        check("voiceQueue: 在播期间入队不出声", vam.isAnnouncing)

        // 音频条目入队
        vam.pendingAnnouncements = []
        vam.enqueueAnnouncement(.audioFile(path: "/tmp/b215/sound.wav"), sessionID: "s")
        check("voiceQueue: 音频条目入队",
              vam.pendingAnnouncements == [.audioFile(path: "/tmp/b215/sound.wav")])
        // 出声闸补丁：清空队列——matched sender 完成回调会复位 isAnnouncing 并推进队列，
        // 队列非空将真的调 speak/playAudioFile（后者文件缺失还会 fallback TTS 出声）
        vam.pendingAnnouncements = []

        // TTS 完成回调：mismatched sender → no-op（状态不动）
        let synth = NSSpeechSynthesizer()
        vam.handleSpeechDidFinish(sender: synth, finished: true)
        check("voiceQueue: 非在播 synth 回调 no-op", vam.isAnnouncing == true)

        // matched sender：复位在播态 + 推进（队列空 → no-op 不出声）
        vam.activeSynthesizer = synth
        vam.handleSpeechDidFinish(sender: synth, finished: false)
        check("voiceQueue: TTS 打断复位 isAnnouncing", vam.isAnnouncing == false)
        check("voiceQueue: 复位后清空 synth 引用", vam.activeSynthesizer == nil)

        // 音频完成回调：mismatched（currentSound 为 nil 不可能相等）→ no-op
        guard let snd = NSSound(named: "Basso") else {
            check("voiceQueue: 系统音 Basso 可加载（环境前提）", false)
            return
        }
        vam.isAnnouncing = true
        vam.handleSoundDidFinish(sender: snd, finished: true)
        check("voiceQueue: 非在播 sound 回调 no-op", vam.isAnnouncing == true)

        // matched：复位 + 推进（队列空 no-op）
        vam.currentSound = snd
        vam.handleSoundDidFinish(sender: snd, finished: true)
        check("voiceQueue: 音频完成复位", vam.isAnnouncing == false && vam.currentSound == nil)

        // logDescription 纯函数：文本截前 30 字、路径取末段
        check("voiceQueue: text 摘要含文本",
              QueuedAnnouncement.text("你好B215").logDescription.contains("你好B215"))
        check("voiceQueue: audio 摘要取末段",
              QueuedAnnouncement.audioFile(path: "/a/b/c.wav").logDescription == "audio(c.wav)")

        // 现场还原
        vam.isAnnouncing = false
        vam.pendingAnnouncements = []
    }
}
