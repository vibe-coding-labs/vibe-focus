// Tests/Standalone/VoiceAnnouncementTemplateTests.swift
// Verification: VoiceAnnouncementTemplate.interpolate — 模板变量插值（{project_name}/{model}/{cwd}/{session_id}）
// Mirrors: Sources/App/VoiceAnnouncementPreferences.swift（VoiceAnnouncementTemplate.interpolate）
// Fixtures: 无外部文件（内联最小 payload 镜像）
// Run: swift Tests/Standalone/VoiceAnnouncementTemplateTests.swift

import Foundation

// MARK: - Mirrored types（与 Sources/Hook/ClaudeHookModels.swift 保持字段一致，仅取插值所需字段）

struct MirroredTerminalContext {
    let claudeProjectDir: String?
}

struct MirroredPayload {
    let sessionID: String
    let cwd: String?
    let model: String?
    let terminalCtx: MirroredTerminalContext?
}

// MARK: - Mirrored logic（与 VoiceAnnouncementTemplate.interpolate 逐行一致）

func interpolate(_ template: String, payload: MirroredPayload) -> String {
    let projectName = payload.terminalCtx?.claudeProjectDir?
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .components(separatedBy: "/").last
        ?? "未知项目"
    let model = payload.model ?? "未知模型"
    let cwd = payload.cwd ?? ""
    let sessionID = payload.sessionID

    return template
        .replacingOccurrences(of: "{project_name}", with: projectName)
        .replacingOccurrences(of: "{model}", with: model)
        .replacingOccurrences(of: "{cwd}", with: cwd)
        .replacingOccurrences(of: "{session_id}", with: sessionID)
}

// MARK: - Harness

var failures = 0
var checks = 0

func checkEqual(_ label: String, _ actual: String, _ expected: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    } else {
        print("ok: \(label)")
    }
}

func makePayload(cwd: String?, model: String?, projectDir: String?, sessionID: String = "sess-42") -> MirroredPayload {
    MirroredPayload(
        sessionID: sessionID,
        cwd: cwd,
        model: model,
        terminalCtx: MirroredTerminalContext(claudeProjectDir: projectDir)
    )
}

// MARK: - 正常插值

checkEqual(
    "project_name 取路径最后一段",
    interpolate("{project_name} 完成", payload: makePayload(cwd: "/tmp", model: nil, projectDir: "/Users/me/github/vibe-labs")),
    "vibe-labs 完成"
)
checkEqual(
    "model 插值",
    interpolate("由 {model} 完成", payload: makePayload(cwd: nil, model: "glm-4.7", projectDir: "/repo")),
    "由 glm-4.7 完成"
)
checkEqual(
    "cwd 与 session_id 插值",
    interpolate("{cwd} #{session_id}", payload: makePayload(cwd: "/home/work", model: nil, projectDir: nil)),
    "/home/work #sess-42"
)
checkEqual(
    "多变量混合",
    interpolate("{project_name}/{model}/{session_id}", payload: makePayload(cwd: nil, model: "m1", projectDir: "a/b/c")),
    "c/m1/sess-42"
)

// MARK: - 缺失字段兜底

checkEqual(
    "projectDir 缺失 → 未知项目",
    interpolate("{project_name} 完成", payload: makePayload(cwd: nil, model: nil, projectDir: nil)),
    "未知项目 完成"
)
checkEqual(
    "model 缺失 → 未知模型",
    interpolate("{model}", payload: makePayload(cwd: nil, model: nil, projectDir: "/x")),
    "未知模型"
)
checkEqual(
    "cwd 缺失 → 空串",
    interpolate("[{cwd}]", payload: makePayload(cwd: nil, model: nil, projectDir: "/x")),
    "[]"
)
checkEqual(
    "terminalCtx 整体缺失 → 未知项目",
    interpolate("{project_name}", payload: MirroredPayload(sessionID: "s", cwd: "/c", model: "m", terminalCtx: nil)),
    "未知项目"
)

// MARK: - 路径形态变体

checkEqual(
    "根路径去斜杠后取最后一段",
    interpolate("{project_name}", payload: makePayload(cwd: nil, model: nil, projectDir: "repo")),
    "repo"
)
checkEqual(
    "无占位符模板原样返回",
    interpolate("对话完成", payload: makePayload(cwd: nil, model: nil, projectDir: nil)),
    "对话完成"
)

// MARK: - Summary

print("")
print("checks=\(checks) failures=\(failures)")
if failures > 0 {
    exit(1)
}
print("ALL PASS")
