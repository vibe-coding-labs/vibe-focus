import SwiftUI

// MARK: - Agent 接入（design-agent-access.md §5 授权模型的人侧面板）
// 总开关 + 两级写授权子开关，默认全关——人的一次明确授权动作。
// 命令 API 骑在 hook 服务上（同一 server 同一 token 门），未开 Hook 服务时
// Agent 即使有授权也无可达端点，置顶提示交代依赖。
// 开关用 @AppStorage 直写 UserDefaults.standard（与 AgentAccessPreferences 同键同域），
// App 内 API handler 每请求实时读取——改开关即刻生效，无需重启。

extension SettingsView {

    var agentAccessSection: some View {
        SettingsCard(
            title: "Agent 接入",
            subtitle: "让 Claude Code / Codex / ZCode 等 Agent 像你一样使用 VibeFocus 的能力：看见窗口（结构化列表，不用截图猜）、摆放窗口、创建网格、捕获/恢复布局、向你发通知。人保持控制权：分级授权，默认全关。",
            icon: "cpu"
        ) {
            if !hookEnabled {
                InfoBanner(
                    style: .warning,
                    title: "Hook 服务未开启",
                    text: "Agent 接入的命令服务随 Hook 服务同端口监听。请先到「Claude 集成」页打开「Hook 服务」开关。"
                )
                Divider()
            }

            SettingsRow(
                title: "启用 Agent 接入",
                detail: "Agent 可读取状态：窗口列表、live 会话、布局快照（只读，无风险）。凭据与 Hook 相同（设置页 token），仅本机可达。"
            ) {
                Toggle("", isOn: $agentAccessEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            SettingsRow(
                title: "允许 Agent 摆放窗口",
                detail: "拉回主屏、浮动、聚焦、摆位、切空间、向你发通知、捕获快照。每次操作落审计（agent 归因），可在日志中追溯。"
            ) {
                Toggle("", isOn: $agentAllowWindowOps)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!agentAccessEnabled)
            }

            Divider()

            SettingsRow(
                title: "允许 Agent 创建网格 / 恢复布局",
                detail: "会真实创建终端窗口并执行启动命令，或按快照重排现有窗口。建议配合「先捕获再恢复」使用：快照就是 Agent 的撤销点。"
            ) {
                Toggle("", isOn: $agentAllowCreateWindows)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!agentAccessEnabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Agent 怎么用")
                    .font(.system(size: 12, weight: .semibold))
                Text("终端（CLI）：VibeFocusHotkeys windows list / move-main --id <N> / grid create。MCP 工具（claude code 等）：把 VibeFocusMCP 注册为 MCP server 后即可调用 vibefocus_* 工具族。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("永不开放给 Agent：退出本应用、修改热键、修改安全设置、卸载 Hook。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
