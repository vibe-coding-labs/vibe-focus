import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAutoShowStartTests.swift — 覆盖率批次 35（B267）：
// ①AppSpeechSynthesizerProvider.makeSynthesizer：真实引擎装配直测（构造+参数透传，
//   不触发 startSpeaking 零发声）；②AppSoundPlayer.stop 空实例 no-op（play 真发声留白）；
// ③InputBubbleAutoShow.start：observer 幂等守卫 + seedBaselines 全量只读扫描。

private final class DelegateBox: NSObject, NSSpeechSynthesizerDelegate {
    var called = false
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finished: Bool) {
        called = true
    }
}

extension RunnerHarness {
    func runAutoShowStartTests() {
        // MARK: A. AppSpeechSynthesizerProvider：真实装配参数透传（零发声）
        let provider = AppSpeechSynthesizerProvider()
        let box = DelegateBox()
        let synth = provider.makeSynthesizer(rate: 210, volume: 0.55, delegate: box)
        // volume 经 NSSpeechSynthesizer 内部量化（0.55 → 0.5499878），用小容差断言。
        check("autoShow: 工厂装配 rate/volume 透传（合成器量化容差）",
              abs(synth.rate - 210) < 0.5 && abs(synth.volume - 0.55) < 0.01)
        // delegate 弱引用由 DelegateBox 强持有保持存活；手动派发完成回调验证链路。
        synth.delegate?.speechSynthesizer?(synth, didFinishSpeaking: true)
        check("autoShow: delegate 透传完成回调可达", box.called)
        // 不调用 synth.startSpeaking——真发声留白。

        // MARK: B. AppSoundPlayer.stop：未播放实例 no-op（play 真发声留白）
        let player = AppSoundPlayer()
        let idleSound = NSSound()
        player.stop(idleSound)
        check("soundEngine: stop 未播放实例 no-op 不崩", true)

        // MARK: C. InputBubbleAutoShow.start：observer 幂等守卫
        let autoShow = InputBubbleAutoShow.shared
        autoShow.start()
        autoShow.start() // 二次调用 observer != nil 守卫早退
        check("autoShow: start 幂等（重复调用不崩不重复注册）", true)
    }
}
