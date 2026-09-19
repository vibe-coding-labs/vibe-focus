import AppKit
import Foundation
import Network
@testable import VibeFocusKit

// Tests/Runner/RunnerLLMRequestTests.swift — 覆盖率批次 7（B237）：
// VoiceAnnouncementManager.requestLLMSummary 网络编排全路径直测（本地 mock server）。
//
// 打法：apiBase 是注入参数——本地 NWListener 起 OpenAI 兼容 mock（真 URLSession
// 全链：请求构造/Bearer 头/JSON body → HTTP 响应 → choices 解析），四路径：
//   ①200+choices JSON → 返回 content（成功路径）；
//   ②500 → httpError(500)；
//   ③200+非 choices 结构 → parseError；
//   ④apiBase 含非法字符 → invalidAPIBase（URL 构造失败，零网络）。
// requestLLMSummary 是 @MainActor 方法——主线程同步测试里用 RunLoop 短片泵等
// async 完成（B154 家法；DispatchSemaphore.wait 会死锁 MainActor Task）。
// 诚实留白：summarizeAndSpeak/speakFallback（NSSpeechSynthesizer 真发音，会打断
// 用户）；voiceAnnounce 正文编排（音频通道）。

/// 极简 OpenAI 兼容 mock：收一次请求（分片循环收齐），按注入的 responder 回响应。
/// 请求内容不解析（URLSession 只需要合法响应格式）。
final class MockLLMServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "mock-llm")
    /// 请求 body 到达后调用，返回 (statusCode, responseBody)
    var responder: ((Data) -> (Int, Data))?
    private(set) var lastRequestBody: Data?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// 本地回环端口字符串（供 apiBase 拼接）
    var base: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { state in
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            // 头部结束 + body 按 Content-Length 收齐即响应（否则继续收）
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let bodyStart = headerEnd.upperBound
                let body = buffer[bodyStart...]
                let contentLength = header
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                if body.count >= contentLength {
                    self.lastRequestBody = Data(body.prefix(contentLength))
                    let (status, payload) = self.responder?(self.lastRequestBody ?? Data()) ?? (200, Data())
                    let response = Data("""
                    HTTP/1.1 \(status) Mock\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n
                    """.utf8) + payload
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if isComplete { connection.cancel(); return }
            self.receive(on: connection, accumulated: buffer)
        }
    }
}

extension RunnerHarness {
    func runLLMRequestTests() {
        guard let server = try? MockLLMServer() else {
            check("llmRequest: mock server 可创建", false)
            return
        }
        server.responder = { body in
            return (200, Data("""
            {"choices":[{"message":{"role":"assistant","content":"一句话总结文本"}}]}
            """.utf8))
        }
        server.start()
        // 端口就绪小等待（NWListener ready 异步）
        let readyDeadline = Date().addingTimeInterval(3)
        while (server.listener.state != .ready) && Date() < readyDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check("llmRequest: mock listener ready", server.listener.state == .ready)

        let manager = VoiceAnnouncementManager.shared

        func callLLM(apiBase: String) -> (success: Bool, content: String?, statusCode: Int?) {
            var outcome: (Bool, String?, Int?)?
            let start = Date()
            Task { @MainActor in
                do {
                    let content = try await manager.requestLLMSummary(
                        message: "原始长消息", apiBase: apiBase, apiKey: "test-key",
                        model: "test-model", maxChars: 50, context: ["上文一", "上文二"],
                        pendingQuestion: false)
                    outcome = (true, content, nil)
                } catch let err as VoiceAnnouncementError {
                    if case .httpError(let code) = err { outcome = (false, nil, code) }
                    else { outcome = (false, nil, nil) }
                } catch {
                    outcome = (false, nil, nil)
                }
            }
            while outcome == nil && Date().timeIntervalSince(start) < 10 {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            return outcome ?? (false, nil, nil)
        }

        // ① 成功路径：200+choices → content 原文返回；请求 body 含 system/user 两消息。
        let ok = callLLM(apiBase: server.base)
        check("llmRequest: 200+choices 成功返回 content",
              ok.success && ok.content == "一句话总结文本")
        if let bodyData = server.lastRequestBody,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]] {
            let roles = messages.compactMap { $0["role"] as? String }
            let hasBearerSemantic = (json["model"] as? String) == "test-model"
            check("llmRequest: 请求体 system+user 两消息且 model 透传",
                  roles == ["system", "user"] && hasBearerSemantic
                  && (json["max_tokens"] as? Int) == 100)
        } else {
            check("llmRequest: 请求体可解析", false)
        }

        // ② HTTP 错误路径：500 → httpError(500)。
        server.responder = { _ in (500, Data("{\"error\":\"boom\"}".utf8)) }
        let httpFail = callLLM(apiBase: server.base)
        check("llmRequest: 500 → httpError(500)", !httpFail.success && httpFail.statusCode == 500)

        // ③ 解析错误路径：200 但无 choices 结构 → parseError。
        server.responder = { _ in (200, Data("{\"unrelated\":true}".utf8)) }
        let parseFail = callLLM(apiBase: server.base)
        check("llmRequest: 200 无 choices → parseError", !parseFail.success && parseFail.statusCode == nil)

        // ④ 非法 apiBase → invalidAPIBase（URL 构造失败，零网络）。
        let badBase = callLLM(apiBase: "ht tp://invalid base with spaces")
        check("llmRequest: 非法 apiBase → invalidAPIBase", !badBase.success && badBase.statusCode == nil)

        server.stop()
    }
}
