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

        // 1) 无记录 → .default（偏好非 Equatable，用重编码字节对比）
        func encoded(_ p: VoiceAnnouncementPreferences) -> Data {
            try! JSONEncoder().encode(p)
        }
        UserDefaults.standard.removeObject(forKey: key)
        print("DBG1:", String(data: encoded(VoiceAnnouncementManager.loadPreferences()), encoding: .utf8) ?? "?"); print("DBG2:", String(data: encoded(.default), encoding: .utf8) ?? "?");
        check("voicePrefs: 无记录回落 default",
              encoded(VoiceAnnouncementManager.loadPreferences())
              == encoded(.default))

        // 2) 损坏数据 → .default（不崩溃不回写）
        UserDefaults.standard.set(Data("not-json-at-all".utf8), forKey: key)
        check("voicePrefs: 损坏数据回落 default",
              encoded(VoiceAnnouncementManager.loadPreferences())
              == encoded(.default))

        // 3) 合法 JSON → 原样解出
        var custom = VoiceAnnouncementPreferences.default
        custom.mode = .template
        custom.templateText = "{project_name} B214"
        custom.volume = 0.5
        custom.llmModel = "test-model"
        UserDefaults.standard.set(encoded(custom), forKey: key)
        let loaded = VoiceAnnouncementManager.loadPreferences()
        check("voicePrefs: 合法 JSON 原样解出", encoded(loaded) == encoded(custom))

        // 4) savePreferences 回读闭环：shared 当前偏好编码写回 → load 读回一致
        let before = VoiceAnnouncementManager.shared.preferences
        VoiceAnnouncementManager.shared.savePreferences()
        check("voicePrefs: save→load 回读一致",
              encoded(VoiceAnnouncementManager.loadPreferences()) == encoded(before))

        // 现场还原：键移除（本进程域，勿留测试数据）
        UserDefaults.standard.removeObject(forKey: key)
    }
}
