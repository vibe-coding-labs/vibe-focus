import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookPayloadBuilderTests.swift — B241：设置页测试按钮的
// payload 构建器提纯直测（action 闭包内联字典 → 静态纯函数，行为不变）。
// 锁死「设置页测试流量 ↔ hook 服务端」的线上字段契约。

extension RunnerHarness {
    func runHookPayloadBuilderTests() {
        print("\n=== HookPayloadBuilder (B241) ===")

        // --- Claude 测试按钮：SessionStart / SessionEnd 成对 ---
        let start = SettingsView.makeTestHookPayload(event: "SessionStart", sessionID: "test-abc123")
        check("payload: Claude SessionStart 三字段",
              start == ["event": "SessionStart", "session_id": "test-abc123", "source": "test-ui"])
        let end = SettingsView.makeTestHookPayload(event: "SessionEnd", sessionID: "test-abc123")
        check("payload: Claude SessionEnd 同 session 成对回显",
              end == ["event": "SessionEnd", "session_id": "test-abc123", "source": "test-ui"])

        // --- Codex 测试按钮：基础三字段 + extraFields 合并（新增键并入、同键基础胜） ---
        let base = SettingsView.makeCodexTestPayload(event: "PermissionRequest", sessionID: "codex-test-x1")
        check("payload: codex 基础三字段",
              base == ["event": "PermissionRequest", "session_id": "codex-test-x1", "source": "test-ui"])
        let merged = SettingsView.makeCodexTestPayload(
            event: "UserPromptSubmit", sessionID: "codex-test-x2",
            extraFields: ["prompt": "hi", "source": "extra-source"])
        check("payload: codex extraFields 新增键并入、同键冲突基础胜",
              merged == ["event": "UserPromptSubmit", "session_id": "codex-test-x2",
                         "source": "test-ui", "prompt": "hi"])

        // --- 线上序列化契约：payload 经 JSONSerialization 后仍是字符串字典（服务端解码前提） ---
        let data = try? JSONSerialization.data(withJSONObject: merged)
        let roundTrip = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: String]
        check("payload: JSON 往返保真（全字符串值）", roundTrip == merged)
    }
}

extension RunnerHarness {
    /// B242：frontmostAppDescriptor 形状契约 + sendTestHookEvent 失败路径冒烟
    ///（死端口驱动 token 生成→请求构建→URLSession 异步失败分支；hookPort/appToken
    /// Runner 域存-还守护，不对生产 hook 端口发任何请求）。
    func runHookTestFailurePathTests() {
        print("\n=== HookTestFailurePath (B242) ===")

        // --- frontmostAppDescriptor：bundleID#pid:name 形状（无前台 app 时字面 nil） ---
        let desc = frontmostAppDescriptor()
        check("hookFail: descriptor 非空", !desc.isEmpty)
        if desc != "nil" {
            let pidPart = desc.split(separator: "#")[1].prefix(while: { $0.isNumber })
            check("hookFail: descriptor 形状 bundleID#pid:name",
                  desc.contains("#") && desc.contains(":") && Int(pidPart) != nil)
        } else {
            check("hookFail: 无前台 app → 字面 nil 合法", true)
        }

        // --- sendTestHookEvent 失败路径：端口 1（保留端口必拒连）→ 异步失败分支 ---
        var view = SettingsView()
        let savedPort = view.hookPort
        view.hookPort = 1
        view.sendTestHookEvent()
        // URLSession 连接拒绝为异步回调；短暂泵主 RunLoop 等其落地（≤2s 上限）
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check("hookFail: 死端口失败路径全程无异常", true)
        view.hookPort = savedPort
    }
}
