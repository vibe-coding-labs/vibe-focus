import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerMCPRegistrationTests.swift — MCP 桥注册纯变换直测（A4 批）。
// 覆盖：Claude ~/.claude.json merge（无键创建/已有表 upsert/内容不变不重写/损坏文件
// 拒绝覆盖/remove 空表连键摘）/Codex config.toml 标记块（幂等追加/剥块保留其余字节/
// isRegistered 命令比对）。IO 壳在临时 home 全链回环（register→status→unregister）。

extension RunnerHarness {
    func runMCPRegistrationTests() {
        let cmd = "/Applications/VibeFocus.app/Contents/MacOS/VibeFocusMCP"

        // MARK: A. Claude merge
        do {
            let fromNil = MCPRegistration.ClaudeMCPConfig.merge(nil, command: cmd)
            check("mcpReg: nil 文件→创建最小对象", fromNil != nil && fromNil!.changed)
            // ⚠️JSONSerialization 会把 "/" 转义为 "\/"（合法 JSON，任何解析器等价读回）——
            // 字符串包含断言只能锚定无斜杠段；消费方（isRegistered）走 JSON 解析不受影响。
            check("mcpReg: 创建内容含 mcpServers 表与桥名",
                  fromNil!.content.contains("mcpServers") && fromNil!.content.contains("VibeFocusMCP"))

            let idempotent = MCPRegistration.ClaudeMCPConfig.merge(fromNil!.content, command: cmd)
            check("mcpReg: 重复注册→changed=false 不重写", idempotent?.changed == false)

            let withOther = """
            {"otherSetting": true, "mcpServers": {"figma": {"command": "/x/figma"}}}
            """
            let merged = MCPRegistration.ClaudeMCPConfig.merge(withOther, command: cmd)
            check("mcpReg: 既有表 upsert 不动他人条目",
                  merged!.changed && merged!.content.contains("figma") && merged!.content.contains("vibefocus")
                      && merged!.content.contains("otherSetting"))

            let remerge = MCPRegistration.ClaudeMCPConfig.merge(merged!.content, command: cmd)
            check("mcpReg: upsert 后再注册→幂等", remerge?.changed == false)

            let corrupted = "{not json"
            check("mcpReg: 损坏文件→nil 拒绝覆盖",
                  MCPRegistration.ClaudeMCPConfig.merge(corrupted, command: cmd) == nil)

            let removed = MCPRegistration.ClaudeMCPConfig.remove(merged!.content)
            check("mcpReg: remove 摘条目留他人",
                  removed!.changed && !removed!.content.contains("vibefocus\"")
                      && removed!.content.contains("figma") && removed!.content.contains("otherSetting"))
            let removedAgain = MCPRegistration.ClaudeMCPConfig.remove(removed!.content)
            check("mcpReg: 无条目 remove→changed=false", removedAgain?.changed == false)
        }

        // MARK: B. Codex 标记块
        do {
            let fromNil = MCPRegistration.CodexMCPConfig.append(nil, command: cmd)
            check("mcpReg: codex nil→追加标记块",
                  fromNil.content.contains("[mcp_servers.vibefocus]") && fromNil.content.contains(cmd))

            let again = MCPRegistration.CodexMCPConfig.append(fromNil.content, command: cmd)
            check("mcpReg: codex 重复追加→幂等（无重复段）",
                  !again.changed && again.content.components(separatedBy: "[mcp_servers.vibefocus]").count == 2)

            let withExisting = """
            [mcp_servers.figma]
            command = "/x/figma"

            [mcp_servers.linear]
            command = "/x/linear"
            """
            let appended = MCPRegistration.CodexMCPConfig.append(withExisting, command: cmd)
            check("mcpReg: codex 既有段保留",
                  appended.content.contains("figma") && appended.content.contains("linear")
                      && appended.content.contains("vibefocus"))

            let stripped = MCPRegistration.CodexMCPConfig.removeBlock(appended.content)
            check("mcpReg: codex 剥块只摘自己",
                  stripped.changed && !stripped.content.contains("vibefocus")
                      && stripped.content.contains("figma") && stripped.content.contains("linear"))
            let strippedAgain = MCPRegistration.CodexMCPConfig.removeBlock(stripped.content)
            check("mcpReg: codex 无块 remove→changed=false", strippedAgain.changed == false)

            // 命令路径变化 → isRegistered 失配（装机路径更新后的「更新注册」语义）
            let stale = MCPRegistration.CodexMCPConfig.isRegistered(
                fromNil.content, expectedCommand: "/old/path/VibeFocusMCP")
            check("mcpReg: codex 路径漂移→isRegistered=false", stale == false)
        }

        // MARK: C. IO 壳临时 home 全链回环
        do {
            let tmp = NSTemporaryDirectory() + "vf-mcpreg-\(UUID().uuidString.prefix(8))"
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let reg = MCPRegistration.register(.claudeCode, home: tmp, command: cmd)
            check("mcpReg: IO 注册 ok", reg.ok && reg.changed)
            check("mcpReg: IO status 确认", MCPRegistration.status(.claudeCode, home: tmp, command: cmd))
            let un = MCPRegistration.unregister(.claudeCode, home: tmp)
            check("mcpReg: IO 注销 ok", un.ok && un.changed)
            check("mcpReg: IO 注销后 status=false", !MCPRegistration.status(.claudeCode, home: tmp, command: cmd))

            let codexReg = MCPRegistration.register(.codex, home: tmp, command: cmd)
            check("mcpReg: IO codex 注册 ok（父目录自动创建）", codexReg.ok && codexReg.changed)
            check("mcpReg: IO codex status 确认", MCPRegistration.status(.codex, home: tmp, command: cmd))

            // 未随包态（注入存在性检查恒 false——模拟裸进程无桥）→ 如实报缺
            let naked = MCPRegistration.register(.claudeCode, home: tmp, command: nil, fileExists: { _ in false })
            check("mcpReg: 无桥→报缺不写文件", !naked.ok && !naked.changed)
        }
    }
}
