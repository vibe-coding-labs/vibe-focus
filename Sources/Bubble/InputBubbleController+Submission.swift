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
        // B176：激活逐拍重试——activate 只调一次时，被系统协作激活推迟/拒绝
        // （典型：鼠标点击事件处理期间发起）就只能干等到假超时；每拍重发让
        // 推迟的激活在事件落定后仍能兑现。
        _ = NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: .activateIgnoringOtherApps)
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

        // B176 提交后自动归位：决策在注入起点采集（窗态 580ms 注入窗口内不变），
        // 执行在收尾块（Return 已落地）。仅气泡提交路径；abort 不归位（用户还需要这扇窗）。
        let autoRestoreDecision = InputBubbleAutoRestoreGate.decide(
            preferenceEnabled: InputBubblePreferences.autoRestoreOnSubmit,
            submits: steps.contains(.returnKey),
            hasToggleRecord: ToggleEngine.shared.load(windowID: target.windowID) != nil,
            isOnMainScreen: WindowManager.shared.isWindowOnMainScreen(windowID: target.windowID)
        )
        let restoreWindowID = target.windowID

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
            self?.autoRestoreIfDecided(decision: autoRestoreDecision, windowID: restoreWindowID)
            self?.finishSubmission()
        }
    }

    /// B176：提交注入落地后按门决议归位（经 ToggleEngine 直调，与 UPS restoreToOriginal
    /// 同一执行入口；成功清 toggle 记录，~2s 后到达的 UPS 见无记录 → stay，无冲突）。
    private func autoRestoreIfDecided(decision: InputBubbleAutoRestoreGate.Outcome, windowID: UInt32) {
        guard decision == .restore else {
            log("[InputBubble] auto-restore skip", level: .debug, fields: [
                "outcome": String(describing: decision),
                "windowID": String(windowID)
            ])
            return
        }
        let traceID = "bubble-\(Int(Date().timeIntervalSince1970 * 1000))"
        let outcome = ToggleEngine.shared.restore(
            windowID: windowID,
            triggerSource: "input_bubble_submit",
            traceID: traceID
        )
        if case .restored = outcome {
            log("[InputBubble] submit auto-restore completed", fields: [
                "windowID": String(windowID),
                "traceID": traceID
            ])
        } else {
            log("[InputBubble] submit auto-restore failed", level: .warn, fields: [
                "windowID": String(windowID),
                "outcome": outcome.outcomeLabel,
                "traceID": traceID
            ])
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
        // B180：气泡会话结束，还原自家浮层（幂等；dismiss 路径同款）
        ScreenOverlayManager.shared.setOverlaysSuppressedForInputBubble(false)
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
