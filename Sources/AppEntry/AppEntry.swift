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
