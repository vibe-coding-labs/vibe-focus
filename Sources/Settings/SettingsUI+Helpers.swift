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
        // P-INST-106: 版本显示字符串构造耗时（Bundle.main.infoDictionary 字典查找 + 字符串拼接；设置 UI 渲染调用）。
        let avdStart = Date()
        defer {
            log("SettingsUI.appVersionDisplay finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: avdStart))
            ])
        }
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion ?? AppVersion.current : AppVersion.current
        return "v\(version)"
    }

    var bundleIdentifier: String {
        // P-INST-107: bundleIdentifier 读取耗时（Bundle.main.bundleIdentifier；设置 UI 多处调用）。
        let biStart = Date()
        defer {
            log("SettingsUI.bundleIdentifier finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: biStart))
            ])
        }
        return Bundle.main.bundleIdentifier ?? "com.vibefocus.app"
    }

    var currentAppPath: String {
        // P-INST-108: 当前 app 路径读取耗时（Bundle.main.bundleURL.path；设置 UI + 安装位置检测调用）。
        let capStart = Date()
        defer {
            log("SettingsUI.currentAppPath finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: capStart))
            ])
        }
        return Bundle.main.bundleURL.path
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
