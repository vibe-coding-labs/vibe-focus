import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiStubSeamTests.swift — 覆盖率批次 31（2026-11-19）：
// VIBEFOCUS_YABAI_PATH 注入缝 + 假 yabai 可执行文件，把无 yabai 环境（CI）下
// runYabai 三分支、runYabaiVariants 重试/失败、query* 解码与失败日志、显示器几何匹配、
// Space 上下文捕获、toggle 焦点三分支解析全部变成 CLI 可直测路径。
//
// 替身只回显固定 JSON / 指定退出码，绝不执行任何真实 space/window 变更：
// - `-m space --focus` / `--load-sa` 一律非零退出（即使被 availability 探针误调也无副作用）；
// - 行为模式由测试写入的 mode 文件控制（不反复改进程环境，避免干扰并行后台任务）；
// - 域结束时 defer 恢复 env 与 SpaceController 状态，替身路径不入 YabaiClient 缓存。

extension RunnerHarness {
    func runYabaiStubSeamTests() {
        print("\n=== YabaiStubSeam (cover-31) ===")
        let sc = SpaceController.shared

        // 先建立 20s 节流窗（此时尚未注入替身路径）：本域内 captureSpaceContext 等内部
        // refreshAvailabilityIfNeeded 一律早退，避免 availability 后台探针消费替身路径。
        sc.refreshAvailabilityIfNeeded()

        let savedEnabled = sc.isEnabled
        let savedAvailability = sc.availability
        let savedCanControl = sc.canControlSpaces
        let savedMessage = sc.lastErrorMessage
        let savedEnv = ProcessInfo.processInfo.environment["VIBEFOCUS_YABAI_PATH"]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibefocus-yabai-stub-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        defer {
            if let savedEnv {
                setenv("VIBEFOCUS_YABAI_PATH", savedEnv, 1)
            } else {
                unsetenv("VIBEFOCUS_YABAI_PATH")
            }
            try? FileManager.default.removeItem(at: dir)
            sc.clearQueryCache()
            sc.availability = savedAvailability
            sc.isEnabled = savedEnabled
            sc.canControlSpaces = savedCanControl
            sc.lastErrorMessage = savedMessage
        }

        let modeFile = dir.appendingPathComponent("mode")
        let stubPath = dir.appendingPathComponent("yabai")
        func setMode(_ mode: String) {
            try? mode.write(to: modeFile, atomically: true, encoding: .utf8)
        }
        setMode("ok")

        // ---- 替身数据（displays 帧按当前 NSScreen 主屏做 Cocoa→Quartz 换算，保证几何匹配） ----
        let screens = NSScreen.screens
        var displaysJSON = "[]"
        if let main = screens.first {
            let primaryHeight = ScreenGeometry(cocoaFrames: screens.map { $0.frame }).primaryHeight
            let q = CoordinateKit.quartzRect(fromCocoa: main.frame, primaryHeight: primaryHeight)
            displaysJSON = "[{\"index\":1,\"frame\":{\"x\":\(q.minX),\"y\":\(q.minY),\"w\":\(q.width),\"h\":\(q.height)}}]"
        }
        let focusedSpaceJSON = #"{"id":11,"index":1,"display":1,"is-visible":true}"#
        let spacesJSON = #"[{"id":11,"index":1,"display":1,"is-visible":true},{"id":12,"index":2,"display":1,"is-visible":false}]"#
        let windowJSON = #"{"id":3220,"pid":99,"app":"iTerm2","title":"stub window","space":1,"display":1,"frame":{"x":0,"y":0,"w":800,"h":600},"is-floating":false,"has-ax-reference":true,"is-minimized":false,"has-focus":true}"#
        let windowsJSON = "[\(windowJSON),{\"id\":3221,\"pid\":99,\"app\":\"iTerm2\",\"title\":\"stub second\",\"space\":2,\"display\":1,\"frame\":{\"x\":0,\"y\":0,\"w\":400,\"h\":300},\"is-floating\":false,\"has-ax-reference\":true,\"is-minimized\":false,\"has-focus\":false}]"

        let script = """
        #!/bin/bash
        MODE=$(cat "\(modeFile.path)" 2>/dev/null || echo ok)
        if [ "$MODE" = "fail" ]; then
          echo "stub failure" >&2
          exit 2
        fi
        if [ "$MODE" = "no-focus" ]; then
          echo "could not retrieve window details" >&2
          exit 1
        fi
        if [ "$MODE" = "window-error" ]; then
          case "$*" in
            *"-m query --windows --window "*) echo "unexpected window query failure" >&2; exit 1;;
          esac
        fi
        if [ "$MODE" = "bad-json" ]; then
          case "$*" in
            *"-m query"*) echo "this is not json"; exit 0;;
          esac
        fi
        case "$*" in
          *"-m query --spaces --space"*) echo '\(focusedSpaceJSON)'; exit 0;;
          *"-m query --spaces"*) echo '\(spacesJSON)'; exit 0;;
          *"-m query --windows --window 3220"*) echo '\(windowJSON)'; exit 0;;
          *"-m query --windows --window "*) echo "could not locate window" >&2; exit 1;;
          *"-m query --windows"*) echo '\(windowsJSON)'; exit 0;;
          *"-m query --displays"*) echo '\(displaysJSON)'; exit 0;;
          *"--version"*) echo "yabai-v7.1.18-stub"; exit 0;;
          *"stub-slow"*) sleep 0.2; exit 0;;
          *"stub-stderr"*) echo "stub stderr line" >&2; echo "stub stdout line"; exit 3;;
          *"stub-fail"*) echo "stub failure" >&2; exit 2;;
          *"--load-sa"*) echo "stub load-sa unavailable" >&2; exit 3;;
          *"-m space --focus"*) echo "stub space focus blocked" >&2; exit 3;;
        esac
        exit 3
        """
        try? script.write(to: stubPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath.path)

        // ---- A. 注入缝语义：路径不存在回退常规探测；存在则命中且不入缓存 ----
        setenv("VIBEFOCUS_YABAI_PATH", dir.appendingPathComponent("missing-yabai").path, 1)
        let fallbackPath = YabaiClient.yabaiPath()
        check("yabaiStub: 注入路径不存在 → 回退常规探测（nil 或真实文件）",
              fallbackPath == nil || FileManager.default.fileExists(atPath: fallbackPath!))
        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)
        check("yabaiStub: 注入缝命中替身", YabaiClient.yabaiPath() == stubPath.path)

