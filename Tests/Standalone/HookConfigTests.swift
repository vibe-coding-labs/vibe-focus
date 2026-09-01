// Tests/Standalone/HookConfigTests.swift
// Verification: Hook configuration generation and cleanup logic
// Mirrors: Sources/Hook/ClaudeHookPreferences.swift
// Run: swift Tests/Standalone/HookConfigTests.swift

import Foundation

// MARK: - Mirrored functions

func normalizePort(_ value: Int) -> Int {
    min(max(value, 1024), 65535)
}

let endpointPath = "/claude/hook"

func endpointURLString(port: Int, token: String?) -> String {
    let effectivePort = normalizePort(port)
    if let token, !token.isEmpty {
        return "http://127.0.0.1:\(effectivePort)\(endpointPath)?token=\(token)"
    }
    return "http://127.0.0.1:\(effectivePort)\(endpointPath)"
}

func makeHookEntry(helperScriptPath: String) -> [String: Any] {
    [
        "matcher": "",
        "hooks": [
            ["type": "command", "command": "bash \"\(helperScriptPath)\"", "timeout": 10]
        ]
    ]
}

func generateHooksDict(triggerOnStop: Bool, triggerOnSessionEnd: Bool, autoRestoreOnPromptSubmit: Bool, helperScriptPath: String) -> [String: Any] {
    var hooks: [String: Any] = [:]
    hooks["SessionStart"] = [makeHookEntry(helperScriptPath: helperScriptPath)]
    if triggerOnStop {
        hooks["Stop"] = [makeHookEntry(helperScriptPath: helperScriptPath)]
    }
    if triggerOnSessionEnd {
        hooks["SessionEnd"] = [makeHookEntry(helperScriptPath: helperScriptPath)]
    }
    if autoRestoreOnPromptSubmit {
        hooks["UserPromptSubmit"] = [makeHookEntry(helperScriptPath: helperScriptPath)]
    }
    return hooks
}

func cleanVibeFocusHooks(from hooks: inout [String: Any], targetURL: String, scriptPath: String) {
    for key in ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"] {
        guard var entries = hooks[key] as? [[String: Any]] else { continue }
        entries.removeAll { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
            return hookList.contains { hook in
                if let url = hook["url"] as? String, url == targetURL { return true }
                if let command = hook["command"] as? String, command.contains(scriptPath) { return true }
                return false
            }
        }
        if entries.isEmpty { hooks.removeValue(forKey: key) }
        else { hooks[key] = entries }
    }
}

