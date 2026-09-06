import SwiftUI

// MARK: - Codex CLI 集成（2026-09-07 B21 从 ClaudeHookSection 拆分）
// Codex 的 Hook schema 与 Claude Code 同构，复用同一 Hook 服务与辅助脚本。
// 安装状态的三处三元表达式收敛为 InstallPresentation 单一事实源（Runner 直测）。

extension SettingsView {

    /// 安装状态展示映射（纯决策，Runner 穷尽锁定）
    enum CodexInstallPresentation {
        static func pillTitle(installed: Bool) -> String { installed ? "已安装" : "未安装" }
        static func pillTintName(installed: Bool) -> String { installed ? "success" : "warning" }
        static func detailText(installed: Bool) -> String {
            installed ? "已安装到 ~/.codex/hooks.json" : "尚未安装"
        }
    }

    @ViewBuilder
    var codexHookRows: some View {
            // MARK: - Codex CLI 集成

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(VibeColors.accent.opacity(0.8))
                    .font(.system(size: 14))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex CLI")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Codex 的 Hook schema 与 Claude Code 同构，复用同一个 Hook 服务与辅助脚本，写入独立的 ~/.codex/hooks.json。语音播报同样在 Stop 事件触发。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                    .fill(VibeColors.accent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VibeRadius.panel, style: .continuous)
                    .strokeBorder(VibeColors.accent.opacity(0.14), lineWidth: 1)
            )

            HStack(spacing: 12) {
                Button(CodexHookPreferences.isHookInstalled ? "重新安装" : "安装到 Codex CLI") {
                    let (ok, msg) = CodexHookPreferences.installHookToCodexSettings()
                    codexInstallSucceeded = ok
                    codexInstallMessage = msg
                }
                .buttonStyle(.vibeProminent)
                .disabled(!hookEnabled)

                if CodexHookPreferences.isHookInstalled {
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

            Text("Codex 首次运行 Hook 时需在 Codex 界面确认信任（hook trust 机制）。触发时机与上方 Claude Code 设置共享。")

        SettingsRow(
            title: "Codex Hook 安装状态",
            detail: CodexInstallPresentation.detailText(installed: CodexHookPreferences.isHookInstalled)
        ) {
            SettingsStatusPill(
                title: CodexInstallPresentation.pillTitle(installed: CodexHookPreferences.isHookInstalled),
                tint: CodexInstallPresentation.pillTintName(installed: CodexHookPreferences.isHookInstalled) == "success" ? VibeColors.success : VibeColors.warning
            )
        }
    }
}
