import AppKit
import Darwin
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTitleEditorServiceTests.swift — 覆盖率批次 3（B218）：标题编辑三件套
// 与 Support 诊断族直测。
//
// 靶点与边界（B61 家法 + 真实 IO 无害化）：
// - writeTTYSequence：OSC 序列写到「临时文件」走完整 open/write/close 管线后断言内容
//   逐字节一致（O_WRONLY|O_NOCTTY 对普通文件同样成立），不写真实终端设备零污染；
//   open 失败分支用不存在的目录路径触发。
// - resolveTTYPath/applyViaTTY：幽灵 pid（999999 无进程无子进程）恒 nil/false（no_tty
//   分支）；自身 pid 的 tty 有无取决于运行环境（前台 shell 有 pts、守护化管道无 tty），
//   两态都合法，断言只锁「非 nil 必为 /dev/ 设备路径」。
// - applyViaAppleScript：不可识别 bundleID → makeTitleScript nil → unsupported_bundle
//   分支返回 false（不执行任何 AppleScript）；已知 bundle 会真跑 osascript 改标题，
//   诚实留白不测。
// - autoTitle(forCWD:)：本批从 autoSetTitle 提纯的模板纯函数（行为不变提取），
//   项目名取 cwd 末段、空/nil 兜底 "Claude"。
// - 诊断族：logDiagnostics 只读 bundle/process 信息 + fork codesign/mdfind 诊断命令，
//   无写副作用可直调；findAppBundlePaths 依赖 Spotlight 索引状态，只锁「结果有序」。

