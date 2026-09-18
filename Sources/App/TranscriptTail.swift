// TranscriptTail.swift
// VibeFocus — Claude Code / Codex transcript 尾部读取与解析（B197；B207 双格式）
//
// Stop hook payload 早已携带 transcript_path 却一直零消费（解码层注释「留作未来
// 扩展」）。接入后两件事成为可能：①LLM 总结拿到近期对话上下文（此前只看最后
// 一条消息，常断章取义）；②检测「最后一条是在向用户提问」——Claude 以提问结束
// 回合时 Stop 同样触发，把这种回合播报成「完成」是撒谎，它其实在等输入。
//
// B207：codex Stop hook 的 transcript_path 指向 rollout 文件（codex-cli 0.146.0
// 实证 ~/.codex/sessions/日期/rollout-<时间>-<uuid>.jsonl），行形状与 Claude 不同，
// 解析器双格式自适应（同一入口，调用方无需感知格式）：
//   Claude:  {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":...}]}}
//            content 也可能是纯字符串（防御性兼容）；usage 在 message.usage。
//   codex:   {"type":"response_item","payload":{"type":"message","role":"assistant",
//            "content":[{"type":"output_text","text":...}]}}
//            usage 行 = {"type":"event_msg","payload":{"type":"token_count",
//            "info":{"last_token_usage":{"input_tokens","cached_input_tokens",
//            "cache_write_input_tokens","output_tokens",...}}}}。
//   两者不认识的行（user 行/summary 行/session_meta/world_state/裸元数据行）一律跳过。

import Foundation

enum TranscriptTailReader {

    /// 读文件尾部字节数上限——transcript 可达数十 MB，全量读是主线程灾难；
    /// 64KB 足够覆盖最近若干轮对话，读入 <1ms 量级（调用点在 Stop 异步播报路径，
    /// 不阻塞 hook 响应；若日后看门狗报停顿再下放后台）。
    static let maxReadBytes = 65_536
    /// 最多回带的助手文本条数（太老的内容对总结无增量价值）。
    static let maxMessages = 6
    /// 单条文本截断——超长文本（整文件粘贴等）挤爆 LLM 输入也念不完。
    static let perMessageCap = 800

    /// 从内容字段提取文本块（防御性公共尾）：Claude content 可能是纯字符串；
    /// 两家的块状 content 按 blockType 过滤（Claude=text，codex=output_text），
    /// 空 text 块/nil 静默跳过。
    static func appendTextBlocks(_ content: Any?, blockType: String, into texts: inout [String]) {
        guard let content else { return }
        if let plain = content as? String {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { texts.append(trimmed) }
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks where block["type"] as? String == blockType {
                guard let text = block["text"] as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
            }
        }
    }

