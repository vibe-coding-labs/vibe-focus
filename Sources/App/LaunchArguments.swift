import Foundation

struct LaunchArguments {
    static let shared = LaunchArguments()

    let skipLaunchWindow: Bool
    let showHealthCheck: Bool
    let debugMode: Bool
    let quickLaunch: Bool

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        log("LaunchArguments.init() parsing arguments", level: .debug, fields: ["count": String(arguments.count)])

        skipLaunchWindow = arguments.contains("--skip-launch-window") ||
                          arguments.contains("-s")
        showHealthCheck = arguments.contains("--health-check") ||
                         arguments.contains("-h")
        debugMode = arguments.contains("--debug") ||
                   arguments.contains("-d")
        quickLaunch = arguments.contains("--quick") ||
                     arguments.contains("-q")

        log("LaunchArguments.init() parsed flags", level: .debug, fields: [
            "skipLaunchWindow": String(skipLaunchWindow),
            "showHealthCheck": String(showHealthCheck),
            "debugMode": String(debugMode),
            "quickLaunch": String(quickLaunch)
        ])
    }

    static func printUsage() {
        print("""
        VibeFocus - 窗口聚焦工具

        用法: VibeFocus [选项]

        选项:
          -s, --skip-launch-window    跳过启动窗口
          -h, --health-check          启动时显示健康检查
          -d, --debug                 启用调试日志
          -q, --quick                 快速启动（跳过部分检查）
          --help                      显示此帮助信息

        示例:
          VibeFocus --debug
          VibeFocus -s -q
        """)
    }
}
