// SettingsUI+Helpers.swift
// VibeFocus — SettingsView 计算属性与会话列表
// 从 SettingsUI.swift 中提取

import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Session Lists

    var activeSessionList: some View {
        let active = sessionRegistry.activeBindingsForUI
        if active.isEmpty {
            return AnyView(
                Text("暂无活跃会话绑定")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            )
        }
        return AnyView(
            VStack(spacing: 6) {
                ForEach(active, id: \.windowID) { binding in
                    HStack {
                        Text(binding.appName ?? "Unknown")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(binding.sessionID?.prefix(8) ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        )
    }

    var completedSessionList: some View {
        let recent = sessionRegistry.recentCompletedBindings
        if recent.isEmpty {
            return AnyView(
                Text("暂无最近完成的会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            )
        }
        return AnyView(
            VStack(spacing: 6) {
                ForEach(recent, id: \.windowID) { binding in
                    HStack {
                        Text(binding.appName ?? "Unknown")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(binding.completedAt?.formatted(.dateTime.hour().minute()) ?? "—")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        )
    }

    // MARK: - Display Helpers

    var appVersionDisplay: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion ?? AppVersion.current : AppVersion.current
        return "v\(version)"
    }

    var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
    }

    var currentAppPath: String {
        Bundle.main.bundleURL.path
    }

    var expectedAppPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/VibeFocus.app")
    }

    var otherInstallations: [String] {
        duplicateAppPaths.filter { $0 != currentAppPath }
    }

    var resetAccessCommand: String {
        "tccutil reset Accessibility \(bundleIdentifier)"
    }

    // MARK: - Space Status Helpers

    var spaceStatusTitle: String {
        switch spaceController.availability {
        case .available:
            return "可用"
        case .notInstalled:
            return "未安装"
        case .unavailable:
            return "不可用"
        case .unknown:
            return "未检测"
        }
    }

    var spaceStatusTint: Color {
        switch spaceController.availability {
        case .available:
            return .green
        case .notInstalled, .unknown:
            return .gray
        case .unavailable:
            return .orange
        }
    }

    var spaceStatusDetail: String {
        switch spaceController.availability {
        case .available:
            return "检测到 yabai，可启用跨工作区移动。"
        case .notInstalled:
            return "未检测到 yabai。安装后可启用跨工作区移动功能。"
        case .unavailable:
            return "yabai 已安装但未就绪（可能需要配置 SIP 或授予权限）。"
        case .unknown:
            return "尚未检测 yabai 状态。"
        }
    }
}
