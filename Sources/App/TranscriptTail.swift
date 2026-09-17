// TranscriptTail.swift
// VibeFocus — Claude Code transcript 尾部读取与解析（B197）
//
// Stop hook payload 早已携带 transcript_path 却一直零消费（解码层注释「留作未来
// 扩展」）。接入后两件事成为可能：①LLM 总结拿到近期对话上下文（此前只看最后
// 一条消息，常断章取义）；②检测「最后一条是在向用户提问」——Claude 以提问结束
// 回合时 Stop 同样触发，把这种回合播报成「完成」是撒谎，它其实在等输入。
//
// transcript JSONL 行形状（真机 0.0.60 实测）：
//   {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":...}]}}
//   content 也可能是纯字符串（防御性兼容）；user 行/summary 行/裸元数据行
//  （如 last-prompt）一律跳过。

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

    /// 从 JSONL 行数组提取助手文本块（旧→新序）。防御性解析：坏行/非助手行/
    /// 空 text 块静默跳过，绝不 throw。
    static func parseAssistantTexts(fromLines lines: [String]) -> [String] {
        var texts: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let content = message["content"]
            if let plain = content as? String {
                let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts.append(trimmed) }
            } else if let blocks = content as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "text" {
                    guard let text = block["text"] as? String else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { texts.append(trimmed) }
                }
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
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let readBytes = min(Int64(maxBytes), size)
        let offset = size - readBytes
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.read(upToCount: Int(readBytes))) ?? Data()
        guard !data.isEmpty else { return [] }
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        let texts = parseAssistantTexts(fromLines: lines)
        // 首行落在读界上可能是半行 JSON——解析自然失败被跳过，无需特判。
        return texts.suffix(maxMessages).map { text in
            text.count > perMessageCap ? String(text.prefix(perMessageCap)) : text
        }
    }

    /// 等待输入前缀（模板/音频/LLM fallback 三路共用同一措辞，听感一致）。
    static let waitingPrefix = "Claude 在等你回复"
}