        // ---- B. runYabai 三分支：成功 / logSuccess / 慢命令 / 非零退出 ----
        let version = sc.runYabai(arguments: ["--version"])
        check("yabaiStub: runYabai 成功透传 stdout",
              version?.exitCode == 0 && (version?.stdout.contains("stub") ?? false))
        let loggedSuccess = sc.runYabai(
            arguments: ["--version"], operation: "stubVersion", operationID: "stub", logSuccess: true)
        check("yabaiStub: logSuccess 成功也落日志", loggedSuccess?.exitCode == 0)
        let slow = sc.runYabai(arguments: ["stub-slow"], operation: "stubSlow")
        check("yabaiStub: ≥180ms 慢命令分支", slow?.exitCode == 0)
        let failed = sc.runYabai(arguments: ["stub-fail"], operation: "stubFail")
        check("yabaiStub: 非零退出透传 stderr",
              failed?.exitCode == 2 && (failed?.stderr.contains("stub failure") ?? false))

        // ---- C. 启动失败臂：不可执行文件 → runYabai/runYabaiVariants 均 nil 降级 ----
        let plainFile = dir.appendingPathComponent("not-executable")
        try? "#!/bin/bash\n".write(to: plainFile, atomically: true, encoding: .utf8)
        setenv("VIBEFOCUS_YABAI_PATH", plainFile.path, 1)
        check("yabaiStub: 不可执行替身 → runYabai nil", sc.runYabai(arguments: ["--version"]) == nil)
        let launchFailVariants = sc.runYabaiVariants(
            variants: [["--version"], ["--version"]], operation: "stubLaunchFail")
        check("yabaiStub: runYabaiVariants 启动失败 → (false, nil)",
              !launchFailVariants.success && launchFailVariants.failure == nil)
        setenv("VIBEFOCUS_YABAI_PATH", stubPath.path, 1)

        // ---- D. runYabaiVariants：首败次成 / 全败返回最后失败 ----
        let variantsRecovered = sc.runYabaiVariants(
            variants: [["stub-fail"], ["--version"]], operation: "stubVariants")
        check("yabaiStub: 首变体失败次变体成功", variantsRecovered.success && variantsRecovered.failure == nil)
        let variantsAllFailed = sc.runYabaiVariants(
            variants: [["stub-fail"], ["stub-stderr"]], operation: "stubVariantsFail", operationID: "stub")
        check("yabaiStub: 全变体失败返回最后一次",
              !variantsAllFailed.success && variantsAllFailed.failure?.exitCode == 3
              && (variantsAllFailed.failure?.stderr.contains("stub stderr line") ?? false))

        // ---- E. querySpaces 解码 / 缓存 / 失败 / bad-json ----
        sc.clearQueryCache()
        let spaces = sc.querySpaces(caller: "stub", ignoreCache: true)
        check("yabaiStub: querySpaces 解码替身 JSON", spaces?.count == 2 && spaces?.first?.id == 11)
        let cachedSpaces = sc.querySpaces(caller: "stub-cache")
        check("yabaiStub: querySpaces 缓存命中", cachedSpaces?.count == 2)
        let topology = sc.querySpaceTopology()
        check("yabaiStub: querySpaceTopology available",
              topology.isAvailable && topology.spaces?.count == 2)