func generateGeneratedToken() -> String {
    UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .prefix(32)
        .lowercased()
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func checkEqual<T: Equatable>(_ name: String, _ a: T, _ b: T) {
    if a == b { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name) — expected \(b), got \(a)") }
}

// MARK: - endpointURLString

print("1. endpointURLString — with token")
do {
    checkEqual("with token",
        endpointURLString(port: 39277, token: "abc123"),
        "http://127.0.0.1:39277/claude/hook?token=abc123")
    checkEqual("with UUID token",
        endpointURLString(port: 8080, token: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"),
        "http://127.0.0.1:8080/claude/hook?token=a1b2c3d4-e5f6-7890-abcd-ef1234567890")
}

print("\n2. endpointURLString — without token")
do {
    checkEqual("nil token",
        endpointURLString(port: 39277, token: nil),
        "http://127.0.0.1:39277/claude/hook")
    checkEqual("empty token",
        endpointURLString(port: 39277, token: ""),
        "http://127.0.0.1:39277/claude/hook")
}

print("\n3. endpointURLString — port normalization")
do {
    checkEqual("port 0 → 1024",
        endpointURLString(port: 0, token: nil),
        "http://127.0.0.1:1024/claude/hook")
    checkEqual("port 80 → 1024",
        endpointURLString(port: 80, token: "t"),
        "http://127.0.0.1:1024/claude/hook?token=t")
    checkEqual("port 99999 → 65535",
        endpointURLString(port: 99999, token: nil),
        "http://127.0.0.1:65535/claude/hook")
}

// MARK: - makeHookEntry

print("\n7. makeHookEntry — structure")
do {
    let entry = makeHookEntry(helperScriptPath: "/usr/local/bin/vf-helper.sh")
    checkEqual("matcher is empty", entry["matcher"] as? String, "")
    let hooks = entry["hooks"] as? [[String: Any]]
    check("hooks array has 1 entry", hooks?.count == 1)
    let hook = hooks?.first
    checkEqual("type is command", hook?["type"] as? String, "command")
    check("command contains script path", (hook?["command"] as? String)?.contains("/usr/local/bin/vf-helper.sh") == true)
    checkEqual("timeout is 10", hook?["timeout"] as? Int, 10)
}

// MARK: - generateHooksDict

print("\n8. generateHooksDict — all enabled")
do {
    let hooks = generateHooksDict(triggerOnStop: true, triggerOnSessionEnd: true, autoRestoreOnPromptSubmit: true, helperScriptPath: "/tmp/helper.sh")
    check("has SessionStart", hooks["SessionStart"] != nil)
    check("has Stop", hooks["Stop"] != nil)
    check("has SessionEnd", hooks["SessionEnd"] != nil)
    check("has UserPromptSubmit", hooks["UserPromptSubmit"] != nil)
    check("has exactly 4 keys", hooks.count == 4)
}

print("\n9. generateHooksDict — only SessionStart (all disabled)")
do {
    let hooks = generateHooksDict(triggerOnStop: false, triggerOnSessionEnd: false, autoRestoreOnPromptSubmit: false, helperScriptPath: "/tmp/helper.sh")
    check("has SessionStart", hooks["SessionStart"] != nil)
    check("NO Stop", hooks["Stop"] == nil)
    check("NO SessionEnd", hooks["SessionEnd"] == nil)
    check("NO UserPromptSubmit", hooks["UserPromptSubmit"] == nil)
    check("has exactly 1 key", hooks.count == 1)
}

print("\n10. generateHooksDict — mixed flags")
do {
    let hooks = generateHooksDict(triggerOnStop: true, triggerOnSessionEnd: false, autoRestoreOnPromptSubmit: true, helperScriptPath: "/tmp/helper.sh")
    check("has SessionStart", hooks["SessionStart"] != nil)
    check("has Stop", hooks["Stop"] != nil)
    check("NO SessionEnd", hooks["SessionEnd"] == nil)
    check("has UserPromptSubmit", hooks["UserPromptSubmit"] != nil)
    check("has exactly 3 keys", hooks.count == 3)
}

// MARK: - cleanVibeFocusHooks

print("\n11. cleanVibeFocusHooks — removes command hooks matching script path")
do {
    var hooks: [String: Any] = [
        "SessionStart": [
            ["matcher": "", "hooks": [["type": "command", "command": "bash \"/path/to/helper.sh\"", "timeout": 10]]]
        ],
        "UserPromptSubmit": [
            ["matcher": "", "hooks": [["type": "command", "command": "bash \"/path/to/helper.sh\"", "timeout": 10]]]
        ]
    ]
    cleanVibeFocusHooks(from: &hooks, targetURL: "http://127.0.0.1:39277/claude/hook", scriptPath: "/path/to/helper.sh")
    check("SessionStart removed (was only VF)", hooks["SessionStart"] == nil)
    check("UserPromptSubmit removed (was only VF)", hooks["UserPromptSubmit"] == nil)
}

print("\n12. cleanVibeFocusHooks — removes HTTP hooks matching target URL")
do {
    var hooks: [String: Any] = [
        "Stop": [
            ["matcher": "", "hooks": [["type": "http", "url": "http://127.0.0.1:39277/claude/hook?token=abc"]]]
        ]
    ]
    cleanVibeFocusHooks(from: &hooks, targetURL: "http://127.0.0.1:39277/claude/hook?token=abc", scriptPath: "/other/path.sh")
    check("Stop removed (matched URL)", hooks["Stop"] == nil)
}

print("\n13. cleanVibeFocusHooks — preserves non-VF hooks")
do {
    let otherHook: [[String: Any]] = [
        ["matcher": "", "hooks": [["type": "command", "command": "bash /usr/bin/other-hook.sh", "timeout": 5]]]
    ]
    let vfHook: [[String: Any]] = [
        ["matcher": "", "hooks": [["type": "command", "command": "bash \"/path/to/helper.sh\"", "timeout": 10]]]
    ]
    var hooks: [String: Any] = [
        "SessionStart": vfHook,
        "CustomEvent": otherHook
    ]
    cleanVibeFocusHooks(from: &hooks, targetURL: "http://127.0.0.1:39277/claude/hook", scriptPath: "/path/to/helper.sh")
    check("SessionStart removed (VF hook)", hooks["SessionStart"] == nil)
    check("CustomEvent preserved (non-VF)", hooks["CustomEvent"] != nil)
}

print("\n14. cleanVibeFocusHooks — mixed VF and non-VF in same event")
do {
    let vfHook: [String: Any] = [
        "matcher": "", "hooks": [["type": "command", "command": "bash \"/path/to/helper.sh\"", "timeout": 10]]
    ]
    let otherHook: [String: Any] = [
        "matcher": "", "hooks": [["type": "command", "command": "other-script", "timeout": 5]]
    ]
    var hooks: [String: Any] = [
        "SessionStart": [vfHook, otherHook]
    ]
    cleanVibeFocusHooks(from: &hooks, targetURL: "http://127.0.0.1:39277/claude/hook", scriptPath: "/path/to/helper.sh")
    let remaining = hooks["SessionStart"] as? [[String: Any]]
    check("SessionStart preserved with non-VF entry", remaining != nil)
    check("only 1 entry remains", remaining?.count == 1)
}

print("\n15. cleanVibeFocusHooks — empty hooks dict")
do {
    var hooks: [String: Any] = [:]
    cleanVibeFocusHooks(from: &hooks, targetURL: "http://127.0.0.1:39277/claude/hook", scriptPath: "/path/to/helper.sh")
    check("empty dict unchanged", hooks.isEmpty)
}

// MARK: - ensureTokenGenerated (token generation logic)

print("\n16. Token generation — format")
do {
    for _ in 0..<5 {
        let token = generateGeneratedToken()
        check("token is 32 chars: '\(token)'", token.count == 32)
        check("token is lowercase: '\(token)'", token == token.lowercased())
        check("token has no dashes: '\(token)'", !token.contains("-"))
    }
}

print("\n17. Token generation — uniqueness")
do {
    let tokens = Set((0..<20).map { _ in generateGeneratedToken() })
    check("20 tokens are all unique", tokens.count == 20)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