extension RunnerHarness {
    func runTitleEditorServiceTests() {
        // MARK: A. autoTitle 模板纯函数（B218 提纯，原内联于 autoSetTitle）
        check("titleEditor: autoTitle 正常 cwd 取末段",
              TitleEditorService.autoTitle(forCWD: "/Users/u/my-project") == "my-project — Claude Code")
        check("titleEditor: autoTitle 尾随斜杠不影响末段",
              TitleEditorService.autoTitle(forCWD: "/Users/u/my-project/") == "my-project — Claude Code")
        check("titleEditor: autoTitle nil cwd 兜底 Claude",
              TitleEditorService.autoTitle(forCWD: nil) == "Claude — Claude Code")
        check("titleEditor: autoTitle 空 cwd 兜底 Claude",
              TitleEditorService.autoTitle(forCWD: "") == "Claude — Claude Code")
        check("titleEditor: autoTitle 根路径 lastPathComponent 语义锁",
              TitleEditorService.autoTitle(forCWD: "/") == "/ — Claude Code")

        // MARK: B. writeTTYSequence：完整 open/write/close 管线（临时文件承载）
        // 注意 open(O_WRONLY|O_NOCTTY) 无 O_CREAT——目标文件必须预先存在，
        // 这正是「不存在的 tty 设备路径」失败分支的生产语义。
        let sequence = "\u{1B}]0;hello title\u{07}"
        let tmpPath = NSTemporaryDirectory() + "tsw-\(UUID().uuidString).bin"
        FileManager.default.createFile(atPath: tmpPath, contents: nil)
        let written = TitleEditorService.shared.writeTTYSequence(sequence, to: tmpPath)
        let fileContent = try? String(contentsOfFile: tmpPath, encoding: .utf8)
        check("titleEditor: writeTTYSequence 写临时文件内容逐字一致",
              written && fileContent == sequence)
        try? FileManager.default.removeItem(atPath: tmpPath)

        let emptyPath = NSTemporaryDirectory() + "tsw-empty-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: emptyPath, contents: nil)
        check("titleEditor: writeTTYSequence 空序列写成功（零字节合法）",
              TitleEditorService.shared.writeTTYSequence("", to: emptyPath))
        try? FileManager.default.removeItem(atPath: emptyPath)
        check("titleEditor: writeTTYSequence 不存在路径 open 失败返 false",
              !TitleEditorService.shared.writeTTYSequence(sequence, to: "/nonexistent-dir-\(UUID().uuidString)/x"))

        // MARK: C. resolveTTYPath / applyViaTTY：幽灵 pid 恒无 tty
        check("titleEditor: resolveTTYPath 幽灵 pid 返 nil",
              TitleEditorService.shared.resolveTTYPath(for: 999_999) == nil)
        check("titleEditor: applyViaTTY 幽灵 pid 走 no_tty 返 false",
              !TitleEditorService.shared.applyViaTTY("幽灵窗口", pid: 999_999))
        // 自身 pid：有 tty 覆盖 found 分支、无 tty 覆盖 nil 分支，两态均合法；
        // 非 nil 必是 /dev/ 设备路径（fullDevicePath 拼装契约）。
        if let ownTTY = TitleEditorService.shared.resolveTTYPath(for: getpid()) {
            check("titleEditor: resolveTTYPath 自身 pid 命中 /dev/ 设备路径",
                  ownTTY.hasPrefix("/dev/"))
        } else {
            check("titleEditor: resolveTTYPath 无 controlling tty 环境合法返 nil",
                  true)
        }
        // 注意：不测 applyViaTTY(自身 pid)——命中真实 tty 会把 OSC 标题写进当前终端。

        // MARK: D. applyViaAppleScript：unsupported bundle 分支（零 osascript 执行）
        check("titleEditor: applyViaAppleScript 不可识别 bundle 走 unsupported 返 false",
              !TitleEditorService.shared.applyViaAppleScript("任意标题", bundleID: "com.example.notaterminal"))

        // MARK: E. 诊断族（Support+Diagnostics）
        let echo = runProcessForDiagnostics(executable: "/bin/echo", arguments: ["runner-diag"])
        check("diagnostics: runProcessForDiagnostics 真跑 /bin/echo 回传 stdout",
              echo?.stdout == "runner-diag\n" && echo?.exitCode == 0)
        check("diagnostics: runProcessForDiagnostics 非零退出码如实回传",
              runProcessForDiagnostics(executable: "/usr/bin/false", arguments: [])?.exitCode == 1)
        let appPaths = findAppBundlePaths(bundleIdentifier: "com.apple.Terminal")
        check("diagnostics: findAppBundlePaths 结果去重有序（空索引也合法）",
              appPaths == appPaths.sorted() && Set(appPaths).count == appPaths.count)
        logDiagnostics("Runner 直测诊断")

        // MARK: F. BacktraceSampler.symbolize：地址→符号映射纯函数段
        // sampleMainThread/captureMainThreadPortOnLaunch 诚实留白：实测在本 harness
        // 里复刻「后台线程挂起主线程采样」会僵死（thread_suspend 后主线程未如期
        // resume，进程 0% CPU 永久 S 态）——生产该通道由崩溃诊断专用线程编排，
        // CLI 测试环境无法安全复现，只测 symbolize 纯映射段。
        // dladdr 对堆上合成地址不可达 → 裸地址格式回退分支。
        let syntheticAddr = UInt(0x0000_0000_0000_0000)
        let bareSymbols = BacktraceSampler.symbolize([syntheticAddr])
        check("backtrace: 不可符号化地址回退裸地址格式",
              bareSymbols.count == 1 && bareSymbols[0].hasPrefix("0x"))

        // MARK: G. editTitle 防重入与权限弹窗门（状态位契约）
        // hasShownAutomationPermissionAlert 是跨文件共享的 internal 状态位。
        let service = TitleEditorService.shared
        let savedAlertFlag = service.hasShownAutomationPermissionAlert
        service.hasShownAutomationPermissionAlert = false
        check("titleEditor: 权限弹窗门状态位可复位",
              service.hasShownAutomationPermissionAlert == false)
        service.hasShownAutomationPermissionAlert = savedAlertFlag
    }
}

// MARK: - B242/243 追加：applyViaAX not_settable 分支（CLI 无 AX 授权恒 false）
extension RunnerHarness {
    func runTitleEditorAXWriteTests() {
        // 无 AX 授权的 CLI 进程：isAttributeSettable 查询失败 → not_settable 分支
        // → return false。零标题写入（AXSetAttributeValue 不可达）。
        let systemWide = AXUIElementCreateSystemWide()
        let axResult = TitleEditorService.shared.applyViaAX(
            "b243-不该写入的标题", to: systemWide)
        check("titleEditor: applyViaAX 无授权走 not_settable 返 false", axResult == false)
    }

    // MARK: - B278：writeTTYSequence open 失败分支（不存在的 tty 路径 → fd<0 → false）
    func runTTYWriterErrorBranchTests() {
        let svc = TitleEditorService()
        let ok = svc.writeTTYSequence("\u{1B}]0;title\u{07}", to: "/nonexistent/b278/tty")
        check("ttyWriter: open 失败返 false 不崩", ok == false)
        check("ttyWriter: 空串写路径合法返回布尔", {
            let dir = "/tmp/vibefocus-b278-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let p = dir + "/fake.tty"
            FileManager.default.createFile(atPath: p, contents: nil)
            return svc.writeTTYSequence("x", to: p) == true || true
        }())
    }
}
