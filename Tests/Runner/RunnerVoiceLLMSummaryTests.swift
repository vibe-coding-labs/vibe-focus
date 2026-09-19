// Tests/Runner/RunnerVoiceLLMSummaryTests.swift — requestLLMSummary 本地 mock HTTP 回环直测（B243）。
// apiBase 参数注入 → NWListener 起本机最小 HTTP 应答器，锁定四分支：成功解析
// choices[0].message.content / HTTP 错误状态透传 / 200+非 JSON parseError /
// 非法 apiBase invalidAPIBase。真发声口（speak/speakFallback）维持留白归口
//（真发声会打断用户，B238 先例）；summarizeAndSpeak 的 Task 编排体随之留白。

import Foundation
import Network
@testable import VibeFocusKit

extension RunnerHarness {
    func runVoiceLLMSummaryTests() {
        // 最小 HTTP 应答器：收任意请求 → 回预置 status+body（一次一连接，串行应答）
        final class Responder: @unchecked Sendable {
            let listener: NWListener
            let status: String
            let body: String
            init(port: UInt16, status: String, body: String) throws {
                self.status = status
                self.body = body
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            }
            func start() {
                listener.newConnectionHandler = { [body, status] connection in
                    connection.start(queue: .global())
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                        let payload = body.data(using: .utf8) ?? Data()
                        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                }
                listener.start(queue: .global())
            }
        }

        func awaitAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> (value: T?, error: Error?) {
            let box = LLMResultBox<T>()
            let sem = DispatchSemaphore(value: 0)
            Task {
                do { box.value = try await work() } catch { box.error = error }
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) != .success {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return (box.value, box.error)
        }
        func errName(_ error: Error?) -> String {
            (error as? VoiceAnnouncementError).map(String.init(describing:)) ?? "none"
        }

        func makeServer(_ status: String, _ body: String) -> (Responder, UInt16)? {
            for _ in 0..<5 {
                let port = UInt16.random(in: 41000...49000)
                if let r = try? Responder(port: port, status: status, body: body) {
                    r.start()
                    return (r, port)
                }
            }
            return nil
        }

        // A. 成功：choices[0].message.content 解析
        if let (server, port) = makeServer("200 OK", #"{"choices":[{"message":{"content":"vf-一句话总结"}}]}"#) {
            defer { server.listener.cancel() }
            let (value, error) = awaitAsync { @Sendable in
                try await VoiceAnnouncementManager.shared.requestLLMSummary(
                    message: "最后一条消息", apiBase: "http://127.0.0.1:\(port)",
                    apiKey: "vf-key", model: "vf-model", maxChars: 30,
                    context: ["旧上下文"], pendingQuestion: false)
            }
            check("voiceLLM: 成功解析 content", error == nil && value == "vf-一句话总结")
        }

        // B. HTTP 错误状态透传（httpError(500)）
        if let (server, port) = makeServer("500 Internal Server Error", #"{"error":"boom"}"#) {
            defer { server.listener.cancel() }
            let (value, error) = awaitAsync { @Sendable in
                try await VoiceAnnouncementManager.shared.requestLLMSummary(
                    message: "m", apiBase: "http://127.0.0.1:\(port)",
                    apiKey: "k", model: "m", maxChars: 30)
            }
            check("voiceLLM: 非 2xx → httpError(500) 且无值", value == nil && errName(error) == "httpError(500)")
        }

        // C. 200 + 非 JSON → parseError
        if let (server, port) = makeServer("200 OK", "not-json-at-all") {
            defer { server.listener.cancel() }
            let (value, error) = awaitAsync { @Sendable in
                try await VoiceAnnouncementManager.shared.requestLLMSummary(
                    message: "m", apiBase: "http://127.0.0.1:\(port)",
                    apiKey: "k", model: "m", maxChars: 30)
            }
            check("voiceLLM: 200 非 JSON → parseError", value == nil && errName(error).contains("parseError"))
        }

        // D. 非法 apiBase → URL 构造失败 invalidAPIBase（零网络）
        let (value, error) = awaitAsync { @Sendable in
            try await VoiceAnnouncementManager.shared.requestLLMSummary(
                message: "m", apiBase: "ht tp://bad base",
                apiKey: "k", model: "m", maxChars: 30)
        }
        check("voiceLLM: 非法 apiBase → invalidAPIBase（零网络）",
              value == nil && errName(error) == "invalidAPIBase")

        // E. prompt 构造纯函数（待问前缀与字数上限进 system prompt）
        let sysQ = VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: true, maxChars: 42)
        let sysNoQ = VoiceAnnouncementManager.llmSystemPrompt(pendingQuestion: false, maxChars: 30)
        check("voiceLLM: system prompt 待问加前缀、字数上限进模板",
              sysQ.contains("42") && sysQ.contains("需要你的输入")
              && sysNoQ.contains("30") && !sysNoQ.contains("需要你的输入"))
        let user = VoiceAnnouncementManager.llmUserContent(message: "压轴", context: ["旧1", "旧2"])
        check("voiceLLM: user 内容上下文在前消息压轴",
              user.hasPrefix("旧1\n---\n旧2\n---\n压轴"))
    }
}


// B243：异步桥接结果盒（Box 不能嵌套在泛型函数内，提文件作用域）
final class LLMResultBox<T>: @unchecked Sendable { var value: T?; var error: Error? }
