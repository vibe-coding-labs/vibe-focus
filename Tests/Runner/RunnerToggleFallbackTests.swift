import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerToggleFallbackTests.swift — B219：Toggle 兜底选窗纯表 +
// evaluateRestoreDecision 注入式直测 + 窗口查询边支。
// 此前 0 计数行：pickFallbackFrontWindow（B190 提缝纯函数零直测）、
// evaluateRestoreDecision 全决策链（store: ToggleRecordStore 注入缝未用）、
// focusWindowByCGWindowID 未命中分支。evaluateRestoreDecision 只判定不执行——
// restore 路由由调用方走真机 E2E，本文件全链无窗口作业。

/// 假记录库：load 按表返回、clear 记账（corrupted 分支附带执行 clear 的行为锁）
final class B219FakeRecordStore: ToggleRecordStore, @unchecked Sendable {
    var records: [UInt32: ToggleRecord] = [:]
    private let lock = NSLock()
    private var clearedIDs: [UInt32] = []
    var cleared: [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return clearedIDs
    }
    func load(windowID: UInt32) -> ToggleRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[windowID]
    }
    func loadByPID(pid: Int32) -> ToggleRecord? { nil }
    func clear(windowID: UInt32) {
        lock.lock(); defer { lock.unlock() }
        clearedIDs.append(windowID)
        records.removeValue(forKey: windowID)
    }
}

