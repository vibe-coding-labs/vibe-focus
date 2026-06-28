import Foundation

/// Utility for reading the app version and build number at runtime.
enum AppVersion {
    static var current: String {
        // P-INST-105: 版本号读取耗时（Bundle.main.infoDictionary 字典查找 CFBundleShortVersionString；多处 UI 显示调用；进程启动缓存字典通常 <1ms）。
        let avcStart = Date()
        defer {
            log("AppVersion.current finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: avcStart))
            ])
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
