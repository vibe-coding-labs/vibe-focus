// RemoteInstallDeploy.swift
// VibeFocus — 远程一键安装脚本的 CLI 部署通道
// `VibeFocusHotkeys --print-remote-install-script [host] [label]`：打印远程安装脚本
// 后即退（AppEntry 薄转发）。远程机器的转发器/hooks 部署以「仓库生成器忠实产物」
// 落机，杜绝手抄模板漂移（生成器行为测试见 RunnerRemoteInstallTests）。
// CLI 裸二进制无 bundle id，UserDefaults.standard 读不到装机应用的偏好域——
// 端口/token 经 CFPreferences 直读 AppIdentity.bundleID 域（单一事实源），以显式
// 参数传给生成器（不改写 CLI 自己的偏好域，零副作用）。

import Foundation

public enum RemoteInstallDeploy {

    /// 解析 `--print-remote-install-script [host] [label]` 旗标并生成安装脚本；
    /// 旗标不存在返回 nil（调用方继续正常启动）。host 缺省取本机活跃 LAN IP，
    /// label 缺省由 host 派生（remote-<点转横杠>）。
    public static func scriptForArguments(_ args: [String]) -> String? {
        guard let flagIdx = args.firstIndex(of: "--print-remote-install-script") else { return nil }
        func positional(_ offset: Int) -> String? {
            let i = flagIdx + offset
            return args.count > i && !args[i].hasPrefix("-") ? args[i] : nil
        }
        let host = positional(1) ?? LANHookPreferences.currentLANIP()
        let domain = AppIdentity.bundleID as CFString
        let token = CFPreferencesCopyAppValue("claudeHookToken" as CFString, domain) as? String
        let port = CFPreferencesCopyAppValue("claudeHookPort" as CFString, domain) as? Int
        return ClaudeHookPreferences.generateRemoteInstallScript(
            host: host,
            port: port ?? ClaudeHookPreferences.listenPort,
            token: token ?? "",
            labelOverride: positional(2)
        )
    }
}
