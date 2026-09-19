import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerLANSettingsViewTests.swift — 覆盖率批次 2（B215）：LAN 设置视图 body 双分支
// + spool 主机注册表（defaults 注入缝）+ RemoteSpoolDrainer 生命周期 + LLM prompt 纯函数。
//
// 打法延续 B214 三层路线，本批新确立两个可测事实：
// 1. @ObservedObject 虽在构造期立即求值单例，但 RemoteSpoolDrainer.shared 的单例化本身
//    无副作用（init 不调 applyPreferences，timer 为 nil）——LANSettingsView() 可安全构造；
// 2. lanMode=true 分支的构建表达式会执行 LANHookPreferences.currentLANIP()（getifaddrs
//    内存枚举，无外部副作用）与 generateRemoteInstallScript（纯字符串构建）——双分支可测。
// Drainer 生命周期测试走 registerHost→applyPreferences(启动)→removeHost→applyPreferences(停止)
// 的毫秒级窗口，Timer.scheduledTimer 2s 间隔在同步测试进程内永不 fire（无 ssh 外呼）。
// 主机注册表全走 UserDefaults(suiteName:) 隔离域，standard 域只动 lanMode 键且测后清理。

extension RunnerHarness {
    func runLANSettingsViewTests() {
        // MARK: A. RemoteSpoolHosts 注册表（隔离 defaults 域）
        let isolated = UserDefaults(suiteName: "runner-spool-test-\(UUID().uuidString)")!
        check("spoolHosts: 空域载入空表",
              RemoteSpoolHosts.loadHosts(defaults: isolated).isEmpty)
        check("spoolHosts: 垃圾 JSON 载入空表兜底",
              {
                  isolated.set("not-json{{", forKey: RemoteSpoolHosts.hostsKey)
                  return RemoteSpoolHosts.loadHosts(defaults: isolated).isEmpty
              }())
        check("spoolHosts: registerHost 新增返回 true 且持久化",
              RemoteSpoolHosts.registerHost("user@host-a", defaults: isolated)
              && RemoteSpoolHosts.loadHosts(defaults: isolated) == ["user@host-a"])
        check("spoolHosts: registerHost 去重返回 false",
              RemoteSpoolHosts.registerHost("user@host-a", defaults: isolated) == false
              && RemoteSpoolHosts.loadHosts(defaults: isolated) == ["user@host-a"])
        check("spoolHosts: registerHost 非法目标拒注册",
              RemoteSpoolHosts.registerHost("-oProxyCommand=evil", defaults: isolated) == false)
        check("spoolHosts: registerHost 保持插入序追加",
              {
                  RemoteSpoolHosts.registerHost("user@host-b", defaults: isolated)
                  return RemoteSpoolHosts.loadHosts(defaults: isolated) == ["user@host-a", "user@host-b"]
              }())
        check("spoolHosts: removeHost 精确移除",
              {
                  RemoteSpoolHosts.removeHost("user@host-a", defaults: isolated)
                  return RemoteSpoolHosts.loadHosts(defaults: isolated) == ["user@host-b"]
              }())
        check("spoolHosts: saveHosts 往返一致",
              {
                  RemoteSpoolHosts.saveHosts(["x@y", "z@w"], defaults: isolated)
                  return RemoteSpoolHosts.loadHosts(defaults: isolated) == ["x@y", "z@w"]
              }())

        // MARK: B. RemoteSpoolDrainer 生命周期（新实例，不触碰 shared）
        // HostStatus 值语义。
        let status = RemoteSpoolDrainer.HostStatus()
        check("spoolDrainer: HostStatus 默认值与 Equatable",
              status.lastDrainAt == nil && status.lastEventCount == 0 && status.lastError == nil
              && status == RemoteSpoolDrainer.HostStatus())

        // 静态常量契约锁（B178 分批回灌预算等历史语义）。
        check("spoolDrainer: 轮询/超时/陈旧/预算常量契约",
              RemoteSpoolDrainer.pollInterval == 2.0
              && RemoteSpoolDrainer.drainTimeout == 10.0
              && RemoteSpoolDrainer.stalenessMinutes == 60
              && RemoteSpoolDrainer.batchLimit == 20
              && RemoteSpoolDrainer.maxReplaysPerTick == 4)

        // 生命周期：hook 关（默认）→ applyPreferences 走停止分支（timer 本就 nil）；
        // 开 + 有主机 → timer 建立（启动分支）；再关 → invalidate（停止分支）。
        // 全程毫秒级，2s 轮询 timer 在同步测试进程内不会 fire，无 ssh 外呼。
        let drainer = RemoteSpoolDrainer()
        let savedEnabled = ClaudeHookPreferences.isEnabled
        let savedHosts = UserDefaults.standard.string(forKey: RemoteSpoolHosts.hostsKey)
        defer {
            ClaudeHookPreferences.isEnabled = savedEnabled
            if let savedHosts { UserDefaults.standard.set(savedHosts, forKey: RemoteSpoolHosts.hostsKey) } else { UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey) }
        }
        ClaudeHookPreferences.isEnabled = false
        UserDefaults.standard.removeObject(forKey: RemoteSpoolHosts.hostsKey)
        drainer.applyPreferences()   // shouldRun=false, timer=nil → guard return
        ClaudeHookPreferences.isEnabled = true
        RemoteSpoolHosts.registerHost("user@host-c")
        drainer.applyPreferences()   // shouldRun=true → timer 建立（启动分支）
        RemoteSpoolHosts.removeHost("user@host-c")
        drainer.applyPreferences()   // shouldRun=false, timer!=nil → invalidate（停止分支）
        ClaudeHookPreferences.isEnabled = false
        drainer.applyPreferences()   // 复位后再次停止分支
        // tick：空主机表 → for 空转，不发 ssh。
        drainer.tick()