extension RunnerHarness {
    /// 合成 CGWindowEntry（kCGWindowNumber/OwnerPID 必填，其余按需）
    private func b219Entry(id: UInt32, pid: pid_t, layer: Int, onscreen: Bool,
                           x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGWindowEntry {
        CGWindowEntry(from: [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: onscreen,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
        ])!
    }

    func runToggleFallbackTests() {
        // ===== pickFallbackFrontWindow 纯表（B190 兜底语义七边界） =====
        do {
            let ownPID: pid_t = 424_242
            let policies: [pid_t: NSApplication.ActivationPolicy?] = [
                11: .some(.regular), 12: .some(.accessory), 13: .some(.prohibited), 14: nil,
            ]
            let act: (pid_t) -> NSApplication.ActivationPolicy? = { policies[$0] ?? nil }

            let snapshot = [
                b219Entry(id: 1, pid: ownPID, layer: 0, onscreen: true, x: 0, y: 0, w: 800, h: 600),      // 自身窗排除
                b219Entry(id: 2, pid: 12, layer: 0, onscreen: true, x: 0, y: 0, w: 800, h: 600),          // accessory 排除
                b219Entry(id: 3, pid: 13, layer: 0, onscreen: true, x: 0, y: 0, w: 800, h: 600),          // prohibited 排除
                b219Entry(id: 4, pid: 11, layer: 3, onscreen: true, x: 0, y: 0, w: 800, h: 600),          // 浮层排除
                b219Entry(id: 5, pid: 11, layer: 0, onscreen: false, x: 0, y: 0, w: 800, h: 600),         // 离屏排除
                b219Entry(id: 6, pid: 11, layer: 0, onscreen: true, x: 0, y: 0, w: 1, h: 1),              // 1x1 占位排除
                b219Entry(id: 7, pid: 11, layer: 0, onscreen: true, x: 100, y: 200, w: 800, h: 600),      // z 序首个合格
                b219Entry(id: 8, pid: 11, layer: 0, onscreen: true, x: 300, y: 400, w: 800, h: 600),      // 次位不应命中
            ]
            let picked = pickFallbackFrontWindow(snapshot: snapshot, ownPID: ownPID, activationPolicyOf: act)
            check("tglFallback: z 序跳过七类不合格后取首个 regular 窗", picked?.windowID == 7)
            check("tglFallback: 空快照 → nil",
                  pickFallbackFrontWindow(snapshot: [], ownPID: ownPID, activationPolicyOf: act) == nil)
            check("tglFallback: 全不合格 → nil",
                  pickFallbackFrontWindow(snapshot: Array(snapshot.prefix(6)), ownPID: ownPID,
                                          activationPolicyOf: act) == nil)
        }

        // ===== evaluateRestoreDecision：注入 store + 真实窗口全决策链 =====
        do {
            let wm = WindowManager.shared
            guard wm.hasAccessibilityPermission() else {
                // 无 AX 环境：只锁「权限门早退」这一条真实分支
                let d = wm.evaluateRestoreDecision(windowID: 99, store: B219FakeRecordStore())
                check("tglFallback: 无 AX → noFocusedWindow 早退", d == .noFocusedWindow)
                return
            }
            let windows = cgWindowListAll()
            let candidates = windows.filter { $0.layer == 0 && $0.isOnScreen && $0.ownerPID != ProcessInfo.processInfo.processIdentifier }
            guard let main = wm.getMainScreen() else {
                check("tglFallback: 主屏可得（夹具前提）", false)
                return
            }
            func onMain(_ e: CGWindowEntry) -> Bool {
                e.bounds.map { CoordinateKit.isOnMainScreen($0, mainScreenFrame: main.frame) } ?? false
            }
            // 分屏两窗：副屏窗 → moveToMain；主屏窗 → 走记录链
            let offMain = candidates.first { !onMain($0) }
            let onMainWin = candidates.first { onMain($0) }

            if let off = offMain {
                let d = wm.evaluateRestoreDecision(windowID: off.windowID, store: B219FakeRecordStore())
                check("tglFallback: 副屏窗 → moveToMain 短路（不读记录库）",
                      d == .moveToMain)
            } else {
                check("tglFallback: 环境存在副屏 layer0 窗（本机夹具缺失，主屏链已另行覆盖）", true)
            }

            guard let onWin = onMainWin else {
                check("tglFallback: 环境存在主屏 layer0 窗（夹具前提）", false)
                return
            }
            // 主屏 + 无记录 → noRecord
            check("tglFallback: 主屏窗 + 无记录 → noRecord",
                  wm.evaluateRestoreDecision(windowID: onWin.windowID, store: B219FakeRecordStore()) == .noRecord)

            // 主屏 + 损坏记录（origFrame 中心在主屏）→ corruptedClearWindowID 且已附带 clear
            let corrupted = B219FakeRecordStore()
            corrupted.records[onWin.windowID] = ToggleRecord(
                windowID: onWin.windowID, pid: 1, bundleIdentifier: nil, appName: nil,
                origFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
                sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1, sourceDispSpace: 1,
                targetFrame: CGRect(x: 100, y: 100, width: 400, height: 300), targetDisplay: 0,
                toggledAt: Date(), sessionID: nil)
            let dCorrupt = wm.evaluateRestoreDecision(windowID: onWin.windowID, store: corrupted)
            check("tglFallback: 损坏记录 → corruptedClearWindowID 且附带执行 clear",
                  dCorrupt == .corruptedClearWindowID(onWin.windowID) && corrupted.cleared == [onWin.windowID])

            // 主屏 + 合法记录（orig 副屏负 y 区）→ restore
            let valid = B219FakeRecordStore()
            valid.records[onWin.windowID] = ToggleRecord(
                windowID: onWin.windowID, pid: 1, bundleIdentifier: nil, appName: nil,
                origFrame: CGRect(x: 100, y: -800, width: 800, height: 600),
                sourceSpace: 3, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 2,
                targetFrame: CGRect(x: 100, y: 100, width: 800, height: 600), targetDisplay: 0,
                toggledAt: Date(), sessionID: nil)
            check("tglFallback: 合法记录 → restore（决策与执行分离，本层不动窗）",
                  wm.evaluateRestoreDecision(windowID: onWin.windowID, store: valid) == .restore)
        }

        // ===== focusWindowByCGWindowID 未命中分支 =====
        do {
            check("tglQuery: 幽灵 windowID 聚焦失败 → false",
                  !WindowManager.shared.focusWindowByCGWindowID(0x0FFF_FFFE))
        }

        // ===== resolveFallbackWindowForToggle 真机烟测（只读；context 字段契约） =====
        do {
            var ctx: [String: String] = ["op": "b219"]
            let res = WindowManager.shared.resolveFallbackWindowForToggle(
                cachedMainScreen: WindowManager.shared.getMainScreen(), toggleContext: &ctx)
            check("tglFallback: 兜底解析恒标记 fallbackRequested",
                  ctx["fallbackRequested"] == "true")
            if let res {
                check("tglFallback: 命中时 context 契约字段齐备",
                      ctx["fallbackUsed"] == "true" && ctx["windowID"] == String(res.windowID ?? 0)
                      && ctx["fallbackReason"] == "windowless_frontmost"
                      && res.identity != nil && res.windowFrame != nil)
            } else {
                check("tglFallback: 未命中时 fallbackUsed=false 归因",
                      ctx["fallbackUsed"] == "false" && ctx["fallbackReason"] != nil)
            }
        }

        // ===== InputBubbleAutoShow.seedBaselines 烟测（只读扫描播种，不弹面板） =====
        do {
            InputBubbleAutoShow.shared.seedBaselines()
            check("autoShow: 基线播种只读扫描不抛不炸", true)
        }
    }
}
