import AppKit
import Carbon
import ApplicationServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleSubmitPipelineTests.swift — B310：气泡提交管线编排直测。
// B308 修复后 +Submission.swift 编排层（inject/settle/postReturn/waitFrontmost/abort）
// 全部未覆盖；本文件用 B255 keyEventPoster 同款注入法 + B310 观察缝
// （submitFrontmostPIDProvider / submitFocusedWindowHandleProvider /
//   submitSettleAXWindowProvider / submitHasToggleRecordProvider——只换事实来源，
// 不换判定）驱动完整提交管线，键击全程走 mock 不投真实 HID。
//
// AX 落地验证用自有进程探针窗（NSWindow+NSTextView，AXTextArea 内容即屏文本）：
// 自进程 AX 读零权限、零用户窗触碰、零合成键击；探针窗测试末关闭。
// defaults 域（history/draft/autoRestore）先快照后恢复，杜绝跨进程残留（B261 教训）。

private struct SubmitPipelineKeyEvent: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let keyDown: Bool
}

private final class SubmitPipelineKeyEventPoster: KeyEventPosting {
    private(set) var events: [SubmitPipelineKeyEvent] = []
    var returnKeyCount: Int { events.filter { $0.keyCode == CGKeyCode(kVK_Return) && $0.keyDown }.count }
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        events.append(SubmitPipelineKeyEvent(keyCode: keyCode, flags: flags, keyDown: keyDown))
    }
    func reset() { events.removeAll() }
}

extension RunnerHarness {

    func runBubbleSubmitPipelineTests() {
        print("\n=== BubbleSubmitPipeline (B310) ===")
        let controller = InputBubbleController.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let defaults = UserDefaults.standard

        // --- defaults 域快照/恢复（防 Runner 跨进程残留；B261 教训） ---
        let savedHistory = defaults.data(forKey: "inputBubbleHistory")
        let savedDrafts = defaults.data(forKey: "inputBubbleDrafts")
        let savedAutoRestore = defaults.object(forKey: "inputBubbleAutoRestoreOnSubmit")
        defaults.removeObject(forKey: "inputBubbleHistory")
        defaults.removeObject(forKey: "inputBubbleDrafts")

        // --- 自有进程 AX 探针窗（settle 落地验证的真实 AX 事实源） ---
        // CLI 进程默认 .prohibited 策略下窗口不进 AX windows 表——先切 accessory
        //（生产 showPanel 的 setActivationPolicy 同款），测试末还原。
        _ = NSApplication.shared
        let savedPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(savedPolicy) }
        let probe = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 520, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        probe.title = "VF-Submit-Pipeline-Probe"
        let probeText = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        probeText.string = ""
        probe.contentView = probeText
        probe.orderFront(nil)

