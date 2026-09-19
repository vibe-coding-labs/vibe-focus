// Tests/Runner/RunnerCaptureSeamTests.swift
// B233 覆盖堆叠·会话捕获编排注入缝：SessionRestoreController.CaptureDependencies
// （B232 SpoolProcessRunner 家法）——假 yabai 查询/假 AppleScript/假 classifyTTY/假探针
// 零 fork 零 AppleEvents 直驱 captureCurrentLayout 全编排；隔离 store 断言落库。
// restoreLayout 仅驱动「无快照」诚实失败路（命中即真重建窗口=动用户桌面，归真机 E2E）。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runCaptureSeamTests() {
        print("\n=== CaptureSeam (B233) ===")

        // 隔离 store（B216 家法：临时目录 DB）
        let dir = "/tmp/vibefocus-b233-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sut = SessionRestoreController(store: SessionRestoreStore(store: WindowStateStore(dbPath: dir + "/db.sqlite")))

        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> YabaiWindowInfo.Frame {
            YabaiWindowInfo.Frame(x: x, y: y, w: w, h: h)
        }
        func terminalWindow(id: Int, app: String = "Terminal") -> YabaiWindowInfo {
            YabaiWindowInfo(id: id, pid: 500, app: app, title: "b233",
                            space: 1, display: 1, frame: frame(0, 0, 800, 600),
                            isFloatingRaw: false, hasAXReferenceRaw: true,
                            isMinimizedRaw: false, hasFocusRaw: false)
        }
        let terminalBundle: (pid_t) -> String? = { _ in "com.apple.Terminal" }

        // 异步编排桥接（B154 家法）
        func runCapture(_ body: @escaping @Sendable @MainActor () async -> SessionRestoreController.OperationResult,
                        timeout: TimeInterval = 10) -> SessionRestoreController.OperationResult {
            final class Box: @unchecked Sendable { var value: SessionRestoreController.OperationResult? = nil }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = await body()
                sem.signal()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if sem.wait(timeout: .now() + 0.05) == .success { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return box.value ?? SessionRestoreController.OperationResult(ok: false, message: "timeout")
        }

        // 1) yabai 不可用（查询 nil）→ 诚实失败
        sut.captureDependencies.queryAllWindows = { nil }
        let r1 = runCapture { await sut.captureCurrentLayout() }
        check("capture: yabai 不可用诚实失败", !r1.ok && r1.message.contains("yabai 不可用"))

        // 2) 有窗但无可编排终端 → 诚实失败
        sut.captureDependencies.queryAllWindows = { [
            YabaiWindowInfo(id: 1, pid: 600, app: "Safari", title: "web",
                            space: 1, display: 1, frame: frame(0, 0, 800, 600),
                            isFloatingRaw: false, hasAXReferenceRaw: true,
                            isMinimizedRaw: false, hasFocusRaw: false)
        ] }
        let r2 = runCapture { await sut.captureCurrentLayout() }
        check("capture: 无可编排终端诚实失败", !r2.ok && r2.message.contains("没有发现可编排的终端窗口"))

        // 3) 超 64 格上限 → 桌面污染拒绝
        let flood = (1...65).map { terminalWindow(id: 100 + $0) }
        sut.captureDependencies.queryAllWindows = { flood }
        sut.captureDependencies.bundleIDOf = terminalBundle
        let r3 = runCapture { await sut.captureCurrentLayout() }
        check("capture: 超上限拒绝捕获", !r3.ok && r3.message.contains("超过单次捕获上限"))

        // 4) 正常捕获：1 Terminal 窗 + 假 tty 枚举 + 假分类 shell → 成功落库
        sut.captureDependencies.queryAllWindows = { [terminalWindow(id: 20)] }
        sut.captureDependencies.appleScript = { script in
            script.contains("ttys") || script.contains("tty") ? "20|ttys998\n" : ""
        }
        sut.captureDependencies.classifyTTY = { tty in
            PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil)
        }
        let r4 = runCapture { await sut.captureCurrentLayout(name: "B233-快照") }
        check("capture: 单 Terminal 窗成功", r4.ok && r4.message.contains("已捕获 1 窗"))
        check("capture: 快照落隔离库", sut.store.snapshots().count == 1)
        check("capture: 快照单 pane 落库（shell 分类）",
              sut.store.snapshots().first?.windows.first?.panes.count == 1)
        // 注：resolvePane 产出的 SessionPaneSnapshot 不透传 tty 字段（tty 只在
        // joinPanes 的 PaneTTY 骨架层用于分类键），快照层断言分类与目录即可
        check("capture: 自定义名称落库", sut.store.snapshots().first?.name == "B233-快照")

        // 5) 远程会话：tty 表挂分类键 + remoteSSH 分类 + 探针单条命中 → live 计数进摘要
        //（分类键来自 tty 枚举表——空 tty 的 pane 无分类机会，夹具必须给 tty）
        sut.captureDependencies.queryAllWindows = { [terminalWindow(id: 30)] }
        sut.captureDependencies.appleScript = { script in
            script.contains("tty of t") ? "30|ttys997\n" : ""
        }
        sut.captureDependencies.classifyTTY = { _ in
            PaneClassifier.Classification(kind: .remoteSSH, pid: nil,
                                          sshCommand: "ssh cc@host", sshTarget: "cc@host")
        }
        sut.captureDependencies.probeRemoteTargets = { targets in
            var result: [String: [RemoteSessionEntry]] = [:]
            for t in targets { result[t.target + "@" + (t.port ?? "")] = [
                RemoteSessionEntry(projectDir: "--b233", sessionID: "r-233", cwd: "/remote")
            ] }
            return result
        }
        let r5 = runCapture { await sut.captureCurrentLayout(name: "B233-远程") }
        check("capture: 远程会话成功且摘要带 live 计数",
              r5.ok && r5.message.contains("1 个远程会话"))
        check("capture: 远程 pane 命中探针会话",
              sut.store.snapshots().last?.windows.first?.panes.first?.sessionID == "r-233")

        // 6) restoreLayout：空库诚实失败（命中快照即真重建窗口=动用户桌面，归真机 E2E 不碰）
        let r6 = runCapture { await sut.restoreLayout(snapshotID: "nonexistent-b233") }
        check("capture: 无快照恢复诚实失败", !r6.ok && r6.message.contains("没有可恢复的布局快照"))
    }
}
