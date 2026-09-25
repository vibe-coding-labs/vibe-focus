import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAgentOnboardingTests.swift — 接入物料与安全门直测（安全批）。
// 覆盖：回环-only 门矩阵（非回环对端 403 loopback_only）、接入提示词/技能包内容
// 契约（凭证/守则/frontmatter）、技能包 IO 临时 home 全链（安装→等值→卸载→空目录
// 摘除）。token 门本身已有 RunnerHookWalkTests/回环批锁定，此处不重复。

extension RunnerHarness {
    func runAgentOnboardingTests() {

        // MARK: A. 回环-only 门（命令面不随 LAN 暴露）
        do {
            // async handler 的同步包装：Task @MainActor 执行 + 主线程泵 RunLoop
            // （主线程阻塞会饿死 MainActor，短片等待+B232 泵法）。
            final class ResultBox: @unchecked Sendable {
                var value: (statusCode: Int, body: Data)?
            }
            func call(_ method: String, path: String, token: String?, peer: String?) -> (statusCode: Int, body: Data) {
                let box = ResultBox()
                let sem = DispatchSemaphore(value: 0)
                let query = token.map { ["token": $0] } ?? [:]
                Task { @MainActor in
                    let r = await ClaudeHookServer.shared.handleAgentAPIRequest(
                        method: method, path: path, body: Data("{}".utf8),
                        query: query, headers: [:], peerAddress: peer)
                    box.value = r
                    sem.signal()
                }
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if sem.wait(timeout: .now() + 0.05) == .success { break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                return box.value ?? (statusCode: -1, body: Data())
            }

            // 前序域可能把总开关留成关——本节只验证回环门，显式开总开关并恢复
            let savedEnabled = AgentAccessPreferences.isEnabled
            AgentAccessPreferences.isEnabled = true
            defer { AgentAccessPreferences.isEnabled = savedEnabled }
            let lan = call("GET", path: "/api/v1/status",
                           token: ClaudeHookPreferences.authToken, peer: "192.168.1.66")
            check("onboard: 非回环对端→403 loopback_only", lan.statusCode == 403)
            let local = call("GET", path: "/api/v1/status",
                             token: ClaudeHookPreferences.authToken, peer: "127.0.0.1")
            check("onboard: 回环对端→放行（200）", local.statusCode == 200)
            let ipv6 = call("GET", path: "/api/v1/status", token: nil, peer: "fe80::1")
            check("onboard: 非回环 IPv6→403", ipv6.statusCode == 403)
            // 回环门在最前：不向非本机泄露「token 是否正确」的任何信号
            let lanNoToken = call("GET", path: "/api/v1/status", token: nil, peer: "10.1.2.3")
            check("onboard: 非回环无 token→同样 403", lanNoToken.statusCode == 403)
        }

        // MARK: B. 提示词/技能包内容契约
        do {
            let prompt = AgentOnboarding.generatePrompt(port: 39277, token: "tkdemo")
            check("onboard: 提示词含端点与凭证",
                  prompt.contains("127.0.0.1:39277") && prompt.contains("X-VibeFocus-Token: tkdemo"))
            check("onboard: 提示词含行为守则与授权说明",
                  prompt.contains("行为守则") && prompt.contains("403") && prompt.contains("快照"))

            let skill = AgentOnboarding.generateSKILLMarkdown(port: 39277, token: "tkdemo")
            check("onboard: SKILL.md frontmatter 契约",
                  skill.hasPrefix("---\n") && skill.contains("name: vibefocus")
                      && skill.contains("description:"))
            check("onboard: SKILL.md 与提示词同源（守则段一致）",
                  skill.contains(AgentOnboarding.generateBody(port: 39277, token: "tkdemo")))
        }

        // MARK: C. 技能包 IO 全链（临时 home）
        do {
            let tmp = NSTemporaryDirectory() + "vf-onboard-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            check("onboard: 未安装时 status=false",
                  !AgentOnboarding.isSkillInstalled(home: tmp, port: 39277, token: "tkdemo"))
            let install = AgentOnboarding.installSkill(home: tmp, port: 39277, token: "tkdemo")
            check("onboard: 安装 ok", install.ok && install.changed)
            check("onboard: 安装后 status=true",
                  AgentOnboarding.isSkillInstalled(home: tmp, port: 39277, token: "tkdemo"))
            check("onboard: SKILL.md 权限 0600",
                  (try? FileManager.default.attributesOfItem(atPath: AgentOnboarding.skillFilePath(home: tmp))[.posixPermissions] as? Int) ?? 0 == 0o600)
            let again = AgentOnboarding.installSkill(home: tmp, port: 39277, token: "tkdemo")
            check("onboard: 重复安装→幂等", again.ok && !again.changed)
            let rotated = AgentOnboarding.installSkill(home: tmp, port: 39277, token: "tk-new")
            check("onboard: 凭证轮换→更新注册语义", rotated.ok && rotated.changed)

            let uninstall = AgentOnboarding.uninstallSkill(home: tmp)
            check("onboard: 卸载 ok", uninstall.ok && uninstall.changed)
            check("onboard: 卸载后文件不存在",
                  !FileManager.default.fileExists(atPath: AgentOnboarding.skillFilePath(home: tmp)))
            check("onboard: 空目录一并摘除",
                  !FileManager.default.fileExists(atPath: AgentOnboarding.skillDirectory(home: tmp)))
            let uninstallAgain = AgentOnboarding.uninstallSkill(home: tmp)
            check("onboard: 未安装卸载→幂等", uninstallAgain.ok && !uninstallAgain.changed)
        }
    }
}
