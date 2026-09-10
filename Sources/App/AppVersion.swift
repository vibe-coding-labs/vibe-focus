import Foundation

/// Utility for reading the app version and build number at runtime.
enum AppVersion {
    /// 发布版本号单一事实源：build-release.sh / package_release.sh awk 提取此字面量
    /// 写入 Info.plist；运行时从 Info.plist 读回（AppVersion.current）。
    /// 2026-09-10 修复：原 `static let current（原字面量，x.y.z 为占位示例）` 改 computed 后两个脚本
    /// 提取静默失效，装机 Info.plist 一律退化为 0.0.0。
    static let releaseVersion = "0.0.22"

    static var current: String {
        // P-INST-105: 版本号读取耗时（Bundle.main.infoDictionary 字典查找 CFBundleShortVersionString；多处 UI 显示调用；进程启动缓存字典通常 <1ms）。
        #if PERF_INSTRUMENT
        let avcStart = Date()
        defer {
            log("AppVersion.current finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: avcStart))
            ])
        }
        #endif
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
