import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerOverlayWakeRebuildTests.swift — 2026-09-20「角标幽灵窗」修复回归锁
//
// 场景：锁屏/熄屏期间 orderFront 的 canJoinAllSpaces 角标窗会挂在幽灵空间——
// WindowServer 报 onscreen、离屏渲染正常（按窗截图内容完美），但用户可见空间永不合成
// （装机实锤：两代角标窗口 19407-9 / 23515-7 内容完好，用户解锁后任何角落都看不见）。
// 修复 = 监听 screensDidWake / didWake / com.apple.screenIsUnlocked，debounce 后
// hideOverlays+showOverlays 全量重建，重新挂接当前可见空间（装机 0.0.82）。
//
// 本文件锁定：wakeRebuildDecision 真值表（enabled × 崩溃循环熔断 × 输入气泡抑制）
// + debounce 间隔语义。observer 注册在生产 init（startTimerAutomatically=true），
// Runner 构造缝不注册 → 无跨测试副作用。

extension RunnerHarness {

    func runOverlayWakeRebuildTests() {
        check("wakeRebuild T1: enabled+无熔断+无气泡抑制 → 重建",
              ScreenOverlayManager.wakeRebuildDecision(
                enabled: true, crashLoopSuppressed: false, inputBubbleSuppressed: false))
        check("wakeRebuild T2: enabled=false → 不重建（防 showOverlays 无视 isEnabled 拉起浮层）",
              !ScreenOverlayManager.wakeRebuildDecision(
                enabled: false, crashLoopSuppressed: false, inputBubbleSuppressed: false))
        check("wakeRebuild T3: 崩溃循环熔断 → 不重建",
              !ScreenOverlayManager.wakeRebuildDecision(
                enabled: true, crashLoopSuppressed: true, inputBubbleSuppressed: false))
        check("wakeRebuild T4: 输入气泡存续期（B180）→ 不重建（不得借重建拉回浮层）",
              !ScreenOverlayManager.wakeRebuildDecision(
                enabled: true, crashLoopSuppressed: false, inputBubbleSuppressed: true))
        check("wakeRebuild T5: 多抑制组合 → 全绿才重建",
              !ScreenOverlayManager.wakeRebuildDecision(
                enabled: false, crashLoopSuppressed: true, inputBubbleSuppressed: true))
        check("wakeRebuild T6: debounce 间隔为正（合并连发+给 WindowServer 稳定窗）",
              ScreenOverlayManager.wakeRebuildDebounceInterval > 0)
        check("wakeRebuild T7: 唤醒补射间隔递增且为正（解锁后桌面兜底挂接）",
              ScreenOverlayManager.wakeRebuildFollowUpIntervals == [45, 180])
    }
}
