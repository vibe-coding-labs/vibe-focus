import AppKit
import Foundation

// MARK: - 输入气泡 · 绑定跟随（B319 拆分，行为不变）
// B183 autoHide=false 默认模式跟随族（startFollowing/stopFollowing/followTick）
// 整体逐字搬移自 InputBubbleController.swift；存储属性（followWindowOrigin/
// followBubbleOrigin/followTimer）留类体。
extension InputBubbleController {

    /// 启动跟随：基线 = 唤起时目标窗位置与气泡位置；0.2s 轮询目标窗位移。
    func startFollowing(targetCGFrame: CGRect, bubbleOrigin: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        followWindowOrigin = InputBubbleLayout.appKitFrame(
            fromCGFrame: targetCGFrame, primaryScreenHeight: primaryHeight
        ).origin
        followBubbleOrigin = bubbleOrigin
        followTimer?.invalidate()
        let controller = InputBubbleController.shared
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.followTick() }
            }
        }
    }

    /// 终止跟随（dismiss / 提交收尾 / 自动隐藏模式唤起时幂等清场）。
    func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        followWindowOrigin = nil
        followBubbleOrigin = nil
        removeClickMonitor()
        voiceYielded = false
    }

    /// 跟随拍：目标窗位移 → 气泡保偏移平移（夹进所在屏可视区）。
    /// bounds 读不到（最小化/目标窗关闭中）= 原地停驻不跳；目标进程消失 = 随之关闭。
    /// B190 区间埋点：5Hz 主线程周期作业（CGWindowList 单窗读），在「打字卡顿」归因里
    /// 必须有账可查；journal 静默（journalQuietSections）不刷 64 条环。
    func followTick() {
        PerfMonitor.shared.beginSection("bubble.followTick")
        defer { PerfMonitor.shared.endSection() }
        guard phase == .open, let target, let panel,
              let windowBefore = followWindowOrigin, let bubbleBefore = followBubbleOrigin else { return }
        if NSRunningApplication(processIdentifier: target.pid) == nil {
            log("[InputBubble] follow: target app gone, dismissing", level: .debug)
            dismiss(reactivateTarget: false, reason: "followTargetAppGone")
            return
        }
        guard let cgFrame = cgWindowBounds(for: target.windowID) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowNow = InputBubbleLayout.appKitFrame(
            fromCGFrame: cgFrame, primaryScreenHeight: primaryHeight
        ).origin
        let moved = InputBubbleLayout.followOrigin(
            bubbleOrigin: bubbleBefore,
            windowOriginBefore: windowBefore,
            windowOriginNow: windowNow
        )
        let appKitFrame = InputBubbleLayout.appKitFrame(fromCGFrame: cgFrame, primaryScreenHeight: primaryHeight)
        let clamped = InputBubbleLayout.clampedOrigin(
            position: moved,
            bubbleSize: panel.frame.size,
            visibleFrame: containingScreenVisibleFrame(for: appKitFrame)
        )
        if clamped != panel.frame.origin {
            suppressMoveTracking = true
            panel.setFrameOrigin(clamped)
            suppressMoveTracking = false
        }
        // 基线每拍推进（含未位移拍：窗口尺寸变化等场景不累积漂移）
        followWindowOrigin = windowNow
        followBubbleOrigin = clamped
        // B186：语音气泡让位巡检（每 5 拍≈1s；全表 CG 扫描频次控制在 ~5Hz→1Hz）
        voiceYieldScanCounter += 1
        if voiceYieldScanCounter % 5 == 0 {
            updateVoiceYield()
        }
    }

}
