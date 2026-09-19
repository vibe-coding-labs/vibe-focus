import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDiagnosticsSamplerTests.swift — B228：崩溃取证采样器/诊断工具/
// 语音偏好持久化直测（三者此前 0 计数行）。全部只读或 Runner 自域 defaults 存-还。

extension RunnerHarness {
    func runDiagnosticsSamplerTests() {
        // ===== BacktraceSampler：后台线程采样主线程（生产看门狗同款调用方向） =====
        // ⚠️顺序无关铁律（B228 教训）：portBox 是进程级单例——capture 只许并行线的
        // B220 套件做；本套件①不在主线程调 sampleMainThread（capture 后主线程自采样
        // = thread_suspend 自等死锁）②绝不调 captureMainThreadPortOnLaunch（会武装
        // B220 的「未捕获降级」前提，其主线程首采样即挂）。统一后台线程采样，
        // 对捕获/未捕获两态都只断言「不炸+帧数上限」。
        do {
            final class FramesBox: @unchecked Sendable { var frames: [UInt] = [] }
            let box = FramesBox()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                box.frames = BacktraceSampler.sampleMainThread(maxFrames: 16)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 8)
            check("btsamp: 后台线程采样主线程贯通（帧数≤上限）",
                  box.frames.count <= 16)
            let symbols = BacktraceSampler.symbolize(Array(box.frames.prefix(4)))
            check("btsamp: 符号化输出帧数一致",
                  symbols.count == min(4, box.frames.count) && symbols.allSatisfy { !$0.isEmpty })
            check("btsamp: 空地址表符号化 → 空", BacktraceSampler.symbolize([]).isEmpty)
        }

        // ===== 诊断工具：进程执行 / bundle 定位 / 全量诊断日志 =====
        do {
            let r = runProcessForDiagnostics(executable: "/bin/echo", arguments: ["diag-ok"])
            check("diag: 进程执行 stdout 透传", r?.stdout == "diag-ok\n" && r?.exitCode == 0)
            let bad = runProcessForDiagnostics(executable: "/nonexistent/diag-bin", arguments: [])
            check("diag: 不存在可执行文件 → nil 或非零退出（不炸）",
                  bad == nil || bad?.exitCode != 0)

            let dockPaths = findAppBundlePaths(bundleIdentifier: "com.apple.dock")
            check("diag: Dock.app 定位命中系统路径",
                  dockPaths.contains { $0.contains("Dock.app") })
            check("diag: 未知 bundle id → 空表",
                  findAppBundlePaths(bundleIdentifier: "com.vibefocus.nonexistent.zz").isEmpty)

            logDiagnostics("runner-b228-smoke")
            check("diag: 全量诊断日志烟测（环境/签名/证书链不炸）", true)
        }

        // ===== 语音偏好持久化：三分支（缺省/合法往返/损坏回落） =====
        do {
            let key = VoiceAnnouncementManager.preferencesKey
            let saved = UserDefaults.standard.data(forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            UserDefaults.standard.removeObject(forKey: key)
            check("voicePrefs: 无记录 → .default（不回写）",
                  VoiceAnnouncementManager.loadPreferences() == .default)

            var custom = VoiceAnnouncementPreferences.default
            custom.templateText = "B228-模板"
            UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: key)
            check("voicePrefs: 合法 JSON 解码保真",
                  VoiceAnnouncementManager.loadPreferences().templateText == "B228-模板")

            UserDefaults.standard.set(Data("corrupted".utf8), forKey: key)
            check("voicePrefs: 损坏数据 → .default（绝不回写陈旧值）",
                  VoiceAnnouncementManager.loadPreferences() == .default)

            // savePreferences 实例路径（shared 单例构造无副作用；direct call 序列化当前偏好）
            let mgr = VoiceAnnouncementManager.shared
            UserDefaults.standard.removeObject(forKey: key)
            mgr.savePreferences()
            let reloaded = VoiceAnnouncementManager.loadPreferences()
            check("voicePrefs: savePreferences 落库后 load 回读一致",
                  reloaded == mgr.preferences && reloaded.templateText == mgr.preferences.templateText)
        }
    }
}