        // MARK: C. LANSettingsView body 求值（lanMode 双分支）
        let lanKey = LANHookPreferences.lanModeKey
        let savedLanMode = UserDefaults.standard.object(forKey: lanKey)
        defer {
            if let savedLanMode { UserDefaults.standard.set(savedLanMode, forKey: lanKey) } else { UserDefaults.standard.removeObject(forKey: lanKey) }
        }

        // false（默认）分支：SettingsCard + spool 区（空表「暂无远程主机」+ disabled(true)）。
        UserDefaults.standard.set(false, forKey: lanKey)
        let _ = LANSettingsView().body

        // true 分支：lanDetailSection 构建期执行 currentLANIP() 与 generateRemoteInstallScript，
        // remoteBindings 空表走「暂无远程主机」、remoteInstallMessage nil 分支。
        UserDefaults.standard.set(true, forKey: lanKey)
        let _ = LANSettingsView().body

        // memberwise 注入态：spoolHosts 非空（立即拉取 disabled(false) 分支）+
        // remoteInstallMessage 双态（success/danger 前景色三元双分支）。
        let _ = LANSettingsView(remoteBindings: [:], newMachineLabel: "",
                                remoteInstallMessage: "已复制到剪贴板（128 字符）", remoteInstallSucceeded: true,
                                spoolHosts: ["user@host"], newSpoolHost: "").body
        let _ = LANSettingsView(remoteBindings: [:], newMachineLabel: "",
                                remoteInstallMessage: "复制失败", remoteInstallSucceeded: false,
                                spoolHosts: [], newSpoolHost: "user@new").body
        UserDefaults.standard.set(false, forKey: lanKey)

        // MARK: D. LLM prompt 构造纯函数（B197 提缝真身）
        check("voiceLLM: llmSystemPrompt 无待问=纯总结指令",
              VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: false, maxChars: 50)
              == "请用一句话总结以下 AI 回复，不超过50字。直接输出总结，不加引号或前缀。")
        check("voiceLLM: llmSystemPrompt 待问时前置等待提醒",
              VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: true, maxChars: 30).hasPrefix(
                  "请用一句话总结以下 AI 回复，不超过30字。直接输出总结，不加引号或前缀。")
              && VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: true, maxChars: 30).hasSuffix(
                  "AI 正在向用户提问并等待回复，请在总结开头加上「需要你的输入，」。"))
        check("voiceLLM: llmUserContent 上下文在前消息压轴、\\n---\\n 分隔",
              VoiceAnnouncementManager.llmUserContent(message: "最后一句", context: ["早句", "中句"])
              == "早句\n---\n中句\n---\n最后一句")
        check("voiceLLM: llmUserContent 无上下文=裸消息",
              VoiceAnnouncementManager.llmUserContent(message: "only", context: []) == "only")
        check("voiceLLM: llmUserContent 超 2000 字截断保留尾部",
              VoiceAnnouncementManager.llmUserContent(message: String(repeating: "尾", count: 1500),
                                                      context: [String(repeating: "头", count: 1500)]).count == 2000)
        check("voiceLLM: llmUserContent 恰 2000 字不截断",
              VoiceAnnouncementManager.llmUserContent(message: String(repeating: "字", count: 2000),
                                                      context: []).count == 2000)
    }
}