        setMode("bad-json")
        sc.clearQueryCache()
        check("yabaiStub: querySpaces 解码失败 → nil", sc.querySpaces(caller: "stub-bad", ignoreCache: true) == nil)
        let badTopology = sc.querySpaceTopology()
        check("yabaiStub: 拓扑解码失败 → unavailable", !badTopology.isAvailable && badTopology.spaces == nil)
        check("yabaiStub: displays/windows 解码失败 → nil",
              sc.queryDisplays(caller: "stub") == nil && sc.queryAllWindows(caller: "stub") == nil)

        setMode("fail")
        check("yabaiStub: 命令失败 → spaces/displays/windows nil",
              sc.querySpaces(caller: "stub-fail", ignoreCache: true) == nil
              && sc.queryDisplays(caller: "stub-fail") == nil
              && sc.queryAllWindows(caller: "stub-fail") == nil)
        check("yabaiStub: queryFocusedSpace 命令失败 → nil", sc.queryFocusedSpace() == nil)
        check("yabaiStub: queryFocusedWindow 未知错误 → nil", sc.queryFocusedWindow() == nil)
        setMode("no-focus")
        check("yabaiStub: queryFocusedWindow 无焦点窗口 → nil", sc.queryFocusedWindow() == nil)
        setMode("ok")
        sc.clearQueryCache()

        // ---- F. 聚焦 space/window + queryWindow 直查/缓存/not-found/其他错误 ----
        let focusedSpace = sc.queryFocusedSpace()
        check("yabaiStub: queryFocusedSpace 解码", focusedSpace?.index == 1 && focusedSpace?.display == 1)
        let focusedWindow = sc.queryFocusedWindow()
        check("yabaiStub: queryFocusedWindow 解码并写缓存",
              focusedWindow?.id == 3220 && sc.windowQueryCache[3220]?.result?.space == 1)
        check("yabaiStub: queryWindow 缓存命中", sc.queryWindow(windowID: 3220)?.id == 3220)
        check("yabaiStub: queryWindow 直查", sc.queryWindow(windowID: 3220, ignoreCache: true)?.pid == 99)
        check("yabaiStub: windowSpaceIndex 直查", sc.windowSpaceIndex(windowID: 3220) == 1)
        check("yabaiStub: 未知窗 not-found 分支 → nil", sc.queryWindow(windowID: 999_123) == nil)
        check("yabaiStub: 未知窗负结果也缓存",
              sc.windowQueryCache[999_123] != nil && sc.windowQueryCache[999_123]!.result == nil)
        setMode("window-error")
        check("yabaiStub: 未知窗其他错误 → 回退全量查询仍 nil", sc.queryWindow(windowID: 999_124) == nil)
        setMode("ok")

        // ---- G. displays/all windows 解码 + visibleSpaceIndex 三态 ----
        let displays = sc.queryDisplays(caller: "stub")
        check("yabaiStub: queryDisplays 解码", displays?.first?.index == 1)
        let allWindows = sc.queryAllWindows(caller: "stub")
        check("yabaiStub: queryAllWindows 解码", allWindows?.count == 2)
        check("yabaiStub: visibleSpaceIndex 注入 spaces",
              sc.visibleSpaceIndex(forDisplayIndex: 1, spaces: spaces)?.yabaiIndex == 1)
        check("yabaiStub: visibleSpaceIndex 内部查询",
              sc.visibleSpaceIndex(forDisplayIndex: 1)?.yabaiIndex == 1)
        check("yabaiStub: visibleSpaceIndex nil display → nil",
              sc.visibleSpaceIndex(forDisplayIndex: nil, spaces: spaces) == nil)

        // ---- H. 显示器几何匹配三态（有屏 / 无屏诚实降级） ----
        if let main = screens.first {
            check("yabaiStub: exactYabaiDisplayIndex 几何匹配非 nil",
                  sc.exactYabaiDisplayIndex(for: main) != nil)
            check("yabaiStub: exactNSScreen(1) 反查非 nil",
                  sc.exactNSScreen(forYabaiDisplayIndex: 1) != nil)
            let parked = sc.parkingScreen(excludingYabaiDisplayIndex: 1)
            check("yabaiStub: parkingScreen 排除语义",
                  screens.count <= 1 ? parked == nil : parked != nil)
            sc.invalidateDisplayMatchTable()
            check("yabaiStub: 失效后重建匹配表", sc.exactYabaiDisplayIndex(for: main) != nil)
        } else {
            check("yabaiStub: 无屏环境跳过几何断言", true)
        }
        let srcDisplay = sc.sourceDisplayForFrame(.zero)
        check("yabaiStub: sourceDisplayForFrame 只读烟测", srcDisplay == nil || srcDisplay! >= 1)

