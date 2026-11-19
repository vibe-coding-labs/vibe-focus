import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiDirectSeamTests.swift — 覆盖率批次 43（2026-11-19）：
// 补齐"只有真实 yabai 才走到"的 CLI 可测半区，全部经 VIBEFOCUS_YABAI_PATH 替身注入，
// 不执行任何真实 space/window 变更：
// ① YabaiClient 直通原语：run 成功/非零退出/启动异常(catch)/超时(terminate)、
//    queryJSON 解码/非 JSON/退出码守卫、runAsync/queryJSONAsync 全链；
// ② SpaceController.focusWindow 五分支：disabled / no_window(幽灵窗) / 不可管理→Carbon /
//    yabai 成功 / yabai 失败→Carbon 兜底；
// ③ WindowManager.focusWindowByCGWindowID 未命中（幽灵窗安全返回 false）；
// ④ SpaceController.applyAvailability 四态（launch 失败 / SA 已载 / SA 缺失 / 非零退出）；
// ⑤ ClaudeHookServer.buildSnapshotsBody 响应体、WindowManager.terminalScreenText 空树 nil。

private final class YabaiDirectResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// async 桥接（对齐 B154/B228 家法：Task + 短片泵主 RunLoop，30s 死线）。
private func runYabaiDirectAsync<T: Sendable>(
    _ block: @escaping @Sendable () async -> T
) -> T? {
    let box = YabaiDirectResultBox<T>()
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

extension RunnerHarness {
    func runYabaiDirectSeamTests() {
        print("\n=== YabaiDirectSeam (cover-43) ===")
        let sc = SpaceController.shared
        let wm = WindowManager.shared

        // 先建立 20s 节流窗（此时尚未注入替身）：域内任何内部 refreshAvailabilityIfNeeded
        // 都早退，避免后台探针消费替身路径或改写 isEnabled。
        sc.refreshAvailabilityIfNeeded()

        let savedEnabled = sc.isEnabled
        let savedAvailability = sc.availability
        let savedCanControl = sc.canControlSpaces
        let savedMessage = sc.lastErrorMessage
        let savedFocusKnownBroken = wm.focusSpaceKnownBroken
        let savedEnv = ProcessInfo.processInfo.environment["VIBEFOCUS_YABAI_PATH"]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibefocus-yabai-direct-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        defer {
            if let savedEnv {
                setenv("VIBEFOCUS_YABAI_PATH", savedEnv, 1)
            } else {
                unsetenv("VIBEFOCUS_YABAI_PATH")
            }
            try? FileManager.default.removeItem(at: dir)
            sc.clearQueryCache()
            sc.isEnabled = savedEnabled
            sc.availability = savedAvailability
            sc.canControlSpaces = savedCanControl
            sc.lastErrorMessage = savedMessage
            wm.focusSpaceKnownBroken = savedFocusKnownBroken
        }

        let modeFile = dir.appendingPathComponent("mode")
        let stubPath = dir.appendingPathComponent("yabai")
        func setMode(_ mode: String) {
            try? mode.write(to: modeFile, atomically: true, encoding: .utf8)
        }
        setMode("ok")

        let windowsJSON = #"[{"id":4000001,"pid":99,"app":"iTerm2","title":"stub focused","space":1,"display":1,"frame":{"x":0,"y":0,"w":800,"h":600},"is-floating":false,"has-ax-reference":true,"is-minimized":false,"has-focus":true},{"id":4000002,"pid":99,"app":"iTerm2","title":"stub second","space":2,"display":1,"frame":{"x":0,"y":0,"w":400,"h":300},"is-floating":false,"has-ax-reference":false,"is-minimized":false,"has-focus":false}]"#

        let script = """
        #!/bin/bash
        MODE=$(cat "\(modeFile.path)" 2>/dev/null || echo ok)
        if [ "$MODE" = "fail-focus" ]; then
          case "$*" in
            *"--focus"*) echo "stub focus rejected" >&2; exit 1;;
          esac
        fi
        if [ "$MODE" = "sa-probe-error" ]; then
          case "$*" in
            *"-m space --focus"*) echo "error with the scripting-addition" >&2; exit 1;;
          esac
        fi
        case "$*" in
          *"query --spaces --space"*) echo '{"id":11,"index":1,"display":1,"is-visible":true}'; exit 0;;
          *"query --windows --window "*) echo "could not locate window" >&2; exit 1;;
          *"query --windows"*) echo '\(windowsJSON)'; exit 0;;
          *"--version"*) echo "yabai-v7.1.18-stub"; exit 0;;
          *"stub-fail"*) echo "stub failure" >&2; exit 2;;
          *"stub-hang"*) sleep 3; exit 0;;
          *"--load-sa"*) echo "loaded"; exit 0;;
          *"--focus"*) exit 0;;
        esac
        exit 3
        """
        try? script.write(to: stubPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath.path)

        // 启动异常臂专用：存在但不可执行 → Process.run() throws → execute catch → nil
        let nonExecPath = dir.appendingPathComponent("not-executable")
        try? "#!/bin/bash\nexit 0\n".write(to: nonExecPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecPath.path)

        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)

        // ---- ① YabaiClient 直通原语 ----
        let okRun: YabaiClient.YabaiResult? = YabaiClient.run(arguments: ["--version"])
        check("yabaiDirect A1: run 成功 → exit 0 + stdout 透传",
              okRun?.exitCode == 0 && (okRun?.stdout.contains("yabai-v7.1.18-stub") ?? false))

        let failRun: YabaiClient.YabaiResult? = YabaiClient.run(arguments: ["stub-fail"])
        check("yabaiDirect A2: run 非零退出 → exit/stderr 透传",
              failRun?.exitCode == 2 && (failRun?.stderr.contains("stub failure") ?? false))

        setenv("VIBEFOCUS_YABAI_PATH", nonExecPath.path, 1)
        let launchFailRun: YabaiClient.YabaiResult? = YabaiClient.run(arguments: ["--version"])
        check("yabaiDirect A3: 不可执行文件 → run 返回 nil（catch 臂）", launchFailRun == nil)
        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)

        let timeoutRun: YabaiClient.YabaiResult? = YabaiClient.run(arguments: ["stub-hang"])
        check("yabaiDirect A4: 超过 commandTimeout → terminate + nil", timeoutRun == nil)

        let decoded = YabaiClient.queryJSON([YabaiWindowInfo].self, arguments: ["-m", "query", "--windows"])
        check("yabaiDirect A5: queryJSON 解码窗口数组",
              decoded?.count == 2 && decoded?.first?.hasAXReferenceRaw == true
                && decoded?.last?.hasAXReferenceRaw == false)

        check("yabaiDirect A6: queryJSON 非 JSON stdout → nil（解码守卫）",
              YabaiClient.queryJSON([YabaiWindowInfo].self, arguments: ["--version"]) == nil)

        check("yabaiDirect A7: queryJSON 非零退出 → nil（退出码守卫）",
              YabaiClient.queryJSON([YabaiWindowInfo].self, arguments: ["stub-fail"]) == nil)

        let asyncOkBox = runYabaiDirectAsync { await YabaiClient.runAsync(arguments: ["--version"]) }
        let asyncOk: YabaiClient.YabaiResult? = asyncOkBox ?? nil
        check("yabaiDirect A8: runAsync 成功 → exit 0 + stdout 非空",
              asyncOk?.exitCode == 0 && !(asyncOk?.stdout.isEmpty ?? true))

        let asyncFailBox = runYabaiDirectAsync { await YabaiClient.runAsync(arguments: ["stub-fail"]) }
        let asyncFail: YabaiClient.YabaiResult? = asyncFailBox ?? nil
        check("yabaiDirect A9: runAsync 非零退出透传", asyncFail?.exitCode == 2)

        setenv("VIBEFOCUS_YABAI_PATH", nonExecPath.path, 1)
        let asyncLaunchFailBox = runYabaiDirectAsync { await YabaiClient.runAsync(arguments: ["--version"]) }
        let asyncLaunchFail: YabaiClient.YabaiResult? = asyncLaunchFailBox ?? nil
        check("yabaiDirect A10: runAsync 启动异常 → nil", asyncLaunchFail == nil)
        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)

        let asyncDecodedBox = runYabaiDirectAsync {
            await YabaiClient.queryJSONAsync([YabaiWindowInfo].self, arguments: ["-m", "query", "--windows"])
        }
        let asyncDecoded: [YabaiWindowInfo]? = asyncDecodedBox ?? nil
        check("yabaiDirect A11: queryJSONAsync 解码窗口数组",
              asyncDecoded?.count == 2 && asyncDecoded?.first?.hasAXReferenceRaw == true)

        let asyncGuardBox = runYabaiDirectAsync {
            await YabaiClient.queryJSONAsync([YabaiWindowInfo].self, arguments: ["stub-fail"])
        }
        let asyncGuard: [YabaiWindowInfo]? = asyncGuardBox ?? nil
        check("yabaiDirect A12: queryJSONAsync 非零退出 → nil", asyncGuard == nil)

        // ---- ② SpaceController.focusWindow 五分支 ----
        let managed = YabaiWindowInfo(
            id: 4_000_001, pid: 99, app: "iTerm2", title: "stub focused",
            space: 1, display: 1, frame: nil,
            isFloatingRaw: false, hasAXReferenceRaw: true, isMinimizedRaw: false
        )
        let unmanaged = YabaiWindowInfo(
            id: 4_000_001, pid: 99, app: "iTerm2", title: "stub focused",
            space: 1, display: 1, frame: nil,
            isFloatingRaw: false, hasAXReferenceRaw: false, isMinimizedRaw: false
        )

        sc.clearQueryCache()
        setMode("ok")
        sc.isEnabled = false
        check("yabaiDirect B1: disabled → false（不发起任何 fork）",
              sc.focusWindow(4_000_001, knownWindowInfo: managed) == false)

        sc.isEnabled = true
        check("yabaiDirect B2: yabai --focus 成功 → true",
              sc.focusWindow(4_000_001, knownWindowInfo: managed) == true)

        setMode("fail-focus")
        check("yabaiDirect B3: yabai 失败 + Carbon 幽灵窗 → false（双失败）",
              sc.focusWindow(4_000_001, knownWindowInfo: managed) == false)

        setMode("ok")
        check("yabaiDirect B4: 不可管理窗口 → Carbon 兜底路径（幽灵窗 false）",
              sc.focusWindow(4_000_001, knownWindowInfo: unmanaged) == false)

        // 替身只回 id 4000001/4000002：用不在表内的 id 触发 queryWindow nil → no_window。
        sc.clearQueryCache()
        check("yabaiDirect B5: 未知窗口 → queryWindow nil → no_window false",
              sc.focusWindow(4_000_999, knownWindowInfo: nil) == false)

        // ---- ③ focusWindowByCGWindowID 未命中 ----
        check("yabaiDirect C1: CG 列表无此 windowID → false（幽灵窗安全路径）",
              wm.focusWindowByCGWindowID(4_000_001) == false)

        // ---- ④ applyAvailability 四态 ----
        // 统一用不存在的路径走 attemptSilentSARecovery：runProcess nil → 非 SIP 失败
        // → 不写持久化 verdict（无副作用）。
        let missingYabai = dir.appendingPathComponent("missing-yabai").path

        sc.applyAvailability(probe: SpaceController.AvailabilityProbe(
            spacesResult: nil, saLoaded: false, yabaiPath: missingYabai))
        check("yabaiDirect D1: launch 失败 → unavailable + 提示",
              sc.availability == .unavailable && sc.canControlSpaces == false
                && sc.lastErrorMessage == "Unable to launch yabai")

        sc.applyAvailability(probe: SpaceController.AvailabilityProbe(
            spacesResult: YabaiClient.YabaiResult(exitCode: 0, stdout: "[]", stderr: ""),
            saLoaded: true, yabaiPath: missingYabai))
        check("yabaiDirect D2: exit 0 + SA 已载 → available + canControl + 清错误 + 清 knownBroken",
              sc.availability == .available && sc.canControlSpaces == true
                && sc.lastErrorMessage == nil && wm.focusSpaceKnownBroken == false)

        wm.focusSpaceKnownBroken = true
        sc.applyAvailability(probe: SpaceController.AvailabilityProbe(
            spacesResult: YabaiClient.YabaiResult(exitCode: 0, stdout: "[]", stderr: ""),
            saLoaded: false, yabaiPath: missingYabai))
        check("yabaiDirect D3: exit 0 + SA 缺失 → available 但不可控 + SA 提示 + 清 knownBroken",
              sc.availability == .available && sc.canControlSpaces == false
                && (sc.lastErrorMessage?.contains("scripting-addition") ?? false)
                && wm.focusSpaceKnownBroken == false)

        sc.applyAvailability(probe: SpaceController.AvailabilityProbe(
            spacesResult: YabaiClient.YabaiResult(
                exitCode: 1, stdout: "", stderr: "stub probe exploded"),
            saLoaded: false, yabaiPath: missingYabai))
        check("yabaiDirect D4: 非零退出 → unavailable + 错误文案非空",
              sc.availability == .unavailable && sc.canControlSpaces == false
                && !(sc.lastErrorMessage ?? "").isEmpty)

        // ---- ④b attemptSilentSARecovery 成功落账 + 状态机闸门 ----
        // 直接读写 UserDefaults.standard 的恢复结局键（生产事实源），测试后原样还原；
        // 先清空以绕开宿主机器既有的历史结局，保证 CI/开发机双环境确定。
        let defaults = UserDefaults.standard
        let savedVerdict = defaults.string(forKey: "saRecoveryVerdict")
        let savedVerdictAt = defaults.object(forKey: "saRecoveryVerdictAt")
        let savedLegacyFailedAt = defaults.object(forKey: "scriptingAdditionRecoveryFailedAt")
        defaults.removeObject(forKey: "saRecoveryVerdict")
        defaults.removeObject(forKey: "saRecoveryVerdictAt")
        defaults.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")

        let savedRecovered = sc.scriptingAdditionRecoverySucceeded
        let savedCanControlForD5 = sc.canControlSpaces
        let savedMessageForD5 = sc.lastErrorMessage
        sc.scriptingAdditionRecoverySucceeded = false

        sc.attemptSilentSARecovery(yabaiPath: stubPath.path)
        check("yabaiDirect D5: --load-sa 成功 → 恢复标志/可控 + 落账 succeeded",
              sc.scriptingAdditionRecoverySucceeded && sc.canControlSpaces
                && defaults.string(forKey: "saRecoveryVerdict") == "succeeded")

        // succeeded 结局 → autoRecoveryAllowed false → 再次调用直接早退（不再 fork）。
        sc.canControlSpaces = false
        sc.lastErrorMessage = "sentinel-untouched"
        sc.attemptSilentSARecovery(yabaiPath: stubPath.path)
        check("yabaiDirect D6: succeeded 状态机闸门 → 直接早退（状态保持）",
              sc.canControlSpaces == false && sc.lastErrorMessage == "sentinel-untouched")

        sc.scriptingAdditionRecoverySucceeded = savedRecovered
        sc.canControlSpaces = savedCanControlForD5
        sc.lastErrorMessage = savedMessageForD5
        if let savedVerdict {
            defaults.set(savedVerdict, forKey: "saRecoveryVerdict")
        } else {
            defaults.removeObject(forKey: "saRecoveryVerdict")
        }
        if let savedVerdictAt {
            defaults.set(savedVerdictAt, forKey: "saRecoveryVerdictAt")
        } else {
            defaults.removeObject(forKey: "saRecoveryVerdictAt")
        }
        if let savedLegacyFailedAt {
            defaults.set(savedLegacyFailedAt, forKey: "scriptingAdditionRecoveryFailedAt")
        } else {
            defaults.removeObject(forKey: "scriptingAdditionRecoveryFailedAt")
        }

        // ---- ⑤ 快照列表响应体 + 空树 AX 文本 ----
        let snapshotsBody = ClaudeHookServer.buildSnapshotsBody()
        let snapshotsObj = (try? JSONSerialization.jsonObject(with: snapshotsBody)) as? [String: Any]
        let snapshotsData = snapshotsObj?["data"] as? [String: Any]
        let snapshotRows = snapshotsData?["snapshots"] as? [[String: Any]]
        check("yabaiDirect E1: buildSnapshotsBody → ok + count 与 snapshots 一致",
              (snapshotsObj?["ok"] as? Bool) == true
                && (snapshotsData?["count"] as? Int) == (snapshotRows?.count ?? -1))

        let ownApp = AXUIElementCreateApplication(getpid())
        check("yabaiDirect E2: terminalScreenText(本进程空树) → nil（降级兜底）",
              WindowManager.terminalScreenText(of: ownApp) == nil)

        // ---- ⑥ SessionRestoreEnvironment 默认实现接线（生产注入缝的 else 臂） ----
        // 仅调用无外部副作用的默认闭包：真实拉起应用/建窗（ensureTerminalRunning /
        // createTerminalCell）保持 B 态不碰。
        let env = SessionRestoreEnvironment()
        let defaultScreens = env.screens()
        check("yabaiDirect F1: screens 默认闭包透传 NSScreen.screens",
              defaultScreens.count == NSScreen.screens.count)
        if let main = defaultScreens.first {
            check("yabaiDirect F2: cgDisplayID/primaryDisplayID/quartzVisibleFrame 默认接线",
                  env.cgDisplayID(main) != nil && env.primaryDisplayID() != nil
                    && env.quartzVisibleFrame(main).width > 0)
            _ = env.exactYabaiDisplayIndex(main)
        }
        _ = env.automationInstanceRefusal("com.apple.Terminal", false)
        _ = env.automationInstanceRefusal("com.apple.Terminal", true)
        _ = env.querySpaces()
        _ = env.queryAllWindows()
        check("yabaiDirect F3: queryWindow 幽灵窗默认闭包 → nil",
              env.queryWindow(4_000_999) == nil)
        check("yabaiDirect F4: bundleIdentifierOfPID 幽灵 pid → nil",
              env.bundleIdentifierOfPID(pid_t(999_999_999)) == nil)
        check("yabaiDirect F5: classifyTTY 幽灵 tty → 降级 shell 分类",
              env.classifyTTY("/dev/ttys999").kind == .shell)
        _ = env.focusSpace(.yabai(1), "op-env-default")
        env.setWindowFloat(4_000_001, "op-env-default")
        _ = env.parkingScreen(1)
        env.runYabai(["-m", "query", "--spaces"], "env-default", "op-env-default")
        check("yabaiDirect F6: now 默认闭包返回当前时刻",
              abs(env.now().timeIntervalSinceNow) < 5)

        // ---- ⑦ yabaiPath 常规解析成功链 + 路径缓存（不经注入缝时的生产分支） ----
        // 把替身目录前置进 PATH、SHELL 固定为 /bin/bash，让 findViaUserShell /
        // findViaBashWhich 的 `which yabai` 真实命中替身（只做 which，不执行替身命令）。
        // 若宿主 mac 已装真实 yabai，同样命中成功臂——断言只要求「解析到真实存在的路径」。
        unsetenv("VIBEFOCUS_YABAI_PATH")
        let savedPathC = getenv("PATH").map { String(cString: $0) }
        let savedShellC = getenv("SHELL").map { String(cString: $0) }
        let fallbackPATH = savedPathC ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        setenv("PATH", "\(dir.path):\(fallbackPATH)", 1)
        setenv("SHELL", "/bin/bash", 1)

        let shellFound = YabaiClient.findViaUserShell()
        check("yabaiDirect G1: findViaUserShell 命中 PATH 内 yabai",
              shellFound != nil && FileManager.default.fileExists(atPath: shellFound!))
        let whichFound = YabaiClient.findViaBashWhich()
        check("yabaiDirect G2: findViaBashWhich 命中 PATH 内 yabai",
              whichFound != nil && FileManager.default.fileExists(atPath: whichFound!))
        let resolvedPath = YabaiClient.yabaiPath()
        check("yabaiDirect G3: 常规解析 → 非 nil 且入缓存",
              resolvedPath != nil && FileManager.default.fileExists(atPath: resolvedPath!))
        check("yabaiDirect G4: 第二次解析命中缓存（同一路径）",
              YabaiClient.yabaiPath() == resolvedPath)

        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)
        if let savedPathC {
            setenv("PATH", savedPathC, 1)
        } else {
            unsetenv("PATH")
        }
        if let savedShellC {
            setenv("SHELL", savedShellC, 1)
        } else {
            unsetenv("SHELL")
        }

        // ---- ⑧ SA 探针直调（availability 后台探测的生产入口） ----
        // 无 focused space / 探针无法启动 → false（CI 无 yabai 走第一卫；真机装 yabai 时
        // 走第二卫，两臂都为 false，断言跨环境稳定）。
        setMode("ok")
        // 撤掉注入：queryFocusedSpace 走常规解析（CI 恒 nil → 第一卫；真机有 yabai 时
        // 走第二卫 missing 路径），两臂都是 false。
        unsetenv("VIBEFOCUS_YABAI_PATH")
        check("yabaiDirect H1: 无 focused space 或探针启动失败 → SA 不可用",
              sc.checkScriptingAdditionLoaded(yabaiPath: missingYabai) == false)
        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)
        check("yabaiDirect H2: focused space + 探针 exit 0 → SA 可用",
              sc.checkScriptingAdditionLoaded(yabaiPath: stubPath.path))
        setMode("sa-probe-error")
        check("yabaiDirect H3: 探针 scripting-addition 报错 → SA 不可用",
              sc.checkScriptingAdditionLoaded(yabaiPath: stubPath.path) == false)
        setMode("ok")

        // ---- ⑨ 查询缓存辅助原语 ----
        check("yabaiDirect I1: isCacheExpired 过期/新鲜两态",
              sc.isCacheExpired(Date(timeIntervalSinceNow: -3600))
                && !sc.isCacheExpired(Date()))
        sc.clearWindowQueryCache()

        // 收尾：恢复注入前状态（defer 兜底，此处显式清缓存避免窗口查询缓存跨域污染）
        sc.clearQueryCache()
    }
}
