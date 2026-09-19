import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerBindingVerifierTests.swift — B214：SessionWindowRegistry.verifyBinding
// 真身直测（此前仅 decideBindingVerification 纯判定有覆盖，实例方法走真 CGWindowList /
// NSRunningApplication / kill 探活——Runner 无头会话均可真实执行）。

extension RunnerHarness {
    /// 构造最小 WindowState 夹具（仅 pid/windowID/bundleIdentifier 参与 verifyBinding）
    private func bvState(pid: Int32, windowID: UInt32, bundleID: String?) -> WindowState {
        var ws = WindowState(
            windowID: windowID, pid: pid, tty: nil, axWindowNumber: nil, appName: nil,
            bundleIdentifier: bundleID, title: nil, termSessionID: nil, itermSessionID: nil,
            sessionID: nil, bindingType: .local, isCompleted: false,
            createdAt: Date(), updatedAt: Date())
        ws.completedAt = nil
        return ws
    }

    func runBindingVerifierTests() {
        do {
            let dir = "/tmp/vibefocus-bv-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let reg = SessionWindowRegistry(store: WindowStateStore(dbPath: dir + "/bv.db"))
            let myPID = ProcessInfo.processInfo.processIdentifier

            // ===== pidNoLongerExists：进程不存在（macOS pid 上限 99998 以外的必然死 pid） =====
            check("bv: 死 pid → false（pidNoLongerExists）",
                  !reg.verifyBinding(bvState(pid: 999_999_99, windowID: 1, bundleID: nil)))

            // ===== pidMatches 探活路径（NSRunningApplication 命中，不走 kill 兜底） =====
            // ===== windowNotFound：pid 存活但 windowID 不在 CGWindowList =====
            check("bv: 活 pid + 幽灵 windowID → false（windowNotFound）",
                  !reg.verifyBinding(bvState(pid: myPID, windowID: 0x0FFF_FFFF, bundleID: nil)))

            // ===== 真实 CGWindowList 对账 =====
            let windows = cgWindowListAll()
            // 挑一个 layer 0 的在屏他属窗口（Dock/前台 app 必有；Runner 自身无窗口）
            guard let foreign = windows.first(where: { $0.layer == 0 && $0.isOnScreen && $0.ownerPID != myPID }) else {
                check("bv: 环境存在他属 layer0 在屏窗口（夹具前提）", false)
                return
            }
            // windowPIDMismatch：期望 pid=本进程（存活）但窗口属他进程
            check("bv: 活 pid + 他属真实窗口 → false（windowPIDMismatch）",
                  !reg.verifyBinding(bvState(pid: myPID, windowID: foreign.windowID, bundleID: nil)))
            // valid：pid 与 windowID 属主一致 → true
            check("bv: 属主 pid+windowID 全对 → true（valid）",
                  reg.verifyBinding(bvState(pid: foreign.ownerPID, windowID: foreign.windowID, bundleID: nil)))

            // pidMatches 快路径：用真实前台 app 的 bundleID+pid（NSRunningApplication 命中即存活）
            if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                check("bv: bundleID+pid NSRunningApplication 探活路径 → windowNotFound 分支可达",
                      !reg.verifyBinding(bvState(pid: dock.processIdentifier, windowID: 0x0FFF_FFFF,
                                                 bundleID: "com.apple.dock")))
            } else {
                check("bv: Dock 进程在跑（NSRunningApplication 夹具前提）", false)
            }
        }
    }
}
