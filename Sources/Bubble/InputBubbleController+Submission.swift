import AppKit
import Carbon

// Sources/Bubble/InputBubbleController+Submission.swift — B151 自 InputBubbleController.swift
// 按域拆出（逐字搬移零行为变更）：提交链的注入机械（等前台→窗口柄复核→键击投递→收尾）。
// 注入门纯决策在 InputBubbleSubmitGate（RunnerInputBubbleTests 直测），本文件只做编排。

extension InputBubbleController {
    /// 激活后等前台/窗口柄到位再注入（非阻塞轮询；超时宁可不注入）。
    func waitFrontmostAndInject(target: Target, text: String, mode: InputBubbleSubmitMode, elapsedMs: Int) {
        let frontmostMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        if frontmostMatches {
            // 前台已到位：再验窗口柄（防激活期间切 tab / 关窗）
            let handle = WindowManager.shared.focusedWindow(for: target.pid)
                .flatMap { WindowManager.shared.windowHandle(for: $0) }
            let gate = InputBubbleSubmitGate.decide(
                text: text,
                mode: mode,
                targetStillValid: handle == target.windowID,
                frontmostMatchesTarget: true
            )
            switch gate {
            case .proceed(let steps):
                inject(steps: steps, target: target)
            case .dismissOnly:
                finishSubmission()
            case .abortMissingTarget:
                abortSubmission(reason: "target window gone", target: target)
            case .abortFrontmostMismatch:
                abortSubmission(reason: "frontmost mismatch (unreachable)", target: target)
            }
            return
        }
        if elapsedMs >= InputBubbleTiming.frontmostPollBudgetMs {
            abortSubmission(reason: "frontmost activate timeout", target: target)
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(InputBubbleTiming.frontmostPollIntervalMs)
        ) { [weak self] in
            self?.waitFrontmostAndInject(
                target: target, text: text, mode: mode,
                elapsedMs: elapsedMs + InputBubbleTiming.frontmostPollIntervalMs
            )
        }
    }

    func inject(steps: [InputBubbleKeyPlan.Step], target: Target) {
        log("[InputBubble] injecting", fields: [
            "steps": steps.map { $0 == .paste ? "paste" : "return" }.joined(separator: ","),
            "windowID": String(target.windowID),
            "pid": String(target.pid)
        ])
        CrashContextRecorder.shared.record("input_bubble_inject windowID=\(target.windowID) steps=\(steps.count)")
        // B162：注入放行即消费草稿（abort 不清——文本保留在草稿里，重开气泡可续）
        InputBubbleDraftStore.shared.clear(for: target.windowID)

        for (index, step) in steps.enumerated() {
            let delayMs = index * InputBubbleTiming.pasteToReturnDelayMs
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                switch step {
                case .paste:
                    self?.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
                case .returnKey:
                    self?.postKeyCombo(keyCode: CGKeyCode(kVK_Return), flags: [])
                }
            }
        }

        let totalMs = max(steps.count - 1, 0) * InputBubbleTiming.pasteToReturnDelayMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(totalMs + InputBubbleTiming.clipboardRestoreDelayMs)) { [weak self] in
            self?.restoreClipboardIfSafe()
            self?.finishSubmission()
        }
    }

    func abortSubmission(reason: String, target: Target) {
        NSSound.beep()
        log("[InputBubble] inject aborted", level: .warn, fields: [
            "reason": reason,
            "windowID": String(target.windowID)
        ])
        CrashContextRecorder.shared.record("input_bubble_abort reason=\(reason) windowID=\(target.windowID)")
        restoreClipboardIfSafe()
        finishSubmission()
    }

    /// 收尾：回归 accessory 政策 + 状态复位（面板已在 submit 时 orderOut）。
    func finishSubmission() {
        phase = .idle
        panel = nil
        textView = nil
        target = nil
        NSApp.setActivationPolicy(.accessory)
        restoreSettingsWindowIfNeeded()
    }

    /// 气泡关闭/提交收尾后，把之前可见的设置窗放回（TitleEditor 同款：恢复可见性不抢焦点）
    func restoreSettingsWindowIfNeeded() {
        guard settingsWasVisible else { return }
        settingsWasVisible = false
        SettingsWindowController.shared.window?.orderFront(nil)
    }

    // MARK: 键击投递（NativeSpaceBridge Escape 同款 .cghidEventTap 语义）

    func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}
