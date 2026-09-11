import Foundation

// Sources/Hook/ClaudeHookServer+Pure.swift — B156 自 ClaudeHookServer.swift 按域拆出
// （逐字搬移零行为变更）：请求壳纯判定族（重启判定/header 查找/来源分类/token 门/payload 解码）。
// 真身直测：RunnerHookWalkTests tokenGate/decodePayload 块、RunnerRegistryStoreTests B89 来源分类块。

extension ClaudeHookServer {

    // MARK: - Response Helpers

    /// 服务器是否需要（重）启动的纯判定：未运行，或端口/token/绑定模式任一配置变化。
    /// 绑定模式曾是判定盲区——服务运行中翻转「局域网模式」触发 applyPreferences 却
    /// 早退返回，开 LAN 不重绑定（远程机连不上）、关 LAN 不收回 0.0.0.0（继续暴露
    /// 局域网直到重启 app）。Runner 真身直测锁定。
    static func serverNeedsRestart(
        isRunning: Bool,
        activePort: Int?,
        configuredToken: String?,
        configuredBindToLocalhost: Bool?,
        port: Int,
        token: String?,
        bindToLocalhost: Bool
    ) -> Bool {
        guard isRunning else { return true }
        return activePort != port
            || configuredToken != token
            || configuredBindToLocalhost != bindToLocalhost
    }

    /// Case-insensitive header lookup — GCDWebServer preserves original HTTP header casing
    static func resolveHeaderValue(from headers: [String: String], forKey key: String) -> String? {
        if let value = headers[key] { return value }
        let lowerKey = key.lowercased()
        for (k, v) in headers where k.lowercased() == lowerKey {
            return v
        }
        return nil
    }

    /// loopback 判定（纯函数）：IPv4 127/8 前缀、IPv6 ::1、IPv4-mapped ::ffff:127.*。
    static func isLoopbackAddress(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasPrefix("127.") || lower == "::1" || lower.hasPrefix("::ffff:127.") || lower == "::"
    }

    /// hook 请求来源分类（纯函数，B89）：代理头优先（反代部署取真实客户端）→
    /// TCP 对端地址（loopback=本机调用；其它=局域网/远程直连）→ 未知回退 local。
    /// 旧行为只认 X-Forwarded-For/X-Real-IP 代理头——直连 LAN 请求（本应用的主要
    /// 远程场景）不带这些头，日志里真实远程来源全被误记为 local。
    static func classifyRequestSource(peerAddress: String?, proxyIP: String?) -> (source: String, isRemote: Bool) {
        if let proxy = proxyIP, !proxy.isEmpty {
            return (proxy, !isLoopbackAddress(proxy))
        }
        guard let peer = peerAddress, !peer.isEmpty else {
            return ("local", false)
        }
        if isLoopbackAddress(peer) {
            return ("local", false)
        }
        return (peer, true)
    }

    /// Pure token validation — extracted for testability.
    /// Returns the effective token from query params or headers (empty string when absent — never nil).
    static func resolveProvidedToken(query: [String: String], headers: [String: String]) -> String {
        let queryToken = query["token"]
        let headerToken = resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return queryToken ?? headerToken
    }

    /// Pure token validation decision — extracted for testability.
    static func isTokenValid(expectedToken: String?, providedToken: String?) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty else {
            return true // No token configured → skip validation
        }
        return providedToken == expectedToken
    }

    /// token 门判定（B141 提纯）：true = 拒绝（401）。
    /// 语义 = !(resolveProvidedToken → isTokenValid)，拒绝时未计数（totalRequestCount
    /// 只统计通过 token 门的请求——401 不计入总量，与历史口径一致）。
    static func tokenGateRejected(query: [String: String], headers: [String: String], expectedToken: String?) -> Bool {
        let provided = resolveProvidedToken(query: query, headers: headers)
        return !isTokenValid(expectedToken: expectedToken, providedToken: provided)
    }

    /// payload 解码门（B141 提纯）：非法/缺失 event+session_id → nil（调用方回 400）。
    static func decodePayload(from body: Data) -> ClaudeHookPayload? {
        try? JSONDecoder().decode(ClaudeHookPayload.self, from: body)
    }
}
