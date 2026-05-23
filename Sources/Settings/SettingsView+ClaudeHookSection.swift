import SwiftUI

// MARK: - Claude Code 集成
extension SettingsView {

    var claudeHookSection: some View {
        SettingsCard(
            title: "Claude Code 集成",
            subtitle: "让 VibeFocus 监听 Claude Code 的对话事件，实现对话完成后自动将终端窗口拉回主屏幕并最大化。"
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow.opacity(0.8))
                    .font(.system(size: 14))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("工作原理")
                        .font(.system(size: 13, weight: .semibold))
                    Text("开启服务并安装 Hook 后，Claude Code 会在对话结束时自动将终端窗口移到主屏幕。开启「提交后自动恢复」后，在你提交新提示词时窗口会自动回到原来的位置 — 无需手动按快捷键。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.06))
            )

            Divider()

            SettingsRow(
                title: "Hook 服务",
                detail: hookServer.isRunning ? hookServer.statusDescription : "未启动"
            ) {
                HStack(spacing: 10) {
                    SettingsStatusPill(
                        title: hookServer.isRunning ? "运行中" : "未启动",
                        tint: hookServer.isRunning ? .green : .gray
                    )
                    Toggle("", isOn: Binding(
                        get: { hookEnabled },
                        set: { newValue in
                            hookEnabled = newValue
                            ClaudeHookPreferences.isEnabled = newValue
                            if newValue {
                                ClaudeHookPreferences.ensureTokenGenerated()
                                hookToken = ClaudeHookPreferences.authToken ?? ""
                            }
                            hookServer.applyPreferences()
                        }
                    ))
                    .labelsHidden()
                }
            }

            Divider()

            SettingsRow(
                title: "Hook 安装状态",
                detail: ClaudeHookPreferences.isHookInstalled
                    ? "已安装到 ~/.claude/settings.json"
                    : "尚未安装"
            ) {
                SettingsStatusPill(
                    title: ClaudeHookPreferences.isHookInstalled ? "已安装" : "未安装",
                    tint: ClaudeHookPreferences.isHookInstalled ? .green : .orange
                )
            }

            HStack(spacing: 12) {
                Button(ClaudeHookPreferences.isHookInstalled ? "重新安装" : "一键安装 Hook") {
                    let (ok, msg) = ClaudeHookPreferences.installHookToClaudeSettings()
                    hookInstallSucceeded = ok
                    hookInstallMessage = msg
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hookEnabled)

                if ClaudeHookPreferences.isHookInstalled {
                    Button("卸载") {
                        let (ok, msg) = ClaudeHookPreferences.uninstallHookFromClaudeSettings()
                        hookInstallSucceeded = ok
                        hookInstallMessage = msg
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }

                Button("复制配置 JSON") {
                    let json = ClaudeHookPreferences.generateHooksJSON()
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(json, forType: .string)
                    hookInstallMessage = "已复制到剪贴板"
                    hookInstallSucceeded = true
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let msg = hookInstallMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(hookInstallSucceeded ? .green : .red)
            }

            Divider()

            SettingsRow(title: "触发时机", detail: "选择何时自动将终端窗口拉回主屏幕") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("对话完成（Stop 事件，推荐）", isOn: Binding(
                        get: { triggerOnStop },
                        set: { newValue in
                            triggerOnStop = newValue
                            ClaudeHookPreferences.triggerOnStop = newValue
                            if hookEnabled { hookServer.applyPreferences() }
                        }
                    ))
                    .toggleStyle(.checkbox)

                    Toggle("会话结束（SessionEnd 事件）", isOn: Binding(
                        get: { triggerOnSessionEnd },
                        set: { newValue in
                            triggerOnSessionEnd = newValue
                            ClaudeHookPreferences.triggerOnSessionEnd = newValue
                            if hookEnabled { hookServer.applyPreferences() }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            Text("Stop：每次 Claude 回复完成后触发。SessionEnd：Claude 进程退出时触发。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            SettingsRow(
                title: "提交后自动恢复",
                detail: "提交新提示词时，自动将窗口恢复到原来的屏幕、工作区和位置"
            ) {
                Toggle("", isOn: Binding(
                    get: { autoRestoreOnPromptSubmit },
                    set: { newValue in
                        autoRestoreOnPromptSubmit = newValue
                        ClaudeHookPreferences.autoRestoreOnPromptSubmit = newValue
                        if hookEnabled { hookServer.applyPreferences() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            Text("与「对话完成移到主屏幕」配合使用，实现全自动的窗口来回切换。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            SettingsRow(
                title: "监听端口",
                detail: "默认 \(ClaudeHookPreferences.defaultPort)"
            ) {
                TextField("", value: Binding(
                    get: { hookPort },
                    set: { newValue in
                        let clamped = max(1024, min(65535, newValue == 0 ? ClaudeHookPreferences.defaultPort : newValue))
                        hookPort = clamped
                        ClaudeHookPreferences.listenPort = clamped
                        if hookEnabled { hookServer.applyPreferences() }
                    }
                ), formatter: {
                    let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 1024; f.maximum = 65535; return f
                }())
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }

            SettingsRow(title: "鉴权 Token", detail: "自动生成，Hook 安装时同步写入 Claude 配置，确保通信安全") {
                HStack(spacing: 8) {
                    if hookToken.isEmpty {
                        Text("未生成")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(hookToken.prefix(8)) + "...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Button(hookToken.isEmpty ? "生成" : "重新生成") {
                        hookToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
                        ClaudeHookPreferences.authToken = hookToken
                        if hookEnabled { hookServer.applyPreferences() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }

            if !hookToken.isEmpty {
                Text("Token 已自动同步到 Hook 脚本配置，无需重新安装")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            SettingsRow(title: "运行状态", detail: sessionRegistry.lastEventDescription) {
                VStack(alignment: .trailing, spacing: 4) {
                    if let lastEvent = hookServer.lastEventAt {
                        Text("最近事件 \(lastEvent, style: .time)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("已处理 \(hookServer.handledRequestCount) / 总计 \(hookServer.totalRequestCount) / 未匹配 \(hookServer.unmatchedSessionCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let error = hookServer.lastErrorMessage, !error.isEmpty {
                Text("错误：\(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            activeSessionList
            completedSessionList

            Divider()

            HStack(spacing: 12) {
                Button("发送测试事件") {
                    sendTestHookEvent()
                }
                .buttonStyle(.bordered)
                .disabled(!hookEnabled || !hookServer.isRunning)

                Button("清除绑定") {
                    sessionRegistry.clearAllBindings()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)

                Spacer()
            }

            Text("测试：SessionStart 绑定当前窗口 → 1 秒后 SessionEnd 触发移动")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
