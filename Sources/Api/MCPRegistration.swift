import Foundation

// MCP 桥注册（design-agent-access.md A4）：把 VibeFocusMCP 桥写入 agent host 的
// MCP 配置，让 claude code / codex 的 Agent 原生拿到 vibefocus_* 工具族。
// 人的一次显式授权动作（设置页按钮），与 hook 一键安装同交互模式。
// 纯变换 + IO 壳分离（B50 家法）：变换零 IO 可 Runner 直测，IO 只做读写转发。

enum MCPRegistration {

    // MARK: - Host 与路径

    enum Host: String, CaseIterable {
        case claudeCode
        case codex

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex CLI"
            }
        }
    }

    static func claudeConfigPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".claude.json")
    }

    static func codexConfigPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".codex/config.toml")
    }

    /// 桥二进制安装位置：与主二进制同目录（run.sh 随包分发，见 run.sh MCP_BIN 段）。
    /// 非装机态（裸 Runner / 开发调试）返回 nil——注册前必须先升级安装。
    static func mcpBinaryPath(bundleExecutableURL: URL? = Bundle.main.executableURL) -> String? {
        guard let exe = bundleExecutableURL else { return nil }
        return exe.deletingLastPathComponent().appendingPathComponent("VibeFocusMCP").path
    }

    struct Outcome: Equatable {
        let content: String
        let changed: Bool
    }

    // MARK: - Claude Code（~/.claude.json 顶层 mcpServers）

    enum ClaudeMCPConfig {

        static func entry(command: String) -> [String: Any] {
            ["command": command, "args": [String]()]
        }

        /// upsert mcpServers.vibefocus。输入可为 nil（文件不存在→创建最小对象）；
        /// 非 JSON 对象 → nil（调用方报错，绝不覆盖损坏文件）。
        static func merge(_ existing: String?, command: String) -> Outcome? {
            var root: [String: Any]
            if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any] else {
                    return nil
                }
                root = obj
            } else {
                root = [String: Any]()
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [String: Any]()
            let entry = entry(command: command)
            if let before = servers["vibefocus"] as? [String: Any],
               NSDictionary(dictionary: before).isEqual(NSDictionary(dictionary: entry)) {
                return Outcome(content: existing ?? "{}", changed: false)
            }
            servers["vibefocus"] = entry
            root["mcpServers"] = servers
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                  let content = String(data: data, encoding: .utf8) else { return nil }
            return Outcome(content: content, changed: true)
        }

        /// 移除 mcpServers.vibefocus；表变空则连 mcpServers 键一起摘（不留空壳）。
        static func remove(_ existing: String?) -> Outcome? {
            guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any],
                  var servers = root["mcpServers"] as? [String: Any],
                  servers["vibefocus"] != nil else {
                return Outcome(content: existing ?? "", changed: false)
            }
            servers.removeValue(forKey: "vibefocus")
            var updatedRoot = root
            if servers.isEmpty {
                updatedRoot.removeValue(forKey: "mcpServers")
            } else {
                updatedRoot["mcpServers"] = servers
            }
            guard let data = try? JSONSerialization.data(withJSONObject: updatedRoot, options: [.prettyPrinted, .sortedKeys]),
                  let content = String(data: data, encoding: .utf8) else { return nil }
            return Outcome(content: content, changed: true)
        }

        static func isRegistered(_ existing: String?, expectedCommand: String) -> Bool {
            guard let existing,
                  let root = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let entry = servers["vibefocus"] as? [String: Any] else { return false }
            return (entry["command"] as? String) == expectedCommand
        }
    }

    // MARK: - Codex CLI（~/.codex/config.toml 标记块）

    enum CodexMCPConfig {

        static let beginMarker = "# BEGIN vibe-focus managed (mcp)"
        static let endMarker = "# END vibe-focus managed (mcp)"

        static func block(command: String) -> String {
            """
            \(beginMarker)
            [mcp_servers.vibefocus]
            command = "\(command)"
            \(endMarker)
            """
        }

        /// 幂等追加：先剥旧标记块再追加新块（重复点按钮不产生重复段）。
        static func append(_ existing: String?, command: String) -> Outcome {
            let base = existing ?? ""
            let stripped = removeBlock(base).content
            var out = stripped
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += block(command: command) + "\n"
            return Outcome(content: out, changed: out != base)
        }

        /// 只剥标记块之间的内容（含标记行），其余字节原样保留。
        static func removeBlock(_ existing: String?) -> Outcome {
            guard let existing else { return Outcome(content: "", changed: false) }
            var out: [String] = []
            var inBlock = false
            var removed = false
            for line in existing.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == beginMarker { inBlock = true; removed = true; continue }
                if trimmed == endMarker { inBlock = false; continue }
                if !inBlock { out.append(line) }
            }
            return Outcome(content: out.joined(separator: "\n"), changed: removed)
        }

        static func isRegistered(_ existing: String?, expectedCommand: String) -> Bool {
            guard let existing else { return false }
            return existing.contains(beginMarker)
                && existing.contains("[mcp_servers.vibefocus]")
                && existing.contains("command = \"\(expectedCommand)\"")
        }
    }

    // MARK: - IO 壳（读→纯变换→原子写）

    struct HostResult: Equatable {
        let host: Host
        let ok: Bool
        let changed: Bool
        let message: String
    }

    /// 读写单一 host。command 缺省=桥的装机路径；注入 command 供测试在临时 home 全链回环。
    static func register(
        _ host: Host,
        home: String = NSHomeDirectory(),
        command: String? = nil,
        fileExists: ((String) -> Bool)? = nil
    ) -> HostResult {
        let exists = fileExists ?? FileManager.default.fileExists
        let binary: String?
        if let command {
            // 注入命令（测试/高级用途）：不做存在性检查——注入方自证其路径。
            binary = command
        } else {
            // 生产路径：桥必须已随包落机，否则如实报缺（绝不写指向不存在二进制的注册）。
            guard let path = mcpBinaryPath(), exists(path) else {
                return HostResult(host: host, ok: false, changed: false,
                                  message: "未找到 VibeFocusMCP 桥——请先升级安装（桥随包分发）")
            }
            binary = path
        }
        guard let binary else {
            return HostResult(host: host, ok: false, changed: false, message: "无法定位桥路径")
        }
        switch host {
        case .claudeCode:
            let path = claudeConfigPath(home: home)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            guard let outcome = ClaudeMCPConfig.merge(existing, command: binary) else {
                return HostResult(host: host, ok: false, changed: false,
                                  message: "~/.claude.json 不是合法 JSON——请手动检查后再注册（我不会覆盖损坏文件）")
            }
            return writeResult(host: host, path: path, outcome: outcome)
        case .codex:
            let path = codexConfigPath(home: home)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            let outcome = CodexMCPConfig.append(existing, command: binary)
            return writeResult(host: host, path: path, outcome: outcome)
        }
    }

    static func unregister(_ host: Host, home: String = NSHomeDirectory()) -> HostResult {
        switch host {
        case .claudeCode:
            let path = claudeConfigPath(home: home)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            guard let outcome = ClaudeMCPConfig.remove(existing) else {
                return HostResult(host: host, ok: false, changed: false, message: "~/.claude.json 不是合法 JSON")
            }
            return writeResult(host: host, path: path, outcome: outcome)
        case .codex:
            let path = codexConfigPath(home: home)
            let existing = try? String(contentsOfFile: path, encoding: .utf8)
            let outcome = CodexMCPConfig.removeBlock(existing)
            return writeResult(host: host, path: path, outcome: outcome)
        }
    }

    static func status(_ host: Host, home: String = NSHomeDirectory(), command: String? = nil) -> Bool {
        let expected = command ?? mcpBinaryPath() ?? "\u{0}none"
        switch host {
        case .claudeCode:
            let existing = try? String(contentsOfFile: claudeConfigPath(home: home), encoding: .utf8)
            return ClaudeMCPConfig.isRegistered(existing, expectedCommand: expected)
        case .codex:
            let existing = try? String(contentsOfFile: codexConfigPath(home: home), encoding: .utf8)
            return CodexMCPConfig.isRegistered(existing, expectedCommand: expected)
        }
    }

    private static func writeResult(host: Host, path: String, outcome: Outcome) -> HostResult {
        guard outcome.changed else {
            return HostResult(host: host, ok: true, changed: false, message: "已是最新注册")
        }
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        do {
            try outcome.content.write(toFile: path, atomically: true, encoding: .utf8)
            return HostResult(host: host, ok: true, changed: true, message: "已写入 \(path)")
        } catch {
            return HostResult(host: host, ok: false, changed: false,
                              message: "写入失败：\(error.localizedDescription)")
        }
    }
}
