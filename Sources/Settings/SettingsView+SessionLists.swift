// SettingsView+SessionLists.swift
// VibeFocus — 会话列表视图（active/completed 两列表）
// 2026-09-07 B35 从 SettingsUI+Helpers 拆分：视图与展示助手分域

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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VibeColors.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(VibeColors.hairline, lineWidth: 1)
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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VibeColors.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(VibeColors.hairline, lineWidth: 1)
                    )
                }
            }
        )
    }
}