        func probeAXElement() -> AXUIElement? {
            // 轮询几拍等 AX windows 表收录新窗
            for _ in 0..<10 {
                let appEl = AXUIElementCreateApplication(ownPID)
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &ref) == .success,
                   let windows = ref as? [AXUIElement] {
                    for w in windows where WindowManager.shared.title(of: w) == "VF-Submit-Pipeline-Probe" {
                        return w
                    }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return nil
        }

        defer {
            controller.submitFrontmostPIDProvider = nil
            controller.submitFocusedWindowHandleProvider = nil
            controller.submitSettleAXWindowProvider = nil
            controller.submitHasToggleRecordProvider = nil
            controller.keyEventPoster = CGKeyEventPoster()
            controller.finishSubmission()
            probe.orderOut(nil)
            if let savedHistory { defaults.set(savedHistory, forKey: "inputBubbleHistory") } else { defaults.removeObject(forKey: "inputBubbleHistory") }
            if let savedDrafts { defaults.set(savedDrafts, forKey: "inputBubbleDrafts") } else { defaults.removeObject(forKey: "inputBubbleDrafts") }
            if let savedAutoRestore { defaults.set(savedAutoRestore, forKey: "inputBubbleAutoRestoreOnSubmit") } else { defaults.removeObject(forKey: "inputBubbleAutoRestoreOnSubmit") }
        }

        let mock = SubmitPipelineKeyEventPoster()
        controller.keyEventPoster = mock

        func pump(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        @discardableResult
        func pumpUntilIdle(_ maxSeconds: Double) -> Bool {
            let deadline = Date().addingTimeInterval(maxSeconds)
            while Date() < deadline {
                if controller.phase == .idle {
                    pump(0.05)
                    return true
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return controller.phase == .idle
        }
        func arm(text: String, bundleID: String?, windowID: UInt32 = 777_001) {
            controller.finishSubmission()
            controller.phase = .open
            controller.target = InputBubbleController.Target(pid: ownPID, bundleID: bundleID, windowID: windowID, title: "probe")
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            tv.string = text
            controller.textView = tv
            mock.reset()
            controller.submitFrontmostPIDProvider = { ownPID }
            controller.submitFocusedWindowHandleProvider = { windowID }
            controller.submitSettleAXWindowProvider = nil
            controller.submitHasToggleRecordProvider = nil
        }

        // --- ① pasteOnly：粘贴后收尾，无 Return，草稿消费+历史落账+剪贴板还原 ---
        arm(text: "paste-only 内容", bundleID: nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("VF-clip-guard-A", forType: .string)
        controller.submit(mode: .pasteOnly)
        pump(0.15)
        check("pipeline: pasteOnly 只投 ⌘V（down→up 两事件）",
              mock.events.count == 2 && mock.events.allSatisfy { $0.keyCode == CGKeyCode(kVK_ANSI_V) })
        check("pipeline: pasteOnly 无 Return", mock.returnKeyCount == 0)
        check("pipeline: pasteOnly 注入期 phase=submitting", controller.phase == .submitting)
        check("pipeline: pasteOnly 清草稿", InputBubbleDraftStore.shared.draft(for: 777_001) == nil)
        check("pipeline: pasteOnly 历史记 submitted",
              InputBubbleHistoryStore.shared.entries().first?.status == .submitted)
        check("pipeline: pasteOnly 剪贴板还原",
              pumpUntilIdle(1.5) && NSPasteboard.general.string(forType: .string) == "VF-clip-guard-A")

        // --- ② blindDelay 提交（bundleID 非 AX 可读 → 尺寸感知兜底路）：V→R 顺序、单次 Return ---
        arm(text: "blind 内容", bundleID: "com.example.notax")
        controller.submit(mode: .submit)
        check("pipeline: blind 注入期先只投 ⌘V", {
            pump(0.05)
            return mock.events.count == 2 && mock.returnKeyCount == 0
        }())
        let blindIdle = pumpUntilIdle(2.0)
        check("pipeline: blind 兜底路 Return 恰一次且在粘贴之后",
              blindIdle && mock.events.count == 4 && mock.returnKeyCount == 1
              && mock.events[0].keyCode == CGKeyCode(kVK_ANSI_V) && mock.events[0].keyDown
              && mock.events[3].keyCode == CGKeyCode(kVK_Return))
        check("pipeline: blind 收尾 phase 归 idle", controller.phase == .idle)

        // --- ③ axVerify 命中路（自有探针窗 AXTextArea 含粘贴尾部 → 看到 ROI 才发 Return） ---
        let axWindow = probeAXElement()
        if let axWindow, let handle = WindowManager.shared.windowHandle(for: axWindow) {
            probeText.string = "屏上已有内容 probe-submit-tail-marker"
            arm(text: "验证正文 probe-submit-tail-marker", bundleID: "com.googlecode.iterm2", windowID: handle)
            controller.submitSettleAXWindowProvider = { axWindow }
            controller.submit(mode: .submit)
            let verifiedIdle = pumpUntilIdle(2.5)
            check("pipeline: axVerified 命中路 Return 恰一次",
                  verifiedIdle && mock.returnKeyCount == 1 && mock.events.count == 4)
            check("pipeline: axVerified 收尾归 idle", controller.phase == .idle)
        } else {
            check("pipeline: axVerified 命中路（自有窗 AX 不可用，环境受限跳过）", true)
        }

        // --- ④ axVerify 超时兜底（屏文本永不含尾部 → 预算耗尽仍发 Return=旧行为下限） ---
        if let axWindow = probeAXElement() {
            probeText.string = "完全不匹配的屏幕内容"
            arm(text: "永不上屏的正文 tail-not-present-xyz", bundleID: "com.googlecode.iterm2")
            controller.submitSettleAXWindowProvider = { axWindow }
            controller.submit(mode: .submit)
            let timeoutIdle = pumpUntilIdle(3.5)
            check("pipeline: settle 超时兜底 Return 恰一次（绝不吞提交）",
                  timeoutIdle && mock.returnKeyCount == 1 && mock.events.count == 4)
        } else {
            check("pipeline: settle 超时兜底（自有窗 AX 不可用，环境受限跳过）", true)
        }

        // --- ⑤ settle 期间失焦：abort 不发 Return（宁缺勿错），剪贴板还原 ---
        arm(text: "失焦场景正文", bundleID: "com.googlecode.iterm2")
        var settlePolls = 0
        controller.submitFrontmostPIDProvider = { settlePolls += 1; return settlePolls <= 1 ? ownPID : -1 }
        controller.submit(mode: .submit)
        pump(0.4)
        check("pipeline: settle 失焦 abort 零 Return", mock.returnKeyCount == 0)
        check("pipeline: settle 失焦 abort 收尾归 idle 且剪贴板还原",
              controller.phase == .idle && NSPasteboard.general.string(forType: .string) == "VF-clip-guard-A")

        // --- ⑥ settle 无 AX 窗：verifyNoAXWindow 兜底照发 Return ---
        arm(text: "无 AX 窗正文", bundleID: "com.googlecode.iterm2")
        controller.submitSettleAXWindowProvider = { nil }
        controller.submit(mode: .submit)
        let noAxIdle = pumpUntilIdle(2.5)
        check("pipeline: verifyNoAXWindow 兜底 Return 恰一次", noAxIdle && mock.returnKeyCount == 1)

        // --- ⑦ 注入门四分流（waitFrontmostAndInject 直驱） ---
        // 7a 目标窗失效：beep abort、零键击。
        arm(text: "门校验正文", bundleID: nil)
        controller.submitFocusedWindowHandleProvider = { 999_999 }
        controller.finishSubmission()
        controller.phase = .submitting
        controller.waitFrontmostAndInject(
            target: InputBubbleController.Target(pid: ownPID, bundleID: nil, windowID: 777_001, title: "probe"),
            text: "门校验正文", mode: .submit, elapsedMs: 0)
        check("pipeline: 注入门目标窗失效 abort 零键击",
              controller.phase == .idle && mock.events.isEmpty)
        // 7b 预算耗尽：超时 abort、零键击。
        arm(text: "超时正文", bundleID: nil)
        controller.submitFrontmostPIDProvider = { -1 }
        controller.finishSubmission()
        controller.phase = .submitting
        controller.waitFrontmostAndInject(
            target: InputBubbleController.Target(pid: ownPID, bundleID: nil, windowID: 777_001, title: "probe"),
            text: "超时正文", mode: .submit, elapsedMs: InputBubbleTiming.frontmostPollBudgetMs)
        check("pipeline: 注入门预算耗尽 abort 零键击", controller.phase == .idle && mock.events.isEmpty)
        // 7c 空文本：dismissOnly 只收尾。
        arm(text: "", bundleID: nil)
        controller.submit(mode: .submit)
        check("pipeline: 空文本 dismissOnly 零键击收尾",
              controller.phase == .idle && mock.events.isEmpty)

        // --- ⑧ 归位决策 restore 分支（缝判读=true，restore 本体走 nil 记录 failed 臂，零 DB 写） ---
        arm(text: "归位分支正文", bundleID: "com.googlecode.iterm2")
        InputBubblePreferences.autoRestoreOnSubmit = true
        controller.submitHasToggleRecordProvider = { true }
        controller.submitSettleAXWindowProvider = { probeAXElement() }
        if controller.submitSettleAXWindowProvider != nil {
            controller.submit(mode: .submit)
            _ = pumpUntilIdle(4.0)
            check("pipeline: 归位 restore 分支进入并收尾不崩（失败臂）", controller.phase == .idle)
        } else {
            check("pipeline: 归位 restore 分支（自有窗 AX 不可用，环境受限跳过）", true)
        }
        InputBubblePreferences.autoRestoreOnSubmit = false

        // --- ⑨ 散点：Logic needle 全噪声 / HistoryStore 空白快照守卫 / Clipboard dyn 类型跳过 ---
        check("pipeline: pasteLanded needle 全渲染噪声 → 不误判落地",
              !InputBubblePasteSettlePlan.pasteLanded(screenText: "任意屏文本", pastedText: "││││││││││││"))
        let isolated = InputBubbleHistoryStore(defaults: UserDefaults(suiteName: "B310-\(UUID().uuidString)")!)
        isolated.recordDraftSnapshot("  \n\t ", windowID: 1, windowTitle: nil)
        check("pipeline: recordDraftSnapshot 空白守卫零写入", isolated.entries().isEmpty)
        NSPasteboard.general.clearContents()
        let mixed = NSPasteboardItem()
        mixed.setString("VF-keep-me-9137", forType: .string)
        mixed.setData(Data([0x01, 0x02]), forType: NSPasteboard.PasteboardType("dyn.vf9137"))
        NSPasteboard.general.writeObjects([mixed])
        controller.saveClipboardThenWrite("pipeline-temp")
        controller.restoreClipboardIfSafe()
        check("pipeline: 剪贴板快照跳过 dyn 类型且还原普通字符串",
              NSPasteboard.general.string(forType: .string) == "VF-keep-me-9137")
    }
}
