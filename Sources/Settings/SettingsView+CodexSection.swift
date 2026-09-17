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
            subtitle: "Codex 的 Hook schema 与 Claude Code 同构，复用同一个 Hook 服务与辅助脚本，写入独立的 ~/.codex/hooks.json。语音播报同样在 Stop 事件触发。",
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

            Text("Codex 首次运行 Hook 时需在 Codex 界面确认信任（hook trust 机制）。触发时机与「Claude 集成」页的 Claude Code 设置共享。")
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
        }
    }
}
