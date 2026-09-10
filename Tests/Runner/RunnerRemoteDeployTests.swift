import Foundation
import CoreFoundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRemoteDeployTests.swift — B129：远程部署 CLI 通道直测
//（--print-remote-install-script 的旗标解析/偏好域注入/生成物保真）。
// domain 注入假域：token/port 注入路径全绿且不触碰真实装机偏好域。

extension RunnerHarness {
    func runRemoteDeployTests() {
        let flag = "--print-remote-install-script"
        let cleanDomain = "test.vf.b129.clean"
        let injectedDomain = "test.vf.b129.injected"

        // 1. 无旗标 → nil（调用方继续正常启动）
        check("remoteDeploy: 无旗标 → nil",
              RemoteInstallDeploy.scriptForArguments(["VibeFocusHotkeys"], domain: cleanDomain) == nil)

        // 2. 旗标 + 显式 host + label：生成物带 host/label/派生 label 兜底
        let script = RemoteInstallDeploy.scriptForArguments(
            [flag, "10.0.0.9", "remote-lab-9"], domain: cleanDomain)
        check("remoteDeploy: 显式 host 与 label 进生成物",
              script != nil && script!.contains("Target: 10.0.0.9:39277")
              && script!.contains("Machine label: remote-lab-9"))
        check("remoteDeploy: 生成物含 forwarder/config/claude+codex 四段",
              script!.contains("hook-forwarder.sh") && script!.contains("hook-config.json")
              && script!.contains("~/.claude/settings.json") && script!.contains("~/.codex/hooks.json"))

        // 3. label 缺省 → host 点转横杠派生
        let derived = RemoteInstallDeploy.scriptForArguments([flag, "10.0.0.9"], domain: cleanDomain)
        check("remoteDeploy: label 缺省 → remote-10-0-0-9 派生",
              derived?.contains("Machine label: remote-10-0-0-9") == true)

        // 4. 偏好域注入：假域写入 token/port → 生成物如实携带（用后清域）
        CFPreferencesSetAppValue("claudeHookToken" as CFString, "tok-b129" as CFString, injectedDomain as CFString)
        CFPreferencesSetAppValue("claudeHookPort" as CFString, 39999 as CFNumber, injectedDomain as CFString)
        CFPreferencesAppSynchronize(injectedDomain as CFString)
        let injected = RemoteInstallDeploy.scriptForArguments([flag, "10.0.0.9"], domain: injectedDomain)
        check("remoteDeploy: 假域 token/port 注入生成物",
              injected?.contains("tok-b129") == true && injected!.contains("39999"))
        CFPreferencesSetAppValue("claudeHookToken" as CFString, kCFNull as CFTypeRef?, injectedDomain as CFString)
        CFPreferencesSetAppValue("claudeHookPort" as CFString, kCFNull as CFTypeRef?, injectedDomain as CFString)
        CFPreferencesAppSynchronize(injectedDomain as CFString)

        // 5. 域为空 → token 兜底空串、port 兜底 39277（生成物仍可用）
        let empty = RemoteInstallDeploy.scriptForArguments([flag, "10.0.0.9"], domain: cleanDomain)
        check("remoteDeploy: 空域兜底 port=39277",
              empty?.contains("Target: 10.0.0.9:39277") == true)

        // 6. label 位置参数以 - 开头视为未提供（不吃掉后续旗标）
        let noLabel = RemoteInstallDeploy.scriptForArguments([flag, "10.0.0.9", "--verbose"], domain: cleanDomain)
        check("remoteDeploy: 以 - 开头的尾参不当作 label",
              noLabel?.contains("Machine label: remote-10-0-0-9") == true)
    }
}
