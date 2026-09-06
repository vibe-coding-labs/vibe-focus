import SwiftUI
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
    }
}
