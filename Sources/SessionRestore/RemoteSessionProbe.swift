import Foundation

// MARK: - 远程 Claude 会话探针
/// Mac 重启不杀远程进程，但远程 claude 会话的元数据（session id ↔ 项目目录）
/// 只存在远程机 `~/.claude/projects/` 里。本探针经既有 SSH 通道（免密 key）
/// 枚举远端项目目录与最新 session 文件，供捕获时给 remoteSSH pane 定位会话。
/// 全程 best-effort：ssh 不通 / 无免密 / 超时 → 返回空，调用方诚实降级
/// （只回放 ssh 命令，不带 --resume），绝不阻塞捕获。

/// 远端一个项目的最新会话
struct RemoteSessionEntry: Equatable {
    /// 远端 projects 目录名（cwd 经 Claude 转义规则映射，不可逆；匹配走正向转义）
    let projectDir: String
    let sessionID: String
    /// 会话 jsonl 首行的 `"cwd"` 真值（远端真实工作目录；`claude --resume` 按
    /// cwd 定位项目目录，没有它 resume 会扑空——必须 cd 回去）。缺失为 nil。
    let cwd: String?
}

enum RemoteSessionProbe {

    /// 远端执行的 POSIX sh 探针脚本：逐项目目录取最新 jsonl。
    /// 兼容 Linux/macOS 远端（只用 sh + ls + grep）。输出 `PROJ|<dir>|<sessionID>` 行。
    /// 转义边界：脚本内**只允许双引号**——整段以单引号包裹交给远端 `sh -c`，
    /// 出现单引号会撕开包裹（Runner 锁定 noSingleQuotes 契约）。
    /// ⚠️ Swift 字面量转义边界（2026-09-14 真机 E2E 抓到的产品 bug）：grep 模式
    /// 需要 shell 层的 `\"`（双引号内的字面引号），Swift 源码必须写 `\\\"`——
    /// 写 `\"` 会被 Swift 编译期吞成裸 `"`，远端收到 `""cwd":"[^"]*""` 直接语法
    /// 错误，探针永远空手而归（真机实锤：快照 remoteLive=0，远程恢复整体降级
    /// 裸回放不带 --resume）。
    static let probeScript = """
        cd "$HOME/.claude/projects" 2>/dev/null || exit 0
        for d in */; do
            f=$(ls -t "./$d" 2>/dev/null | grep .jsonl | head -1)
            if [ -n "$f" ]; then
                w=$(grep -o -m 1 "\\\"cwd\\\":\\\"[^\\\"]*\\\"" "./$d$f" 2>/dev/null | head -1)
                echo "PROJ|$d|$f|$w"
            fi
        done
        """

    /// 单引号契约：probeScript 内不得出现单引号（外层包裹完整性）
    static func scriptHasNoSingleQuotes() -> Bool {
        !probeScript.contains("'")
    }

    /// 远端命令单串（ssh 的最后一个 argv 元素；远端登录 shell 解析）
    static var remoteCommand: String {
        "sh -c '" + probeScript + "'"
    }

    /// 解析探针 stdout。边界（Runner 锁定）：非 PROJ 前缀行跳过；字段数<3 跳过；
    /// session 文件名须 .jsonl 结尾（截为 sessionID）；目录名/sessionID 空跳过；
    /// cwd 段形如 `"cwd":"/path"`（缺段/空串/非该形态 → nil）。
    static func parseProbeOutput(_ stdout: String) -> [RemoteSessionEntry] {
        var result: [RemoteSessionEntry] = []
        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("PROJ|") else { continue }
            let fields = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard fields.count >= 3 else { continue }
            let file = fields[2]
            guard let sessionID = ClaudeSessionLocator.sessionID(fromSessionFileName: file) else { continue }
            // 探针 echo 的是 glob `*/` 展开值，目录名带尾斜杠，剥掉再入库
            var dir = fields[1]
            while dir.hasSuffix("/") { dir.removeLast() }
            guard !dir.isEmpty else { continue }
            result.append(RemoteSessionEntry(projectDir: dir, sessionID: sessionID, cwd: Self.parseCWDField(fields.count >= 4 ? fields[3] : nil)))
        }
        return result
    }

    /// cwd 段 → 路径（形如 `"cwd":"/x/y"`）；其它形态 nil
    static func parseCWDField(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("\"cwd\":\""), raw.hasSuffix("\""), raw.count > 9 else { return nil }
        let path = String(raw.dropFirst("\"cwd\":\"".count).dropLast())
        return path.isEmpty ? nil : path
    }

    /// pane 的远程 cwd → 远端会话匹配（信号链，前者精确后者启发）：
    /// 1. cwd 正向转义（ClaudeSessionLocator.escapedProjectDir）后精确命中 → 用它；
    /// 2. 标题后缀匹配：pane 标题（远端常设为项目名）与转义目录名尾部命中且唯一 → 用它；
    /// 3. 未知 cwd 且恰好只有一个项目 → 用它；
    /// 4. 其余（多项目且无可靠信号）→ nil（宁可不 resume 也不能接错会话）。
    static func matchSession(
        remoteCWD: String?, paneTitle: String?, entries: [RemoteSessionEntry]
    ) -> RemoteSessionEntry? {
        guard !entries.isEmpty else { return nil }
        if let cwd = remoteCWD, !cwd.isEmpty {
            let escaped = ClaudeSessionLocator.escapedProjectDir(forCWD: cwd)
            if let hit = entries.first(where: { $0.projectDir == escaped }) {
                return hit
            }
            return nil
        }
        if let title = paneTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            let hits = entries.filter { entry in
                entry.projectDir == title || entry.projectDir.hasSuffix("-" + title)
            }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }
        }
        return entries.count == 1 ? entries[0] : nil
    }

    /// 对一个 ssh 目的地执行探针（真身 IO，runner 可注入供 Runner 直测）。
    /// 每次尝试 6s 预算；传输失败小退避重试一次——2026-09-14 真机实锤本机 TUN
    /// 代理（fake-IP 198.18.x）对 LAN ssh 有三种间歇病态：秒断 exit=255
    /// （Connection closed by 198.18.x）、静默挂死不退、握手后无输出——单发成功
    /// 率不稳，一次重试把偶发抖动从「永久降级裸回放」里捞回来（最坏 ~12.4s/目标，
    /// capture 探针按 4 并发分批，整体有界）。任何失败 → 空表（诚实降级）。
    /// target 形如 `user@host`；显式端口由调用方并入 target（host 形态目标不带端口）。
    static func probe(
        target: String,
        port: String?,
        runner: (String, [String], TimeInterval) -> YabaiClient.YabaiResult? = { exe, args, timeout in
            ShellRunner.run(executable: exe, arguments: args, timeout: timeout)
        }
    ) -> [RemoteSessionEntry] {
        var argv = ["ssh"]
        if let port, !port.isEmpty { argv += ["-p", port] }
        // BatchMode：绝不交互等密码；超时预算与 StrictHostKeyChecking=no 与用户既有 wrapper 一致
        argv += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=no",
            target,
            remoteCommand,
        ]
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            guard let result = runner("/usr/bin/ssh", argv, 6), result.exitCode == 0 else { continue }
            // exit 0 即采信（空表 = 远端确实无会话目录，不重试）
            return parseProbeOutput(result.stdout)
        }
        return []
    }
}