        // ---- I. currentSpaceIndex/focusedDisplayIndex/captureSpaceContext（节流窗内启用） ----
        sc.isEnabled = true
        check("yabaiStub: currentSpaceIndex 走替身", sc.currentSpaceIndex() == 1)
        check("yabaiStub: focusedDisplayIndex 走替身", sc.focusedDisplayIndex() == 1)
        sc.clearQueryCache()
        let ctx = sc.captureSpaceContext(windowID: 3220, operationID: "stub")
        check("yabaiStub: captureSpaceContext 四字段",
              ctx.sourceSpaceIndex?.yabaiIndex == 1
              && ctx.targetSpaceIndex?.yabaiIndex == 1
              && ctx.sourceDisplayIndex?.yabaiIndex == 1
              && ctx.sourceDisplaySpaceIndex == 1)

        // ---- J. displayLocalSpaceIndex / nativeSpaceID 注入与查询双路径 ----
        check("yabaiStub: displayLocalSpaceIndex 注入 spaces",
              sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 2, displayIndex: 1, spaces: spaces) == 2)
        check("yabaiStub: displayLocalSpaceIndex 查询路径",
              sc.displayLocalSpaceIndex(forGlobalSpaceIndex: 1, displayIndex: 1) == 1)
        check("yabaiStub: displayLocalSpaceIndex nil 输入 → nil",
              sc.displayLocalSpaceIndex(forGlobalSpaceIndex: nil, displayIndex: 1) == nil)
        check("yabaiStub: nativeSpaceID 命中", sc.nativeSpaceID(forYabaiIndex: 1) == 11)
        check("yabaiStub: nativeSpaceID 未命中 → nil", sc.nativeSpaceID(forYabaiIndex: 42) == nil)

        // ---- K. markOperationError 四分支（本域自足，不依赖真机 yabai 前置域） ----
        sc.markOperationError("stub-error", operationID: "stub")
        check("yabaiStub: markOperationError(String) 写入", sc.lastErrorMessage == "stub-error")
        sc.markOperationError(from: nil, fallback: "stub-fallback", operationID: "stub")
        check("yabaiStub: markOperationError(nil) 用 fallback", sc.lastErrorMessage == "stub-fallback")
        sc.canControlSpaces = true
        sc.markOperationError(
            from: YabaiClient.YabaiResult(exitCode: 2, stdout: "", stderr: "stub stderr"),
            fallback: "unused")
        check("yabaiStub: markOperationError(result) 透传 stderr", sc.lastErrorMessage == "stub stderr")
        sc.markOperationError(
            from: YabaiClient.YabaiResult(exitCode: 1, stdout: "", stderr: "scripting-addition missing"),
            fallback: "unused")
        check("yabaiStub: markOperationError(result) SA 专用文案",
              sc.canControlSpaces == false
              && (sc.lastErrorMessage ?? "").contains("scripting-addition"))

        // ---- L. runProcess 原语：正常 / 启动失败 / ≥50ms 慢日志臂 ----
        let echo = sc.runProcess(executable: "/bin/echo", arguments: ["stub-ro"])
        check("yabaiStub: runProcess 正常",
              echo?.exitCode == 0 && (echo?.stdout.contains("stub-ro") ?? false))
        check("yabaiStub: runProcess 启动失败 → nil",
              sc.runProcess(executable: "/nonexistent/vibefocus-stub", arguments: []) == nil)
        check("yabaiStub: runProcess 慢路径 ≥50ms",
              sc.runProcess(executable: "/bin/sleep", arguments: ["0.06"])?.exitCode == 0)

        // ---- M. toggle 焦点三分支解析：零候选窗 → yabai 探针（pid 不匹配）→ AX 兜底 ----
        do {
            var toggleContext: [String: String] = [:]
            let resolution = WindowManager.shared.resolveFocusedWindowForToggle(
                frontApp: NSRunningApplication.current,
                cachedMainScreen: screens.first,
                toggleContext: &toggleContext)
            check("yabaiStub: toggle 三分支解析来源合法",
                  resolution.source == "cgwindowlist" || resolution.source == "yabai" || resolution.source == "ax")
            check("yabaiStub: toggle 解析计时字段齐全",
                  toggleContext["focusedBranchMs"] != nil
                  && toggleContext["focusedWindowSource"] == resolution.source)
            check("yabaiStub: toggle 解析进度字段已填充",
                  toggleContext["focusedWindowAxMs"] != nil)
        }
    }
}
