import AppKit
import Carbon
import CoreGraphics
import Foundation
@testable import VibeFocusKit

// B129 输入气泡：纯决策层直测（热键匹配矩阵 / 键序计划 / 提交门判序 /
// 剪贴板恢复决策 / CG→AppKit 翻转 / 锚点布局双轴夹进与退化）。
// IO 编排（NSPanel/CGEvent/剪贴板读写）在 InputBubbleController，归真机 E2E。

extension RunnerHarness {
    func runInputBubbleTests() {
        print("\n=== InputBubble (B129) ===")

        // --- ⌥⌘B 匹配矩阵 ---
        check("bubble hotkey: ⌥⌘B 命中", InputBubbleHotKey.matches(
            keyCode: 11, carbonModifiers: UInt32(optionKey | cmdKey)))
        check("bubble hotkey: 仅 ⌥ 不命中", !InputBubbleHotKey.matches(
            keyCode: 11, carbonModifiers: UInt32(optionKey)))
        check("bubble hotkey: 仅 ⌘ 不命中", !InputBubbleHotKey.matches(
            keyCode: 11, carbonModifiers: UInt32(cmdKey)))
        check("bubble hotkey: ⌃⌥⌘ 不命中", !InputBubbleHotKey.matches(
            keyCode: 11, carbonModifiers: UInt32(controlKey | optionKey | cmdKey)))
        check("bubble hotkey: ⌥⌘+⇧ 不命中", !InputBubbleHotKey.matches(
            keyCode: 11, carbonModifiers: UInt32(optionKey | cmdKey | shiftKey)))
        check("bubble hotkey: 其他键 ⌥⌘ 不命中", !InputBubbleHotKey.matches(
            keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(optionKey | cmdKey)))

        // --- 键序计划 ---
        check("keyPlan: submit = paste+return", InputBubbleKeyPlan.steps(for: .submit) == [.paste, .returnKey])
        check("keyPlan: pasteOnly = paste", InputBubbleKeyPlan.steps(for: .pasteOnly) == [.paste])
        check("keyPlan: cancel = 空", InputBubbleKeyPlan.steps(for: .cancel) == [])

        // --- 提交门判序 ---
        func gate(_ text: String, _ mode: InputBubbleSubmitMode, _ valid: Bool, _ front: Bool) -> InputBubbleSubmitGate.Outcome {
            InputBubbleSubmitGate.decide(text: text, mode: mode, targetStillValid: valid, frontmostMatchesTarget: front)
        }
        if case .dismissOnly = gate("", .submit, true, true) {
            check("gate: 空文本 → dismissOnly", true)
        } else { check("gate: 空文本 → dismissOnly", false) }
        if case .dismissOnly = gate("   \n ", .submit, true, true) {
            check("gate: 空白文本 → dismissOnly", true)
        } else { check("gate: 空白文本 → dismissOnly", false) }
        if case .dismissOnly = gate("hi", .cancel, true, true) {
            check("gate: cancel → dismissOnly", true)
        } else { check("gate: cancel → dismissOnly", false) }
        if case .dismissOnly = gate("", .submit, false, false) {
            check("gate: 空文本优先于目标校验", true)
        } else { check("gate: 空文本优先于目标校验", false) }
        if case .abortMissingTarget = gate("hi", .submit, false, true) {
            check("gate: 目标窗失效 → abortMissingTarget", true)
        } else { check("gate: 目标窗失效 → abortMissingTarget", false) }
        if case .abortFrontmostMismatch = gate("hi", .submit, true, false) {
            check("gate: 前台不符 → abortFrontmostMismatch", true)
        } else { check("gate: 前台不符 → abortFrontmostMismatch", false) }
        if case .proceed(let steps) = gate("hi", .submit, true, true), steps == [.paste, .returnKey] {
            check("gate: submit 放行 = paste+return", true)
        } else { check("gate: submit 放行 = paste+return", false) }
        if case .proceed(let steps) = gate("hi", .pasteOnly, true, true), steps == [.paste] {
            check("gate: pasteOnly 放行 = 仅 paste", true)
        } else { check("gate: pasteOnly 放行 = 仅 paste", false) }

        // --- 剪贴板恢复决策 ---
        check("clipboard: changeCount 未动 → 恢复", InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 42))
        check("clipboard: 用户又复制 → 不恢复", !InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 43))
        check("clipboard: count 异常回退 → 不恢复", !InputBubbleClipboardPlan.shouldRestore(postWriteCount: 42, currentCount: 41))

        // --- CG→AppKit y 翻转 ---
        check("layout: appKitY 翻转", InputBubbleLayout.appKitY(fromCGY: 100, primaryScreenHeight: 1117) == 1017)
        check("layout: appKitY 零点", InputBubbleLayout.appKitY(fromCGY: 1117, primaryScreenHeight: 1117) == 0)
        let cgFrame = CGRect(x: 100, y: 200, width: 600, height: 400)
        let akFrame = InputBubbleLayout.appKitFrame(fromCGFrame: cgFrame, primaryScreenHeight: 1117)
        check("layout: appKitFrame 整体翻转", akFrame == CGRect(x: 100, y: 517, width: 600, height: 400))

        // --- 锚点布局 ---
        let bubble = CGSize(width: 480, height: 150)
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // 常规：窗内左下 + margin
        let normal = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 100, y: 100, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 常规贴窗左下内侧", normal == CGPoint(x: 116, y: 116))
        // 右缘夹进：窗太靠右，气泡左移保完整可见
        let rightClamped = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 1400, y: 100, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 右缘夹进 x=visible.max-宽-margin", rightClamped.x == 1728 - 480 - 16 && rightClamped.y == 116)
        // 下缘夹进：窗底越出屏幕（AppKit 坐标 minY < visible.minY）
        let bottomClamped = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 100, y: -50, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: visible, margin: 16)
        check("anchor: 下缘夹进 y=visible.min+margin", bottomClamped == CGPoint(x: 116, y: 16))
        // 副屏负坐标 visibleFrame（本机 P40UG 在主屏上方 = 负 y 区）
        let negVisible = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let negCase = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: -1800, y: -500, width: 600, height: 400),
            bubbleSize: bubble, visibleFrame: negVisible, margin: 16)
        check("anchor: 负坐标副屏正常锚定", negCase == CGPoint(x: -1784, y: -484))
        // 退化：气泡比屏宽 → 贴 visible 左缘不越界
        let degenerate = InputBubbleLayout.anchorOrigin(
            targetAppKitFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
            bubbleSize: CGSize(width: 2000, height: 150),
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 800),
            margin: 16)
        check("anchor: 气泡比屏宽退化贴左缘", degenerate.x == 16 && degenerate.y == 66)

        // --- 时序常量存在性（执行器消费，防误删） ---
        check("timing: 轮询预算 > 间隔", InputBubbleTiming.frontmostPollBudgetMs > InputBubbleTiming.frontmostPollIntervalMs)
        check("timing: 粘贴→回车间隔与恢复延迟为正", InputBubbleTiming.pasteToReturnDelayMs > 0 && InputBubbleTiming.clipboardRestoreDelayMs > 0)
    }
}