    /// 从 JSONL 行数组提取助手文本块（旧→新序；B207 起 Claude 与 codex rollout
    /// 双格式自适应）。防御性解析：坏行/非助手行/空 text 块静默跳过，绝不 throw。
    static func parseAssistantTexts(fromLines lines: [String]) -> [String] {
        var texts: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any] {
                appendTextBlocks(message["content"], blockType: "text", into: &texts)
            } else if obj["type"] as? String == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      payload["role"] as? String == "assistant" {
                appendTextBlocks(payload["content"], blockType: "output_text", into: &texts)
            }
        }
        return texts
    }

    /// 是否「在向用户提问」：最后一条文本以 ？/? 结尾（保守启发——只认问号，
    /// 不猜「请确认/请选择」句式，宁可漏报不可错报打断性提示）。
    static func isQuestionLike(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last == "？" || last == "?"
    }

    /// 读 transcript 尾部并提取助手文本（旧→新，最多 maxMessages 条，逐条截断）。
    /// 路径不存在/不可读/超界一律返回空数组（播报路径不因取证失败而失败）。
    static func readTail(
        path: String,
        maxBytes: Int = maxReadBytes,
        maxMessages: Int = maxMessages,
        perMessageCap: Int = perMessageCap
    ) -> [String] {
        let lines = readLines(path: path, maxBytes: maxBytes)
        let texts = parseAssistantTexts(fromLines: lines)
        // 首行落在读界上可能是半行 JSON——解析自然失败被跳过，无需特判。
        return texts.suffix(maxMessages).map { text in
            text.count > perMessageCap ? String(text.prefix(perMessageCap)) : text
        }
    }

    /// 读文件尾部为行数组（读界上的半行 JSON 由调用方解析时自然跳过）。
    static func readLines(path: String, maxBytes: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let readBytes = min(Int64(maxBytes), size)
        let offset = size - readBytes
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.read(upToCount: Int(readBytes))) ?? Data()
        guard !data.isEmpty else { return [] }
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }

    // MARK: - B200 token 用量提取

    /// 最后一轮回合的 token 用量（transcript assistant 行 message.usage 实测形状：
    /// input_tokens / cache_creation_input_tokens / cache_read_input_tokens /
    /// output_tokens；嵌套 server_tool_use 等未知字段防御性忽略）。
    struct TurnUsage: Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        /// 四项合计（cache 计入——中转计费口径看总量）。
        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        }
    }

    /// 从 JSONL 行提取最后一轮用量（行序遍历，后写覆盖前写=最后一轮胜出；B207 起
    /// Claude message.usage 与 codex token_count.info.last_token_usage 双格式）。
    static func parseLastUsage(fromLines lines: [String]) -> TurnUsage? {
        func int(_ u: [String: Any], _ key: String) -> Int { u[key] as? Int ?? 0 }
        var usage: TurnUsage?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any],
               let u = message["usage"] as? [String: Any] {
                usage = TurnUsage(
                    inputTokens: int(u, "input_tokens"),
                    outputTokens: int(u, "output_tokens"),
                    cacheReadTokens: int(u, "cache_read_input_tokens"),
                    cacheCreationTokens: int(u, "cache_creation_input_tokens")
                )
            } else if obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let u = info["last_token_usage"] as? [String: Any] {
                // codex 最后一轮：cached_input_tokens=读 cache，cache_write_input_tokens=写 cache
                usage = TurnUsage(
                    inputTokens: int(u, "input_tokens"),
                    outputTokens: int(u, "output_tokens"),
                    cacheReadTokens: int(u, "cached_input_tokens"),
                    cacheCreationTokens: int(u, "cache_write_input_tokens")
                )
            }
        }
        return usage
    }

    /// 读 transcript 尾部并提取最后一轮 token 用量；不可得返回 nil。
    static func readLastTurnUsage(path: String, maxBytes: Int = maxReadBytes) -> TurnUsage? {
        parseLastUsage(fromLines: readLines(path: path, maxBytes: maxBytes))
    }

    // MARK: - B207 CLI 显示名（播报诚实化）

    /// transcript 路径对应的 CLI 显示名。codex rollout 落盘约定（0.146.0 实证）：
    /// ~/.codex/sessions/日期/rollout-<时间>-<uuid>.jsonl——路径含 /.codex/sessions/
    /// 且文件名 rollout- 前缀判 codex；其余（含 nil）按 Claude。只用于播报措辞，
    /// 不参与任何行为分支。
    static func cliDisplayName(forTranscriptPath path: String?) -> String {
        guard let path,
              path.contains("/.codex/sessions/"),
              (path as NSString).lastPathComponent.hasPrefix("rollout-") else { return "Claude" }
        return "Codex"
    }

    /// 等待输入前缀（模板/音频/LLM fallback 三路共用同一措辞，听感一致）。
    /// CLI 名随 transcript 来源诚实切换——codex 会话的问句收尾不再念「Claude」。
    static func waitingPrefix(forTranscriptPath path: String?) -> String {
        cliDisplayName(forTranscriptPath: path) + " 在等你回复"
    }

    /// 等待输入前缀（Claude 缺省名；transcript 路径未知时的兜底措辞）。
    static let waitingPrefix = "Claude 在等你回复"
}
