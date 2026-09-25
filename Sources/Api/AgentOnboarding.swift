import Foundation

// Agent 接入物料（2026-09-26 安全+上手批）：
// ① 接入提示词——一段可直接粘给任何 AI 的完整说明（含本机真实凭证与能力速览），
//    设置页一键复制；
// ② Claude 技能包（SKILL.md）——装入 ~/.claude/skills/vibefocus/，之后每个
//    Claude Code 会话原生自带「怎么用 vibe-focus」的知识，无需重复粘贴。
// 两者同源：正文都从 generateBody 派生（单一事实源），凭证由调用方传入。

enum AgentOnboarding {

    static let skillName = "vibefocus"

    static func skillDirectory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".claude/skills/\(skillName)")
    }

    static func skillFilePath(home: String = NSHomeDirectory()) -> String {
        (skillDirectory(home: home) as NSString).appendingPathComponent("SKILL.md")
    }

    // MARK: - 正文（提示词与技能包共用）

    static func generateBody(port: Int, token: String) -> String {
        """
        ## 连接凭证（本机授权，勿外传）
        - HTTP 命令接口：`http://127.0.0.1:\(port)/api/v1/*`
        - 鉴权 header：`X-VibeFocus-Token: \(token)`
        - 接口仅限本机回环访问；远程场景请走 SSH 隧道。

        ## 命令行（首选；读类免凭证、App 未运行也能用）
        ```
        VibeFocusHotkeys status                 # 状态总览
        VibeFocusHotkeys windows list           # 看见屏幕上的窗口（id/标题/位置/是否主屏）
        VibeFocusHotkeys sessions list          # live 会话与绑定
        VibeFocusHotkeys windows move-main --id <N>      # 窗口拉回主屏
        VibeFocusHotkeys windows layout --preset leftHalf # 前台窗摆位
        VibeFocusHotkeys grid create --rows 2 --cols 3   # 铺终端网格（需授权）
        VibeFocusHotkeys snapshot capture / restore [--id ...]  # 布局快照=撤销点
        VibeFocusHotkeys notify --text "需要你确认"       # 向用户发通知
        VibeFocusHotkeys settings get / settings set --key sound.volume --value 0.5
        ```

        ## 行为守则
        1. 动窗口/建网格/改设置前，先 `settings get` 或对应读接口确认现状；改动要留痕、可撤销（快照优先）。
        2. 分级授权由用户在设置页控制：只读默认开；摆窗口、建网格、改设置各自需要用户显式开启，未开启时接口会返回 403——如实告知用户，不要重试绕过。
        3. 永远不要尝试修改：热键、辅助功能权限、token、端口、Agent 授权开关本身（这些只读）。
        4. 向用户汇报时用 `notify`；等待用户输入时说明你已发通知。
        """
    }

    /// 设置页一键复制的完整提示词（比技能包多一段引子，可直接粘进对话）。
    static func generatePrompt(port: Int, token: String) -> String {
        """
        你可以通过以下方式操作本机的 VibeFocus（多终端会话编排工具：窗口进出主屏、铺终端网格、布局快照、会话通知）。

        \(generateBody(port: port, token: token))

        请先读取现状（windows list / sessions list / settings get）再行动；需要未授权能力时直接告诉我去设置页开启。
        """
    }

    /// Claude 技能包 SKILL.md（frontmatter + 正文）。
    static func generateSKILLMarkdown(port: Int, token: String) -> String {
        """
        ---
        name: \(skillName)
        description: 操作本机 VibeFocus——看窗口/会话、摆窗口、铺终端网格、布局快照与恢复、向用户发通知、读写白名单设置。用户提到窗口、格子、布局、提醒时使用。
        ---

        # VibeFocus Agent 接入

        \(generateBody(port: port, token: token))
        """
    }

    // MARK: - 技能包 IO 壳

    struct InstallResult: Equatable {
        let ok: Bool
        let changed: Bool
        let message: String
    }

    static func isSkillInstalled(home: String = NSHomeDirectory(), port: Int, token: String) -> Bool {
        let expected = generateSKILLMarkdown(port: port, token: token)
        guard let current = try? String(contentsOfFile: skillFilePath(home: home), encoding: .utf8) else {
            return false
        }
        return current == expected
    }

    @discardableResult
    static func installSkill(home: String = NSHomeDirectory(), port: Int, token: String) -> InstallResult {
        let dir = skillDirectory(home: home)
        let path = skillFilePath(home: home)
        let content = generateSKILLMarkdown(port: port, token: token)
        if let current = try? String(contentsOfFile: path, encoding: .utf8), current == content {
            return InstallResult(ok: true, changed: false, message: "技能包已是最新（\(path)）")
        }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            // 内含凭证：0600，与 hook-config.json 同标准。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return InstallResult(ok: true, changed: true, message: "已安装技能包（\(path)）")
        } catch {
            return InstallResult(ok: false, changed: false, message: "安装失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    static func uninstallSkill(home: String = NSHomeDirectory()) -> InstallResult {
        let path = skillFilePath(home: home)
        guard FileManager.default.fileExists(atPath: path) else {
            return InstallResult(ok: true, changed: false, message: "技能包未安装")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            // 目录若空一并摘除（不碰用户其他技能目录）。
            let dir = skillDirectory(home: home)
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir), entries.isEmpty {
                try? FileManager.default.removeItem(atPath: dir)
            }
            return InstallResult(ok: true, changed: true, message: "已卸载技能包")
        } catch {
            return InstallResult(ok: false, changed: false, message: "卸载失败：\(error.localizedDescription)")
        }
    }
}
