import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookModelsTests.swift — B68：Hook 模型/脚本内容真身契约直测。
// 四个 Standalone 漂移镜像（ClaudeHookPayloadTests/HookEventDecisionTests/
// HookModelsFullTests/HookScriptContentTests）就此退役：镜像测的是本地复制品——
// WindowMoveReason 镜像仍锁 2 cases 而真身 Batch 14 已加 user_prompt_submit（穷举断言
// 对真身失效）、payload 解码段测的是本地夹具而非 ClaudeHookPayload.init(from:)、
// generateMachineLabel/generateHookConfigJSON 真身已内联。本文件全部改测真实现。

extension RunnerHarness {
    func runHookModelsTests() {
        // A. ClaudeHookEventType：穷举/rawValue/Codable/非法拒绝。
        check("hookModels: eventType 四 case 且 rawValue 即线上 JSON 契约",
              ClaudeHookEventType.allCases.count == 4
              && ClaudeHookEventType.sessionStart.rawValue == "SessionStart"
              && ClaudeHookEventType.stop.rawValue == "Stop"
              && ClaudeHookEventType.sessionEnd.rawValue == "SessionEnd"
              && ClaudeHookEventType.userPromptSubmit.rawValue == "UserPromptSubmit")
        let eventTypeRoundtripOK = ClaudeHookEventType.allCases.allSatisfy { e in
            (try? JSONDecoder().decode(ClaudeHookEventType.self, from: JSONEncoder().encode(e))) == e
        }
        check("hookModels: eventType Codable 回环 + 非法值拒绝",
              eventTypeRoundtripOK
              && (try? JSONDecoder().decode(ClaudeHookEventType.self, from: Data("\"Nonsense\"".utf8))) == nil)

        // B. ClaudeHookPayload.init(from:) 解码契约（真身，非夹具）。
        func decode(_ json: String) -> ClaudeHookPayload? {
            try? JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
        let p1 = decode(#"{"event": "UserPromptSubmit", "session_id": "sess-1", "source": "claude-code", "cwd": "/tmp"}"#)
        check("hookModels: payload event 键解码 + source/cwd 透传",
              p1?.event == .userPromptSubmit && p1?.sessionID == "sess-1"
              && p1?.source == "claude-code" && p1?.cwd == "/tmp")
        check("hookModels: payload hook_event_name 键回退（Claude Code HTTP 形状）",
              decode(#"{"hook_event_name": "Stop", "session_id": "sess-2"}"#)?.event == .stop)
        check("hookModels: payload 非法事件值/缺 session_id 双拒绝",
              decode(#"{"event": "Nonsense", "session_id": "s"}"#) == nil
              && decode(#"{"event": "Stop"}"#) == nil)
        check("hookModels: payload sessionId 别名回退",
              decode(#"{"event": "Stop", "sessionId": "sess-camel"}"#)?.sessionID == "sess-camel")
        check("hookModels: payload session_id 首尾空白裁剪",
              decode(#"{"event": "Stop", "session_id": "  sess-pad  "}"#)?.sessionID == "sess-pad")
        check("hookModels: payload 纯空白 session_id 拒绝",
              decode(#"{"event": "Stop", "session_id": "   "}"#) == nil)
        let p2 = decode(#"{"event": "SessionStart", "session_id": "s3", "terminal_ctx": {"term_session_id": "ts-1", "tty": "/dev/ttys003", "ppid": "1234", "window_id": "42", "machine_label": "remote-host"}}"#)
        check("hookModels: payload terminal_ctx 嵌套解码（snake_case 映射）",
              p2?.terminalCtx?.termSessionID == "ts-1" && p2?.terminalCtx?.tty == "/dev/ttys003"
              && p2?.terminalCtx?.ppid == "1234" && p2?.terminalCtx?.windowID == "42"
              && p2?.terminalCtx?.machineLabel == "remote-host")
        check("hookModels: payload 可选字段缺省全 nil",
              { let p = decode(#"{"event": "Stop", "session_id": "s4"}"#)
                return p?.source == nil && p?.timestamp == nil && p?.cwd == nil && p?.model == nil
                  && p?.terminalCtx == nil && p?.lastAssistantMessage == nil && p?.transcriptPath == nil }())
        let p3 = decode(#"{"event": "Stop", "session_id": "s5", "model": "claude-sonnet-4-6", "last_assistant_message": "done", "transcript_path": "/t.jsonl"}"#)
        check("hookModels: payload 扩展字段解码（model/last_assistant_message/transcript_path）",
              p3?.model == "claude-sonnet-4-6" && p3?.lastAssistantMessage == "done"
              && p3?.transcriptPath == "/t.jsonl")

        // C. ClaudeHookResponse 编码线格式（session_id 键名 + nil 键省略）。
        func wire(_ r: ClaudeHookResponse) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]) ?? [:]
        }
        let w1 = wire(ClaudeHookResponse(ok: true, code: "accepted", message: "ok", sessionID: "sess-9", handled: true))
        check("hookModels: response 线格式 session_id 键名 + 五字段齐全",
              (w1["session_id"] as? String) == "sess-9" && (w1["ok"] as? Bool) == true
              && (w1["code"] as? String) == "accepted" && (w1["message"] as? String) == "ok"
              && (w1["handled"] as? Bool) == true && w1.count == 5)
        let w2 = wire(ClaudeHookResponse(ok: false, code: "error", message: "denied", sessionID: nil, handled: false))
        check("hookModels: response nil sessionID 键整体省略",
              w2["session_id"] == nil && w2.count == 4)

        // E. BindingType 持久化契约（B109：bindingType 落 SQLite/审计行的 rawValue 稳定性）
        do {
            check("bindType: rawValue local/remote 契约 + 非法值拒绝",
                  WindowState.BindingType(rawValue: "local") == .local
                  && WindowState.BindingType(rawValue: "remote") == .remote
                  && WindowState.BindingType(rawValue: "sideways") == nil)
            let enc = try? JSONEncoder().encode(["bindingType": WindowState.BindingType.remote])
            let decoded = enc.flatMap { try? JSONDecoder().decode([String: WindowState.BindingType].self, from: $0) }
            check("bindType: Codable 回环保持 remote", decoded?["bindingType"] == .remote)
        }

        // D. WindowIdentity Codable 回环（全字段含 capturedAt 同值过码）+ 可选缺省。
        let ident = WindowIdentity(windowID: 42, pid: 1234, bundleIdentifier: "com.apple.Terminal",
                                   appName: "Terminal", windowNumber: 7, title: "bash — 80x24")
        let identBack = try? JSONDecoder().decode(WindowIdentity.self, from: JSONEncoder().encode(ident))
        check("hookModels: windowIdentity Codable 回环保真",
              identBack == ident)
        let identMin = WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil, windowNumber: nil, title: nil)
        let identMinBack = try? JSONDecoder().decode(WindowIdentity.self, from: JSONEncoder().encode(identMin))
        check("hookModels: windowIdentity 最小构造可选字段 nil 过码",
              identMinBack == identMin && identMinBack?.bundleIdentifier == nil
              && identMinBack?.windowNumber == nil && identMinBack?.title == nil)

        // E. TerminalContext Codable 回环（snake_case 键映射全表）。
        let ctx = TerminalContext(termSessionID: "t", itermSessionID: "i", kittyWindowID: "k",
                                  weztermPane: "w", tty: "/dev/ttys001", ppid: "42",
                                  claudeProjectDir: "/p", windowID: "7", machineLabel: "remote-a-b")
        let ctxJSON = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ctx)) as? [String: Any]
        check("hookModels: terminalContext 线格式 snake_case 九键",
              (ctxJSON?["term_session_id"] as? String) == "t" && (ctxJSON?["iterm_session_id"] as? String) == "i"
              && (ctxJSON?["kitty_window_id"] as? String) == "k" && (ctxJSON?["wezterm_pane"] as? String) == "w"
              && (ctxJSON?["ppid"] as? String) == "42" && (ctxJSON?["claude_project_dir"] as? String) == "/p"
              && (ctxJSON?["machine_label"] as? String) == "remote-a-b")
        let ctxBack = try? JSONDecoder().decode(TerminalContext.self, from: JSONEncoder().encode(ctx))
        check("hookModels: terminalContext Codable 回环保真", ctxBack == ctx)

        // F. 脚本生成族：本机脚本恒直连 127.0.0.1（B170 去 lanMode 缝——不随 LAN IP 漂移）
        //    + 标签/配置 JSON 命名事实源 + install 脚本集成。
        let helper = ClaudeHookPreferences.generateHelperScriptContent()
        check("hookModels: helper 脚本本机恒直连 127.0.0.1（无 host 采集）",
              helper.contains("http://127.0.0.1:$VF_PORT/claude/hook")
              && !helper.contains("VF_HOST")
              && helper.contains("--connect-timeout 1"))
        check("hookModels: machineLabel 点转连字符",
              ClaudeHookPreferences.machineLabel(forHost: "192.168.1.83") == "remote-192-168-1-83")
        check("hookModels: hookConfigJSON 四键模板逐字（extraHosts 空保持旧形状）",
              ClaudeHookPreferences.hookConfigJSON(host: "h", port: 1, token: "t", machineLabel: "m")
              == "{\n  \"host\": \"h\",\n  \"port\": 1,\n  \"token\": \"t\",\n  \"machine_label\": \"m\"\n}")
        check("hookModels: hookConfigJSON extraHosts 附 hosts 数组且 host 保持主地址",
              ClaudeHookPreferences.hookConfigJSON(host: "h", port: 1, token: "t", machineLabel: "m", extraHosts: ["h2", "h3"])
              == "{\n  \"host\": \"h\",\n  \"hosts\": [\n    \"h2\",\n    \"h3\"\n  ],\n  \"port\": 1,\n  \"token\": \"t\",\n  \"machine_label\": \"m\"\n}")
        let install = ClaudeHookPreferences.generateRemoteInstallScript(host: "192.168.1.83")
        check("hookModels: 远程安装脚本集成（config JSON/标签/目标行同源）",
              install.contains("\"machine_label\": \"remote-192-168-1-83\"")
              && install.contains("Machine label: remote-192-168-1-83")
              && install.contains("hook-config.json"))
        let installMulti = ClaudeHookPreferences.generateRemoteInstallScript(
            host: "192.168.1.83", port: 39277, token: "tok", labelOverride: nil,
            extraHosts: ["10.9.0.2"])
        check("hookModels: 远程安装脚本多候选（hosts 数组入 config 且排除主地址重复）",
              installMulti.contains("\"host\": \"192.168.1.83\"")
              && installMulti.contains("\"hosts\": [")
              && installMulti.contains("\"10.9.0.2\""))
        check("hookModels: 远程安装脚本多候选 extraHosts 与主地址重复时去重（不生成 hosts 键）",
              !ClaudeHookPreferences.generateRemoteInstallScript(
                host: "192.168.1.83", port: 39277, token: "tok", labelOverride: nil,
                extraHosts: ["192.168.1.83"]).contains("\"hosts\""))
    }
}
