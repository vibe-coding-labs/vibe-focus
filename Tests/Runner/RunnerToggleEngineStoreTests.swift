import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerToggleEngineStoreTests.swift — B214：ToggleEngine save/load/loadByPID/clear
// 存储编排真身直测（此前仅 shouldRejectSave 纯判定有覆盖，实例方法 0%）。
// 注入缝 init(store:) 定向隔离 DB（生产单例恒走 WindowStateStore.shared，不触碰 ~/.vibefocus）。

extension RunnerHarness {
    func runToggleEngineStoreTests() {
        // ===== save → load 往返（origFrame 不在主屏=正常收单） =====
        do {
            let dir = "/tmp/vibefocus-teng-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let engine = ToggleEngine(store: WindowStateStore(dbPath: dir + "/teng.db"))

            let orig = CGRect(x: 9000, y: 9000, width: 800, height: 600)   // 主屏之外（Runner 无头会话也有真实屏）
            let target = CGRect(x: 100, y: 100, width: 800, height: 600)
            engine.save(windowID: 4242, pid: 1000, bundleIdentifier: "com.apple.Terminal",
                        appName: "Terminal", origFrame: orig,
                        sourceSpace: .yabai(3), sourceDisplay: .yabai(2), sourceYabaiDisp: .yabai(2),
                        sourceDispSpace: 2, targetFrame: target, targetDisplay: 0,
                        sessionID: nil, reason: .manualHotkey)
            let loaded = engine.load(windowID: 4242)
            var savedOK = false
            if let r = loaded {
                savedOK = r.windowID == 4242 && r.pid == 1000
                    && r.bundleIdentifier == "com.apple.Terminal" && r.appName == "Terminal"
                    && r.origFrame == orig && r.targetFrame == target
                    && r.sourceSpace == 3 && r.sourceYabaiDisp == 2 && r.sourceDispSpace == 2
                    && r.targetDisplay == 0 && r.reason == WindowMoveReason.manualHotkey.rawValue
                    && abs(r.toggledAt.timeIntervalSince1970 - Date().timeIntervalSince1970) < 60
            }
            check("tengStore: save→load 往返全字段就位", savedOK)

            // 主屏居中 origFrame → 拒收（数据异常防线走真身 save）
            engine.save(windowID: 4243, pid: 1000, bundleIdentifier: nil, appName: nil,
                        origFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
                        sourceSpace: .yabai(1), sourceDisplay: .yabai(1), sourceYabaiDisp: .yabai(1),
                        sourceDispSpace: 1, targetFrame: target, targetDisplay: 0, sessionID: nil)
            check("tengStore: 主屏 origFrame save 拒收不落库",
                  engine.load(windowID: 4243) == nil)

            // loadByPID fallback（CGWindowNumber 变化场景）
            check("tengStore: loadByPID 命中最近记录",
                  engine.loadByPID(pid: 1000)?.windowID == 4242)
            check("tengStore: loadByPID 未知 pid → nil",
                  engine.loadByPID(pid: 987654) == nil)

            // clear（restore 后清账）
            engine.clear(windowID: 4242)
            check("tengStore: clear 后 load → nil", engine.load(windowID: 4242) == nil)
            check("tengStore: clear 后 loadByPID → nil", engine.loadByPID(pid: 1000) == nil)

            // claudeSessionEnd reason 落库（B211 归因账本数据源）
            engine.save(windowID: 4244, pid: 2000, bundleIdentifier: nil, appName: nil,
                        origFrame: orig,
                        sourceSpace: .native(7), sourceDisplay: .cgDisplay(9), sourceYabaiDisp: .yabai(1),
                        sourceDispSpace: 1, targetFrame: target, targetDisplay: 0,
                        sessionID: "sess-1", reason: .claudeSessionEnd)
            check("tengStore: claudeSessionEnd reason+sessionID 落库",
                  engine.load(windowID: 4244)?.reason == WindowMoveReason.claudeSessionEnd.rawValue
                  && engine.load(windowID: 4244)?.sessionID == "sess-1")
        }
    }
}
