import AppKit
import SwiftUI
import Foundation


// Hook 测试事件发送（2026-09-07 B35 从 SettingsView+Helpers 拆分：测试按钮编排 + HTTP 请求构造/发收）
extension SettingsView {

    // MARK: - Claude Hook Test Helpers

    func sendTestHookEvent() {
        // P-INST-251: 测试 hook 事件发送编排耗时（ensureTokenGenerated UserDefaults 写 + sendHookRequest URLSession 发起 SessionStart；设置 UI 测试按钮触发，HTTP 请求异步回调不计入 defer；slow-op ≥50ms warn）。
        #if PERF_INSTRUMENT
        let sthStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sthStart)
            if durMs >= 50 { log("[Settings] sendTestHookEvent slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        #endif
        let port = hookPort
        let testSessionID = "test-\(UUID().uuidString.prefix(8))"
        if hookToken.isEmpty {
            ClaudeHookPreferences.ensureTokenGenerated()
            hookToken = ClaudeHookPreferences.authToken ?? ""
        }
        let token = hookToken.isEmpty ? nil : hookToken

        log(
            "[Settings] sending test SessionStart event",
            fields: [
                "sessionID": testSessionID,
                "port": String(port),
                "hasToken": String(token != nil)
            ]
        )

        let startPayload = Self.makeTestHookPayload(event: "SessionStart", sessionID: testSessionID)
        Self.sendHookRequest(
            port: port,
            endpoint: ClaudeHookPreferences.endpointPath,
            payload: startPayload,
            token: token
        ) { result in
            switch result {
            case .success:
                let endPort = port
                let endToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    log(
                        "[Settings] sending test SessionEnd event",
                        fields: [
                            "sessionID": testSessionID,
                            "port": String(endPort)
                        ]
                    )
                    let endPayload = Self.makeTestHookPayload(event: "SessionEnd", sessionID: testSessionID)
                    Self.sendHookRequest(
                        port: endPort,
                        endpoint: ClaudeHookPreferences.endpointPath,
                        payload: endPayload,
                        token: endToken
                    ) { endResult in
                        if case .failure(let endError) = endResult {
                            log(
                                "[Settings] test SessionEnd failed",
                                level: .error,
                                fields: [
                                    "sessionID": testSessionID,
                                    "error": endError.localizedDescription
                                ]
                            )
                        }
                    }
                }
            case .failure(let error):
                log(
                    "[Settings] test SessionStart failed",
                    level: .error,
                    fields: [
                        "sessionID": testSessionID,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    static func sendHookRequest(
        port: Int,
        endpoint: String,
        payload: [String: String],
        token: String?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // P-INST-92: hook 测试请求网络往返耗时（URL 构造 + JSONSerialization 序列化 + URLSession POST + 等待响应；shrStart 在 completion 闭包入口记 round-trip durationMs；设置面板 sendTestHookEvent 调用，timeout 5s；本地 127.0.0.1 但可阻塞 UI 线程的 async wait）。
        let shrStart = Date()
        let request: URLRequest
        do {
            request = try buildHookRequest(port: port, endpoint: endpoint, payload: payload, token: token)
        } catch {
            completion(.failure(error))
            return
        }

        // completion 原语义即在 URLSession 回调线程执行（非主线程），此处仅为跨 @Sendable
        // 闭包传递；nonisolated(unsafe) 消除捕获警告，不改变调用线程与行为。
        nonisolated(unsafe) let completion = completion
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            log("[SettingsView] sendHookRequest round-trip", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: shrStart))
            ])
            if let error {
                completion(.failure(error))
                return
            }
            completion(hookResponseVerdict(response: response, data: data).map { data ?? Data() })
        }
        task.resume()
    }

    /// 请求构造唯一事实源（纯函数，B35 提纯）：URL 拼接/方法/头/JSON 体。
    /// 发收与线程模型留在 sendHookRequest；测试无需网络即可锁定请求契约。
    /// 测试事件 payload 构建（B241 提纯：原内联在 sendTestHookEvent 的两处字典字面量；
    /// source 恒 test-ui 供服务端辨认 UI 测试流量）。
    nonisolated static func makeTestHookPayload(event: String, sessionID: String) -> [String: String] {
        [
            "event": event,
            "session_id": sessionID,
            "source": "test-ui"
        ]
    }

    nonisolated static func buildHookRequest(
        port: Int,
        endpoint: String,
        payload: [String: String],
        token: String?
    ) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else {
            throw NSError(domain: "VibeFocus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-VibeFocus-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// 响应裁决（纯函数，B35 提纯）：非 HTTP → 失败；>=400 → 失败携带状态码与响应体；其余成功。
    nonisolated static func hookResponseVerdict(response: URLResponse?, data: Data?) -> Result<Void, Error> {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(NSError(domain: "VibeFocus", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not HTTP response"]))
        }
        if httpResponse.statusCode >= 400 {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
            return .failure(NSError(
                domain: "VibeFocus",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]
            ))
        }
        return .success(())
    }
}
