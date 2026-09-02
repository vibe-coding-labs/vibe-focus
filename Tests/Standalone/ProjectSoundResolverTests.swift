// Tests/Standalone/ProjectSoundResolverTests.swift
// Verification: 项目音效规则解析（首匹配/回落/归一匹配/非法 rawValue 跳过）+ 项目名提取
// Mirrors: Sources/App/ProjectSoundResolver.swift, Sources/Window/WindowManager+Finding.swift (projectName(fromCwd:))
// Run: swift Tests/Standalone/ProjectSoundResolverTests.swift

import Foundation

// MARK: - Mirrored types

enum CompletionSoundType: String, CaseIterable {
    case none, systemDefault, builtinDing, builtinPing, builtinComplete, builtinAreYouOk, custom

    var rawValueLoweredMirror: String { rawValue }
}

// 镜像 WindowManager.projectName(fromCwd:)（末段路径 + 小写归一）
func mirrorProjectName(fromCwd cwd: String?) -> String? {
    guard let cwd else { return nil }
    let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let last = trimmed.components(separatedBy: "/").last, !last.isEmpty else { return nil }
    return last.lowercased()
}

struct ProjectSoundRule: Codable, Equatable {
    var projectName: String
    var soundRawValue: String

    var soundType: CompletionSoundType? { CompletionSoundType(rawValue: soundRawValue) }

    init(projectName: String, soundType: CompletionSoundType) {
        self.projectName = projectName
        self.soundRawValue = soundType.rawValue
    }
}

enum ProjectSoundResolver {
    static func projectName(claudeProjectDir: String?, cwd: String?) -> String? {
        mirrorProjectName(fromCwd: claudeProjectDir ?? cwd)
    }

    static func resolvedType(
        projectName: String?,
        rules: [ProjectSoundRule],
        globalType: CompletionSoundType
    ) -> CompletionSoundType {
        guard let projectName, !projectName.isEmpty else { return globalType }
        for rule in rules {
            guard let ruleSound = rule.soundType else { continue }
            if ruleMatches(ruleName: rule.projectName, liveProjectName: projectName) {
                return ruleSound
            }
        }
        return globalType
    }

    static func ruleMatches(ruleName: String, liveProjectName: String) -> Bool {
        guard let a = mirrorProjectName(fromCwd: ruleName),
              let b = mirrorProjectName(fromCwd: liveProjectName) else { return false }
        return a == b
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

print("1. projectName 提取（claudeProjectDir 优先，cwd 回落）")
do {
    check("claudeProjectDir 末段", ProjectSoundResolver.projectName(claudeProjectDir: "/Users/me/github/vibe-labs", cwd: "/other") == "vibe-labs")
    check("claudeProjectDir 缺失回落 cwd", ProjectSoundResolver.projectName(claudeProjectDir: nil, cwd: "/Users/me/work/app2/") == "app2")
    check("双缺失 → nil", ProjectSoundResolver.projectName(claudeProjectDir: nil, cwd: nil) == nil)
    check("全斜杠 → nil", ProjectSoundResolver.projectName(claudeProjectDir: "///", cwd: nil) == nil)
    check("小写归一", ProjectSoundResolver.projectName(claudeProjectDir: "/X/GitHub/Vibe-Focus", cwd: nil) == "vibe-focus")
}

print("2. resolvedType 解析矩阵")
do {
    let rules = [
        ProjectSoundRule(projectName: "vibe-focus", soundType: .builtinDing),
        ProjectSoundRule(projectName: "/Users/me/github/shaowei", soundType: .builtinAreYouOk),
    ]
    check("无规则 → 全局", ProjectSoundResolver.resolvedType(projectName: "anything", rules: [], globalType: .builtinPing) == .builtinPing)
    check("命中首条规则", ProjectSoundResolver.resolvedType(projectName: "vibe-focus", rules: rules, globalType: .builtinPing) == .builtinDing)
    check("未命中 → 回落全局", ProjectSoundResolver.resolvedType(projectName: "unknown-proj", rules: rules, globalType: .builtinPing) == .builtinPing)
    check("规则名是绝对路径也能命中（双侧归一）", ProjectSoundResolver.resolvedType(projectName: "shaowei", rules: rules, globalType: .builtinPing) == .builtinAreYouOk)
    check("大小写不敏感命中", ProjectSoundResolver.resolvedType(projectName: "Vibe-Focus", rules: rules, globalType: .builtinPing) == .builtinDing)
    check("live 项目名为 nil → 全局", ProjectSoundResolver.resolvedType(projectName: nil, rules: rules, globalType: .builtinComplete) == .builtinComplete)
    check("live 项目名为空 → 全局", ProjectSoundResolver.resolvedType(projectName: "", rules: rules, globalType: .builtinComplete) == .builtinComplete)
    check("全局 .none 但命中规则 → 规则音效（规则覆盖全局开关）",
          ProjectSoundResolver.resolvedType(projectName: "vibe-focus", rules: rules, globalType: .none) == .builtinDing)

    let brokenRules = [
        ProjectSoundRule(projectName: "bad", soundType: .builtinDing),
    ]
    var corrupt = brokenRules
    corrupt[0].soundRawValue = "nonexistent_type"
    check("非法 rawValue 规则跳过 → 回落全局",
          ProjectSoundResolver.resolvedType(projectName: "bad", rules: corrupt, globalType: .builtinPing) == .builtinPing)

    let ordered = [
        ProjectSoundRule(projectName: "app", soundType: .builtinDing),
        ProjectSoundRule(projectName: "app", soundType: .builtinComplete),
    ]
    check("重名规则首条生效", ProjectSoundResolver.resolvedType(projectName: "app", rules: ordered, globalType: .none) == .builtinDing)
}

print("3. 规则 Codable roundtrip")
do {
    let rules = [ProjectSoundRule(projectName: "vibe-focus", soundType: .custom)]
    let round = try JSONDecoder().decode([ProjectSoundRule].self, from: JSONEncoder().encode(rules))
    check("roundtrip 保持", round == rules)
    check("soundType 解码回 .custom", round.first?.soundType == .custom)
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
