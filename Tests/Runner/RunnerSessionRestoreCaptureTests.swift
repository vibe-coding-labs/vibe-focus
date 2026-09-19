// Tests/Runner/RunnerSessionRestoreCaptureTests.swift
// B228 覆盖堆叠·会话采集决策层：SessionRestoreController 静态决策函数
// （isCapturableYabaiWindow 注入缝分支 / joinPanes 三来源 join / bundleIDForYabaiWindow
// 映射 / classifyTTY ps 落空 / resolvePane 六路 / probeRemoteTargets 空表与无效目标）。
// 全部纯决策或只读 fork——不建窗、不动用户终端。probeRemoteTargets 只探无效主机
// （DNS 落空快速失败），绝不 ssh 真实服务器。

import AppKit
import Foundation
@testable import VibeFocusKit

/// 泛型函数体内不允许嵌套类型（Swift 限制）——结果盒提到文件级
final class PaneProbeBox<T: Sendable>: @unchecked Sendable {
    var value: T? = nil
}

extension RunnerHarness {

    /// 异步静态函数桥接（B154 家法：Task + 短片泵主 RunLoop，30s 死线防插桩慢）
    private func runCaptureAsync<T: Sendable>(
        _ block: @escaping @Sendable () async -> T
    ) -> T? {
        let box = PaneProbeBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await block()
            sem.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if sem.wait(timeout: .now() + 0.05) == .success { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    private func captureWindow(
        id: Int?, pid: Int?, app: String?,
        frame: YabaiWindowInfo.Frame?, display: Int? = 1
    ) -> YabaiWindowInfo {
        YabaiWindowInfo(
            id: id, pid: pid, app: app, title: "b228",
            space: 1, display: display, frame: frame,
            isFloatingRaw: false, hasAXReferenceRaw: true,
            isMinimizedRaw: false, hasFocusRaw: false
        )
    }

    private func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> YabaiWindowInfo.Frame {
        YabaiWindowInfo.Frame(x: x, y: y, w: w, h: h)
    }

    // MARK: - isCapturableYabaiWindow（bundleIDOf 注入缝，判序穷尽）

    func runCapturableWindowTests() {
        print("\n=== CapturableWindow (B228) ===")
        let supported: (pid_t) -> String? = { _ in "com.apple.Terminal" }
        let unsupported: (pid_t) -> String? = { _ in "com.example.unknown" }
        let nilBundle: (pid_t) -> String? = { _ in nil }

        check("capture: pid nil 不可采",
              !SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: nil, app: "Terminal", frame: frame(0, 0, 800, 600)),
                bundleIDOf: supported))
        check("capture: frame nil 不可采",
              !SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: 100, app: "Terminal", frame: nil),
                bundleIDOf: supported))
        check("capture: 小窗（<100pt）不可采",
              !SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: 100, app: "Terminal", frame: frame(0, 0, 99, 600)),
                bundleIDOf: supported))
        check("capture: bundle 解析 nil 不可采",
              !SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: 100, app: "Terminal", frame: frame(0, 0, 800, 600)),
                bundleIDOf: nilBundle))
        check("capture: 支持集终端可采",
              SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: 100, app: "Terminal", frame: frame(0, 0, 800, 600)),
                bundleIDOf: supported))
        check("capture: 不支持集拒采",
              !SessionRestoreController.isCapturableYabaiWindow(
                captureWindow(id: 1, pid: 100, app: "Terminal", frame: frame(0, 0, 800, 600)),
                bundleIDOf: unsupported))
    }

    // MARK: - bundleIDForYabaiWindow（app 名 → bundle id 映射）

    func runBundleIDMappingTests() {
        print("\n=== BundleIDMapping (B228) ===")
        let iterm = captureWindow(id: 1, pid: 100, app: "iTerm2", frame: frame(0, 0, 800, 600))
        check("bundleID: iTerm2 映射",
              SessionRestoreController.bundleIDForYabaiWindow(iterm, pid: 100) == "com.googlecode.iterm2")
        let terminal = captureWindow(id: 2, pid: 100, app: "Terminal", frame: frame(0, 0, 800, 600))
        check("bundleID: Terminal 映射",
              SessionRestoreController.bundleIDForYabaiWindow(terminal, pid: 100) == "com.apple.Terminal")
        let unknown = captureWindow(id: 3, pid: 999_998, app: "SomeApp", frame: frame(0, 0, 800, 600))
        check("bundleID: 未知 app 幻影 pid 回落 app 名",
              SessionRestoreController.bundleIDForYabaiWindow(unknown, pid: 999_998) == "SomeApp")
    }

    // MARK: - joinPanes（yabai × iTerm2 × Terminal tty 三来源 join）

    func runJoinPanesTests() {
        print("\n=== JoinPanes (B228) ===")
        let rect = CGRect(x: 10, y: 20, width: 800, height: 600)

        // 1) frame nil 的窗口被跳过
        let skipped = SessionRestoreController.joinPanes(
            yabaiWindows: [captureWindow(id: 1, pid: 100, app: "Terminal", frame: nil)],
            itermEntries: [], terminalTTYs: [:])
        check("join: frame nil 窗跳过", skipped.isEmpty)

        // 2) iTerm2 窗 + 就近命中的 session 条目 → pane 来自条目并记 ASID
        let itermWin = captureWindow(id: 10, pid: 100, app: "iTerm2", frame: frame(10, 20, 800, 600))
        let entries = [
            ITermSessionEntry(windowASID: "asid-1", windowBounds: rect,
                              tabIndex: 1, sessionIndex: 1, tty: "/dev/ttys020", name: "proj"),
            ITermSessionEntry(windowASID: "asid-1", windowBounds: rect,
                              tabIndex: 1, sessionIndex: 2, tty: "/dev/ttys021", name: "shell"),
        ]
        let joined = SessionRestoreController.joinPanes(
            yabaiWindows: [itermWin], itermEntries: entries, terminalTTYs: [:])
        check("join: iTerm2 命中产一窗", joined.count == 1)
        check("join: iTerm2 pane 按 tab/session 序", joined[0].panes.map(\.tty) == ["/dev/ttys020", "/dev/ttys021"])
        check("join: iTerm2 ASID 记录", joined[0].itermWindowASID == "asid-1")

        // 3) Terminal 窗 + CGWindowID tty 表 → pane 来自表
        let termWin = captureWindow(id: 20, pid: 200, app: "Terminal", frame: frame(10, 20, 800, 600))
        let termJoined = SessionRestoreController.joinPanes(
            yabaiWindows: [termWin], itermEntries: [], terminalTTYs: [20: ["/dev/ttys030"]])
        check("join: Terminal tty 表命中", termJoined[0].panes.map(\.tty) == ["/dev/ttys030"])
        check("join: Terminal 无 ASID", termJoined[0].itermWindowASID == nil)

        // 4) Terminal 窗无 tty 表 → 兜底一个空 pane（窗级绑定仍有机会）
        let emptyJoined = SessionRestoreController.joinPanes(
            yabaiWindows: [termWin], itermEntries: [], terminalTTYs: [:])
        check("join: 无 tty 兜底空 pane",
              emptyJoined[0].panes.count == 1 && emptyJoined[0].panes[0].tty == nil)
    }

    // MARK: - classifyTTY / resolvePane / probeRemoteTargets（IO 落空与决策路）

    func runPaneResolveTests() {
        print("\n=== PaneResolve (B228) ===")

        // classifyTTY：不存在的 tty → ps 落空回落 shell 分类
        let cls = SessionRestoreController.classifyTTY("/dev/ttys997")
        check("pane: 幻影 tty 分类回落 shell", cls.kind == .shell && cls.pid == nil)

        // resolvePane 六路（全部无真实 IO 或只读落空；async 调用整体入闭包）
        let localHookValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .localClaude, pid: nil, sshCommand: nil, sshTarget: nil),
                hookSessionID: "b228-s1", hookCWD: "/tmp/b228", paneTitle: "t",
                probeResults: [:])
        }
        check("pane: localClaude hook 绑定优先",
              localHookValue?.kind == .localClaude && localHookValue?.sessionID == "b228-s1")

        let localNoPIDValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .localClaude, pid: nil, sshCommand: nil, sshTarget: nil),
                hookSessionID: nil, hookCWD: nil, paneTitle: nil,
                probeResults: [:])
        }
        check("pane: localClaude 无绑定无 pid 退 shell", localNoPIDValue?.kind == .shell)

        let remoteNoTargetValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .remoteSSH, pid: nil,
                                                              sshCommand: "ssh somewhere", sshTarget: nil),
                hookSessionID: nil, hookCWD: nil, paneTitle: nil,
                probeResults: [:])
        }
        check("pane: remoteSSH 无目的地保留原命令行回放",
              remoteNoTargetValue?.kind == .remoteSSH && remoteNoTargetValue?.sshCommand == "ssh somewhere")

        let remoteHookValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .remoteSSH, pid: nil,
                                                              sshCommand: "ssh cc@host", sshTarget: "cc@host"),
                hookSessionID: "b228-r1", hookCWD: "/remote", paneTitle: nil,
                probeResults: [:])
        }
        check("pane: remoteSSH hook 绑定取绑定 cwd/session",
              remoteHookValue?.sessionID == "b228-r1" && remoteHookValue?.cwd == "/remote"
              && remoteHookValue?.wasRemoteSessionLive == false)

        let remoteNoHookValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .remoteSSH, pid: nil,
                                                              sshCommand: "ssh cc@host", sshTarget: "cc@host"),
                hookSessionID: nil, hookCWD: nil, paneTitle: nil,
                probeResults: ["cc@host@": [
                    RemoteSessionEntry(projectDir: "--b228a", sessionID: "r1", cwd: "/x"),
                    RemoteSessionEntry(projectDir: "--b228b", sessionID: "r2", cwd: "/y"),
                ]])
        }
        check("pane: remoteSSH 探针命中不匹配→live 标记",
              remoteNoHookValue?.sessionID == nil && remoteNoHookValue?.wasRemoteSessionLive == true)

        let shellPaneValue = runCaptureAsync {
            await SessionRestoreController.resolvePane(
                classification: PaneClassifier.Classification(kind: .shell, pid: nil, sshCommand: nil, sshTarget: nil),
                hookSessionID: nil, hookCWD: nil, paneTitle: nil,
                probeResults: [:])
        }
        check("pane: shell 空信息如实保留", shellPaneValue?.kind == .shell && shellPaneValue?.cwd == nil)

        // probeRemoteTargets：空表直返；无效主机探针落空（DNS 失败快速返回，绝不碰真实服务器）
        let emptyProbe = runCaptureAsync { await SessionRestoreController.probeRemoteTargets([]) }
        check("pane: 空探针表直返空字典", (emptyProbe ?? [:]).isEmpty)
        let deadProbe = runCaptureAsync {
            await SessionRestoreController.probeRemoteTargets([("b228-invalid-host", nil)])
        }
        check("pane: 无效主机探针落空空条目", deadProbe?["b228-invalid-host@"]?.isEmpty == true)
    }
}
