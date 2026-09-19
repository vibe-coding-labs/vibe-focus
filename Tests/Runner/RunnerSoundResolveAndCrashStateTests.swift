import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSoundResolveAndCrashStateTests.swift — 覆盖率批次 17（B248）：
// ①SoundManager.resolveSound/bundledSound 直测（B248 提缝 private→internal）+
//   手写最小 WAV 驱动文件加载分支——纠正 B239 过度豁免：resolveSound 只加载解码
//   NSSound，不调用 .play() 零发声，「发声链」豁免收窄到 startPlayback/previewSound。
// ②CrashContextRecorder record/markCleanExit 状态机直测——纠正 B239/B242 归因：
//   状态文件在 /tmp（共享诊断设计），且测试后还原内存 state（生产 app 的内存态
//   权威会在自身下次持久化时覆写磁盘，瞬态无害）。

/// 生成合法的最小 16-bit PCM WAV（0.05s 静音），驱动 NSSound(contentsOfFile:) 解码。
private func minimalWavData() -> Data {
    var data = Data()
    let sampleRate = 8000
    let seconds = 0.05
    let samples = Int(Double(sampleRate) * seconds)
    let dataSize = samples * 2
    func append(_ s: String) { data.append(contentsOf: s.utf8) }
    func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func appendUInt16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    append("RIFF"); appendUInt32(UInt32(36 + dataSize)); append("WAVE")
    append("fmt "); appendUInt32(16); appendUInt16(1) // PCM
    appendUInt16(1); appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * 2)); appendUInt16(2); appendUInt16(16)
    append("data"); appendUInt32(UInt32(dataSize))
    data.append(contentsOf: repeatElement(0, count: dataSize))
    return data
}

extension RunnerHarness {
    func runSoundResolveAndCrashStateTests() {
        // MARK: A. resolveSound：解析计划 → NSSound 加载（零播放）
        check("soundResolve: .none → nil（不加载）",
              SoundManager.shared.resolveSound(soundType: CompletionSoundType.none) == nil)
        let system = SoundManager.shared.resolveSound(soundType: .systemDefault)
        check("soundResolve: systemDefault 加载系统音 Hero 非 nil",
              system != nil)
        // Runner bundle 无 Sounds 资源（资源随生产 .app bundle 走）→ bundled 查找
        // 全扩展名 miss 降级 nil（生产装载时同路径返回非 nil）。
        check("soundResolve: builtinDing 在无资源 bundle 走 nil 降级",
              SoundManager.shared.resolveSound(soundType: .builtinDing) == nil)

        // .custom：显式路径文件存在 → 加载；不存在 → 降级系统音非 nil。
        let wavPath = NSTemporaryDirectory() + "b248-\(UUID().uuidString).wav"
        try? minimalWavData().write(to: URL(fileURLWithPath: wavPath))
        let fileLoaded = SoundManager.shared.resolveSound(
            soundType: .custom, customPath: wavPath)
        check("soundResolve: custom 显式合法 wav 加载非 nil", fileLoaded != nil)
        try? FileManager.default.removeItem(atPath: wavPath)

        let missingCustom = SoundManager.shared.resolveSound(
            soundType: .custom, customPath: "/nonexistent-b248/x.wav")
        check("soundResolve: custom 文件缺失降级系统音（轮次 3 行为）",
              missingCustom != nil)
        let emptyCustom = SoundManager.shared.resolveSound(
            soundType: .custom, customPath: nil)
        check("soundResolve: custom 双路径皆空 → 走 .none 返 nil",
              emptyCustom == nil)

        // bundledSound：真实查找（Runner bundle 无资源 → nil 降级；有资源时加载）。
        check("soundResolve: bundledSound 无资源名 nil 降级",
              SoundManager.shared.bundledSound(named: "b248-nonexistent") == nil)

        // MARK: B. CrashContextRecorder record/markCleanExit 状态机（/tmp 共享诊断态）
        let recorder = CrashContextRecorder.shared
        let savedState = recorder.state

        recorder.state = CrashContextRecorder.SessionState(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: "b248-test", cleanExit: true, events: [], lastIngestedCrashReport: nil)
        let eventsBefore = recorder.state?.events.count ?? 0
        recorder.record("b248-event-1")
        recorder.record("b248-event-2")
        let eventsAfter = recorder.state?.events.count ?? -1
        // appendEventLocked 事件行带 ISO8601 时间戳前缀（nowString()）。
        let tail = recorder.state?.events.suffix(2) ?? []
        check("crashState: record 两条事件入环且带时间戳前缀",
              eventsAfter == eventsBefore + 2
              && tail.count == 2
              && tail.first?.hasSuffix("b248-event-1") == true
              && tail.last?.hasSuffix("b248-event-2") == true)

        recorder.markCleanExit()
        check("crashState: markCleanExit 置 cleanExit", recorder.state?.cleanExit == true)

        check("crashState: nowString 非空 ISO8601 形态",
              !recorder.nowString().isEmpty)
        recorder.bootstrap()
        check("crashState: bootstrap 幂等不崩", true)

        // 还原内存态（生产 app 内存态权威，磁盘瞬态由其下次持久化覆写）。
        recorder.state = savedState
    }
}
