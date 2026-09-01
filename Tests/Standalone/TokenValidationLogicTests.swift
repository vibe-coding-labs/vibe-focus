// Tests/Standalone/TokenValidationLogicTests.swift
// Verification: hook 请求 token 取值与判定纯函数
// Mirrors: Sources/Hook/ClaudeHookServer.swift (resolveProvidedToken / isTokenValid)
// Run: swift Tests/Standalone/TokenValidationLogicTests.swift
//
// 背景（playbook 2.16a 第十六刀影子接线）：两函数标注 "extracted for testability"
// 却生产零调用——真实验证逻辑内联在 handleRequest 里，两份语义漂移风险（第一刀
// decideWindowMove 同款反模式）。本刀生产接线纯函数，本测试锁定契约：
// query 优先于 header、header 值去首尾空白、双缺失返回空串（非 nil）、
// 未配置 token 跳过验证（nil/空串等价）、其余严格相等判定。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors ClaudeHookServer.resolveProvidedToken / isTokenValid / resolveHeaderValue 的 header 取值语义
enum MirrorTokenValidation {

    /// Mirrors resolveHeaderValue（大小写不敏感 header 查找 + 字符串字典兜底）
    static func headerValue(_ headers: [String: String], forKey key: String) -> String? {
        if let exact = headers[key] { return exact }
        return headers.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    /// Mirrors resolveProvidedToken：query 优先，回退去空白后的 header；双缺失 → ""（非 nil）
    static func resolveProvidedToken(query: [String: String], headers: [String: String]) -> String {
        let queryToken = query["token"]
        let headerToken = headerValue(headers, forKey: "X-VibeFocus-Token")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return queryToken ?? headerToken
    }

    /// Mirrors isTokenValid：未配置（nil/空串）→ 跳过验证；其余严格相等
    static func isTokenValid(expectedToken: String?, providedToken: String?) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty else {
            return true
        }
        return providedToken == expectedToken
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. resolveProvidedToken — 取值优先级

print("1. resolveProvidedToken 取值")

check("query token 优先于 header token",
      MirrorTokenValidation.resolveProvidedToken(
        query: ["token": "query-token"],
        headers: ["X-VibeFocus-Token": "header-token"]) == "query-token")

check("无 query 时回退 header token",
      MirrorTokenValidation.resolveProvidedToken(
        query: [:],
        headers: ["X-VibeFocus-Token": "header-token"]) == "header-token")

check("header 值去首尾空白（含换行的粘贴 token 也能匹配）",
      MirrorTokenValidation.resolveProvidedToken(
        query: [:],
        headers: ["X-VibeFocus-Token": "  abc123 \n"]) == "abc123")

check("query 与 header 双缺失 → 空串（非 nil，日志 tokenPrefix 安全）",
      MirrorTokenValidation.resolveProvidedToken(query: [:], headers: [:]) == "")

check("header 大小写不敏感查找",
      MirrorTokenValidation.resolveProvidedToken(
        query: [:],
        headers: ["x-vibefocus-token": "lowercase-header"]) == "lowercase-header")

// MARK: 2. isTokenValid — 判定契约

print("\n2. isTokenValid 判定")

check("未配置 token（nil）→ 跳过验证，任意 provided 均通过",
      MirrorTokenValidation.isTokenValid(expectedToken: nil, providedToken: "anything"))
check("配置为空串 → 与 nil 等价，跳过验证",
      MirrorTokenValidation.isTokenValid(expectedToken: "", providedToken: "anything"))
check("provided == expected → 通过",
      MirrorTokenValidation.isTokenValid(expectedToken: "secret", providedToken: "secret"))
check("provided != expected → 401 拒绝",
      !MirrorTokenValidation.isTokenValid(expectedToken: "secret", providedToken: "wrong"))
check("provided 为空串且 expected 非空 → 拒绝（未带 token 不放行）",
      !MirrorTokenValidation.isTokenValid(expectedToken: "secret", providedToken: ""))

// MARK: 3. 端到端组合 — 与生产 handleRequest 接线路径同构

print("\n3. 接线路径组合")

func handleRequest(query: [String: String], headers: [String: String], configuredToken: String?) -> Int {
    let providedToken = MirrorTokenValidation.resolveProvidedToken(query: query, headers: headers)
    if !MirrorTokenValidation.isTokenValid(expectedToken: configuredToken, providedToken: providedToken) {
        return 401
    }
    return 200
}

check("配置 token + query 带 token → 200",
      handleRequest(query: ["token": "secret"], headers: [:], configuredToken: "secret") == 200)
check("配置 token + 仅 header 带 token → 200",
      handleRequest(query: [:], headers: ["X-VibeFocus-Token": "secret"], configuredToken: "secret") == 200)
check("配置 token + 双双缺失 → 401",
      handleRequest(query: [:], headers: [:], configuredToken: "secret") == 401)
check("未配置 token + 无任何 provided → 200（本机无鉴权场景）",
      handleRequest(query: [:], headers: [:], configuredToken: nil) == 200)
check("配置空串 token（历史 configureToken 空串路径）+ 无 provided → 200",
      handleRequest(query: [:], headers: [:], configuredToken: "") == 200)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
