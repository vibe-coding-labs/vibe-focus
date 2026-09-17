import SwiftUI
import ApplicationServices
import VibeFocusKit

@main
/// Main application entry point — menu bar resident app with no dock icon.
struct VibeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(HotKeyManager.shared)
        }
    }

    init() {
        // 崩溃管道自测：`VibeFocusHotkeys --crash-test-signal` 手工安装信号处理器、
        // 写启动审计后 raise(SIGTRAP)，端到端演练「审计行 + fatal 文本 + BACKTRACE +
        // 归档」全链路（SIGTRAP 类死亡无 .ips，本开关是唯一可主动触发的验证手段）。
        // 不取单实例锁、不启动 UI，对运行中的正式实例零影响。
        if CommandLine.arguments.contains("--crash-test-signal") {
            VibeFocusCrashPipeline.installHandlers()
            VibeFocusCrashPipeline.recordTestLaunch(
                bundleID: "crash-test",
                version: "test",
                exePath: CommandLine.arguments.first ?? "?"
            )
            FileHandle.standardError.write(Data("crash-test: raising SIGTRAP\n".utf8))
            raise(SIGTRAP)
        }
        // 一键取证：`VibeFocusHotkeys --diagnose` 汇总退出审计/致命记录/.ips/
        // keepalive 决策/应用日志错误，打印后即退（不进入事件循环、不取单实例锁）。
        // 2026-09-06 排查「莫名其妙退出」时证据散落 6 处全靠手工比对，本入口即其固化。
        if CommandLine.arguments.contains("--diagnose") {
            print(VibeFocusDoctor.report())
            fflush(stdout)
            exit(0)
        }
        // 轻量 AX 探针：`VibeFocusHotkeys --check-ax` 打印 ax=true/false 即退，
        // 退出码 0/3。deploy-release.sh 装机后验证用（tccd 竞态把新进程误标未授权
        // 时，装机脚本据此自动重启一次，见 2026-09-10 教训）。CLI 调用与 GUI 实例
        // 同一二进制同一 DR，tccd 视图一致（实证：竞态中毒期间终端跑 --diagnose
        // 同样报未授权，中毒进程死后转真）。
        if CommandLine.arguments.contains("--check-ax") {
            let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
            print("ax=\(trusted)")
            fflush(stdout)
            exit(trusted ? 0 : 3)
        }
        // 远程部署通道：`VibeFocusHotkeys --print-remote-install-script [host] [label]`
        // 打印远程一键安装脚本后即退（不进事件循环、不取单实例锁）。生成与偏好域
        // 读取细节见 RemoteInstallDeploy（kit 侧单一事实源）。
        if let script = RemoteInstallDeploy.scriptForArguments(CommandLine.arguments) {
            print(script)
            fflush(stdout)
            exit(0)
        }
        // B201 项目级 hook 安装通道：`--install-claude-hook-project <dir>` /
        // `--uninstall-claude-hook-project <dir>`。只写 <dir>/.claude/settings.json
        // （团队仓库/按项目选择性启用场景），转发器脚本与 token 仍归全局安装，
        // 项目目录不落敏感配置。即退不进事件循环、不取单实例锁。
        let cliArgs = CommandLine.arguments
        if let i = cliArgs.firstIndex(of: "--install-claude-hook-project"), cliArgs.count > i + 1 {
            let (ok, msg) = ProjectHookInstaller.install(cliArgs[i + 1])
            print((ok ? "OK: " : "FAIL: ") + msg)
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
        if let i = cliArgs.firstIndex(of: "--uninstall-claude-hook-project"), cliArgs.count > i + 1 {
            let (ok, msg) = ProjectHookInstaller.uninstall(cliArgs[i + 1])
            print((ok ? "OK: " : "FAIL: ") + msg)
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }
}
