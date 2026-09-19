import SwiftUI

// MARK: - Codex CLI 集成（2026-09-07 B21 自 ClaudeHookSection 拆出视图；B205 升独立标签页）
// Codex 的 Hook schema 与 Claude Code 同构，复用同一 Hook 服务与辅助脚本。
// 安装状态的三处三元表达式收敛为 InstallPresentation 单一事实源（Runner 直测）。
// B205：不再是 Claude 集成页卡片内的尾块，独立成「Codex 集成」标签页——
// 主开关（Hook 服务）仍在「Claude 集成」页，跨页依赖用置顶提示交代。

extension SettingsView {

    /// 安装状态展示映射（纯决策，Runner 穷尽锁定）
    enum CodexInstallPresentation {
        static func pillTitle(installed: Bool) -> String { installed ? "已安装" : "未安装" }
        static func pillTintName(installed: Bool) -> String { installed ? "success" : "warning" }
        static func detailText(installed: Bool) -> String {
            installed ? "已安装到 ~/.codex/hooks.json" : "尚未安装"
        }
    }

    /// 「Codex 集成」标签页内容（B205：独立 SettingsCard）
    var codexSection: some View {
        SettingsCard(
            title: "Codex CLI 集成",
            subtitle: "Codex 的 Hook schema 与 Claude Code 同构，复用同一个 Hook 服务与辅助脚本，写入独立的 ~/.codex/hooks.json。已注册 SessionStart（会话绑定）、Stop（完成回合 → 拉主屏 + 语音播报 + 面板「已完成」，跟随「Claude 集成」页触发开关）、UserPromptSubmit（提交 → 绑定归位 + 面板「运行中」+ 环境上下文注入，跟随「提交后自动归位」开关）、PermissionRequest（弹权限确认停下等批准 → 等待输入通知，跟随「Claude 集成」页通知开关）与 SessionEnd（会话结束拉回，跟随「Claude 集成」页开关）。",
            icon: "terminal.fill"
        ) {
            if !hookEnabled {
                InfoBanner(
                    style: .warning,
                    title: "Hook 服务未开启",
                    text: "Codex 安装与触发依赖 Hook 服务。请先到「Claude 集成」页打开「Hook 服务」开关，再回到这里安装。"
                )

                Divider()
            }

            HStack(spacing: 12) {
                Button(CodexHookPreferences.isHookInstalled() ? "重新安装" : "安装到 Codex CLI") {
                    let (ok, msg) = CodexHookPreferences.installHookToCodexSettings()
                    codexInstallSucceeded = ok
                    codexInstallMessage = msg
                }
                .buttonStyle(.vibeProminent)
                .disabled(!hookEnabled)

                if CodexHookPreferences.isHookInstalled() {
                    Button("卸载") {
                        let (ok, msg) = CodexHookPreferences.uninstallHookFromCodexSettings()
                        codexInstallSucceeded = ok
                        codexInstallMessage = msg
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(VibeColors.danger)
                }

                Spacer()
            }

            if let msg = codexInstallMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(codexInstallSucceeded ? VibeColors.success : VibeColors.danger)
            }

            Text("Codex 按 hooks 内容 hash 记忆信任：安装或变更 hooks 后，需在 Codex TUI 执行 /hooks 确认信任（未信任的 hooks 会被静默跳过）。触发时机与「Claude 集成」页的 Claude Code 设置共享。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            SettingsRow(
                title: "Codex Hook 安装状态",
                detail: CodexInstallPresentation.detailText(installed: CodexHookPreferences.isHookInstalled())
            ) {
                SettingsStatusPill(
                    title: CodexInstallPresentation.pillTitle(installed: CodexHookPreferences.isHookInstalled()),
                    tint: CodexInstallPresentation.pillTintName(installed: CodexHookPreferences.isHookInstalled()) == "success" ? VibeColors.success : VibeColors.warning
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("发送 Codex 测试事件") {
                        sendCodexPermissionTestEvent()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hookEnabled)

                    Button("测试 Stop") {
                        sendCodexStopTestEvent()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hookEnabled)

                    Button("测试提交") {
                        sendCodexPromptSubmitTestEvent()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hookEnabled)

                    Spacer()
                }

                Text("端到端验证三条通路：「发送 Codex 测试事件」= PermissionRequest 等待批准 → 通知中心（开启「等待输入系统通知」后应弹提醒，关闭时返回 notification_disabled 同样算通）；「测试 Stop」= 完成回合 → 移窗管线（该测试会话无绑定，诚实返回 no_binding_skip 即算通）+ 完成语音播报 + 面板翻「已完成」；「测试提交」= UserPromptSubmit → 归位管线 + 面板翻「运行中」。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let msg = codexTestMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// codex 测试事件 payload 构建（B241 提纯：基础三字段 + 调用方 extraFields 合并，
    /// 同键冲突以基础三字段胜（merge 闭包保 current）——与原内联 merge 语义一致）。
    nonisolated static func makeCodexTestPayload(
        event: String,
        sessionID: String,
        extraFields: [String: String] = [:]
    ) -> [String: String] {
        var payload: [String: String] = [
            "event": event,
            "session_id": sessionID,
            "source": "test-ui"
        ]
        payload.merge(extraFields) { current, _ in current }
        return payload
    }

    /// 通用 codex 测试事件发送（B207 自 B206 的 PermissionRequest 专用版泛化）：
    /// 走同一 hook 端点与 token 门，session 前缀 codex-test- 便于日志辨认。
    private func sendCodexTestEvent(
        event: String,
        extraFields: [String: String],
        startedMessage: @escaping (String) -> String
    ) {
        let port = hookPort
        let testSessionID = "codex-test-\(UUID().uuidString.prefix(8))"
        if hookToken.isEmpty {
            ClaudeHookPreferences.ensureTokenGenerated()
            hookToken = ClaudeHookPreferences.authToken ?? ""
        }
        let token = hookToken.isEmpty ? nil : hookToken

        log(
            "[Settings] sending codex test event",
            fields: [
                "event": event,
                "sessionID": testSessionID,
                "port": String(port),
                "hasToken": String(token != nil)
            ]
        )

        let payload = Self.makeCodexTestPayload(
            event: event, sessionID: testSessionID, extraFields: extraFields)

        Self.sendHookRequest(
            port: port,
            endpoint: ClaudeHookPreferences.endpointPath,
            payload: payload,
            token: token
        ) { result in
            switch result {
            case .success:
                DispatchQueue.main.async {
                    codexTestMessage = startedMessage(testSessionID)
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    codexTestMessage = "发送失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// B206：发送 codex PermissionRequest 测试事件——端到端验证「等用户批准 → 通知
    /// 中心」通路。服务器按「等待输入通知」开关门控（关闭时响应 notification_disabled，
    /// 也是诚实结果）。
    func sendCodexPermissionTestEvent() {
        sendCodexTestEvent(
            event: "PermissionRequest",
            extraFields: ["message": "Codex 权限确认测试：等待你的批准"]
        ) { session in
            "测试事件已发送（session=\(session)）——已开启通知开关时通知中心应有提醒"
        }
    }

    /// B207：发送 codex Stop 测试事件——验证「完成回合 → 移窗管线 + 完成语音播报 +
    /// 面板 done」通路。无绑定会话诚实返回 no_binding_skip（移窗管线通到了但没有
    /// 该会话的窗口记录）；语音播报开关开启时应听到播报。
    func sendCodexStopTestEvent() {
        sendCodexTestEvent(
            event: "Stop",
            extraFields: ["last_assistant_message": "Codex 完成回合测试：这一轮已经做完了"]
        ) { session in
            "测试事件已发送（session=\(session)）——完成语音播报开启时应听到播报；面板中该测试会话翻「已完成」（无绑定窗口，移窗诚实返回 no_binding_skip）"
        }
    }

    /// B207：发送 codex UserPromptSubmit 测试事件——验证「提交 → 绑定/归位管线 +
    /// 面板 running + additionalContext 注入回传」通路。
    func sendCodexPromptSubmitTestEvent() {
        sendCodexTestEvent(
            event: "UserPromptSubmit",
            extraFields: ["prompt": "Codex 提交测试"]
        ) { session in
            "测试事件已发送（session=\(session)）——面板中该测试会话翻「运行中」；「提交后自动归位」开启时走归位管线（无绑定窗口则诚实跳过）"
        }
    }
}
