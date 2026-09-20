// MARK: - 按键投递注入缝（B255）

/// 键击投递抽象：CGEvent 构造+post 只此一处。测试注入 mock 记录序列不投递。
protocol KeyEventPosting {
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool)
}

/// 默认实现：真实 CGEvent HID 投递（生产路径）。
struct CGKeyEventPoster: KeyEventPosting {
    func post(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

import AppKit
import Carbon

// Sources/Bubble/InputBubbleController+Submission.swift — B151 自 InputBubbleController.swift
// 按域拆出（逐字搬移零行为变更）：提交链的注入机械（等前台→窗口柄复核→键击投递→收尾）。
// 注入门纯决策在 InputBubbleSubmitGate（RunnerInputBubbleTests 直测），本文件只做编排。
// B308：Return 投递时序治理——粘贴落地验证（AX）+ 尺寸感知兜底，纯决策在
// InputBubblePasteSettlePlan（RunnerInputBubbleTests 直测），本文件只做编排。

/// Return 投递依据（取证字段，进日志与 crash context）。
enum InputBubbleReturnLanding: String {
    /// AX 验证：粘贴尾部已上屏
    case axVerified
    /// AX 验证预算耗尽（读不到/粘贴不上屏），兜底照发=旧行为下限
    case verifyTimeout
    /// 目标窗 AX 窗口取不到（瞬间态），兜底照发
    case verifyNoAXWindow
    /// app 不支持 AX 屏文本读取，尺寸感知盲延迟
    case blindDelay
}

/// AXUIElement 跨队列承载盒（AXUIElement 非 Sendable，StrictConcurrency 下
/// 显式盒传递；单元素单读零共享态）。
private final class AXWindowBox: @unchecked Sendable {
    let window: AXUIElement
    init(_ window: AXUIElement) { self.window = window }
}

/// B308：粘贴落地验证的 AX 读取后台串行队列（深树遍历离开主线程，B305 教训）。
private enum PasteSettleAXQueue {
    static let queue = DispatchQueue(label: "vibefocus.inputbubble.pasteSettleAX")
}

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
                inject(steps: steps, target: target, text: text)
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

    func inject(steps: [InputBubbleKeyPlan.Step], target: Target, text: String) {
        let settleMode = InputBubblePasteSettlePlan.mode(forBundleID: target.bundleID)
        let bytes = text.utf8.count
        log("[InputBubble] injecting", fields: [
            "steps": steps.map { $0 == .paste ? "paste" : "return" }.joined(separator: ","),
            "bytes": String(bytes),
            "settle": settleMode == .axVerify ? "ax" : "blind",
            "windowID": String(target.windowID),
            "pid": String(target.pid)
        ])
        CrashContextRecorder.shared.record(
            "input_bubble_inject windowID=\(target.windowID) steps=\(steps.count) bytes=\(bytes) settle=\(settleMode == .axVerify ? "ax" : "blind")"
        )
        // B195：提交内容进全局历史（↑↓ 翻阅/跨窗恢复兜底），随后照旧清草稿。
        // B196：状态=已提交，带窗口归属（面板按窗过滤/草稿晋升依赖）。
        // abort 不清不记（abortSubmission 路径不经此处）。
        InputBubbleHistoryStore.shared.record(
            text,
            windowID: target.windowID,
            windowTitle: target.title,
            status: .submitted
        )
        // B162：注入放行即消费草稿（abort 不清——文本保留在草稿里，重开气泡可续）
        InputBubbleDraftStore.shared.clear(for: target.windowID)

        let startedAt = Date()
        // paste 恒在 t0（steps 契约：paste 首位或唯一）。B308 起与 Return 解耦：
        // Return 不再盲等固定 80ms，按 settle 计划验证落地后再发（根因：终端侧
        // Cmd+V 是异步分块粘贴作业，键事件与粘贴写入两条通道无顺序保证）。
        if steps.contains(.paste) {
            DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
                self?.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            }
        }
        guard steps.contains(.returnKey) else {
            // pasteOnly：无 Return，收尾节奏与旧行为一致（单步 totalMs=0 + 500ms）
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(InputBubbleTiming.clipboardRestoreDelayMs)) { [weak self] in
                self?.restoreClipboardIfSafe()
                self?.finishSubmission()
            }
            return
        }
        switch settleMode {
        case .axVerify:
            settlePasteThenReturn(target: target, text: text, startedAt: startedAt)
        case .blindDelay:
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(InputBubblePasteSettlePlan.fallbackDelayMs(textByteCount: bytes))
            ) { [weak self] in
                self?.postReturn(landedBy: .blindDelay, target: target, text: text, startedAt: startedAt)
            }
        }
    }

    /// B308：粘贴落地验证循环——看到粘贴尾部上屏才发 Return。
    /// 每拍复查前台（NSWorkspace 非 AX，廉价）：注入窗口期用户切走 → abort 不发
    /// Return（粘贴已落框，宁缺勿错，与提交门「宁可不注入不可射错窗」同则）。
    /// AX 屏文本读在后台串行队列（深树遍历不占主线程，B305 教训；messaging
    /// timeout 封顶单次调用）；读不到/预算耗尽 → 仍发 Return（=旧行为下限，
    /// 绝不因验证通道失灵而吞提交）。
    func settlePasteThenReturn(target: Target, text: String, startedAt: Date) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard elapsedMs < InputBubblePasteSettlePlan.verifyBudgetMs(textByteCount: text.utf8.count) else {
            postReturn(landedBy: .verifyTimeout, target: target, text: text, startedAt: startedAt)
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            abortSubmission(reason: "frontmost lost during paste settle", target: target)
            return
        }
        guard let axWindow = WindowManager.shared.focusedWindow(for: target.pid) else {
            postReturn(landedBy: .verifyNoAXWindow, target: target, text: text, startedAt: startedAt)
            return
        }
        let box = AXWindowBox(axWindow)
        PasteSettleAXQueue.queue.async { [weak self] in
            let screenText = WindowManager.terminalScreenText(of: box.window)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .submitting else { return }
                if InputBubblePasteSettlePlan.pasteLanded(screenText: screenText, pastedText: text) {
                    self.postReturn(landedBy: .axVerified, target: target, text: text, startedAt: startedAt)
                } else {
                    self.settlePasteThenReturn(target: target, text: text, startedAt: startedAt)
                }
            }
        }
    }

    /// B308：Return 落地（验证通过/兜底）→ 投递 Return → 收尾。
    /// B176 归位决策采集点从注入起点移到 Return 落点（Return 时点不再固定 80ms，
    /// 决策所需的窗态在投递瞬间读更新鲜），执行仍在收尾块（Return 已落地后）。
    func postReturn(landedBy: InputBubbleReturnLanding, target: Target, text: String, startedAt: Date) {
        let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log("[InputBubble] return posting", fields: [
            "landedBy": landedBy.rawValue,
            "waitedMs": String(waitedMs),
            "windowID": String(target.windowID)
        ])
        CrashContextRecorder.shared.record(
            "input_bubble_return landedBy=\(landedBy.rawValue) waitedMs=\(waitedMs) windowID=\(target.windowID)"
        )
        postKeyCombo(keyCode: CGKeyCode(kVK_Return), flags: [])
        let autoRestoreDecision = InputBubbleAutoRestoreGate.decide(
            preferenceEnabled: InputBubblePreferences.autoRestoreOnSubmit,
            submits: true,
            hasToggleRecord: ToggleEngine.shared.load(windowID: target.windowID) != nil,
            isOnMainScreen: WindowManager.shared.isWindowOnMainScreen(windowID: target.windowID)
        )
        let restoreWindowID = target.windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(InputBubbleTiming.clipboardRestoreDelayMs)) { [weak self] in
            self?.restoreClipboardIfSafe()
            self?.autoRestoreIfDecided(decision: autoRestoreDecision, windowID: restoreWindowID)
            self?.finishSubmission()
        }
    }

    /// B176：提交注入落地后按门决议归位（经 ToggleEngine 直调，与 UPS restoreToOriginal
    /// 同一执行入口；成功清 toggle 记录，~2s 后到达的 UPS 见无记录 → stay，无冲突）。
    /// B191：restore 下放 WindowWorkExecutor（B180 hook UPS 同款——装机 34 条 STALL
    /// 取证中本路径 0.26~2.3s 全部阻塞主线程=提交瞬间气泡/界面冻结主因）；归位在
    /// 后台串行队列执行，提交收尾立即返回，移动结果日志照常落账。
    private func autoRestoreIfDecided(decision: InputBubbleAutoRestoreGate.Outcome, windowID: UInt32) {
        guard decision == .restore else {
            log("[InputBubble] auto-restore skip", level: .debug, fields: [
                "outcome": String(describing: decision),
                "windowID": String(windowID)
            ])
            return
        }
        let traceID = "bubble-\(Int(Date().timeIntervalSince1970 * 1000))"
        Task { @MainActor in
            let outcome = await WindowWorkExecutor.run {
                ToggleEngine.shared.restore(
                    windowID: windowID,
                    triggerSource: "input_bubble_submit",
                    traceID: traceID
                )
            }
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
        // B196：气泡没了历史面板必联动收起（与 dismiss 同款）
        InputBubbleHistoryPanelController.shared.close()
        // B183：提交收尾终止跟随引擎与点击监视器（dismiss 路径同款）
        stopFollowing()
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
        keyEventPoster.post(keyCode: keyCode, flags: flags, keyDown: true)
        keyEventPoster.post(keyCode: keyCode, flags: flags, keyDown: false)
    }
}
