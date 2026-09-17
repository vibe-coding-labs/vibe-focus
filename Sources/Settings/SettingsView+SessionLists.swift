// SettingsView+SessionLists.swift
// VibeFocus — 会话列表视图（active/completed 两列表）
// 2026-09-07 B35 从 SettingsUI+Helpers 拆分：视图与展示助手分域
// 2026-09-17 B202 activeSessionList 升级为 live 会话面板：状态徽章（运行中/等待
// 输入/已完成…派生自 B202 SessionActivityTracker 事件流）+屏/space（一次
// `yabai query --windows` 聚合，后台 async fork 不占主线程）+2s 自动刷新。

import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Session Lists

    var activeSessionList: some View {
        SessionLivePanelView()
    }
}

/// B202 live 会话面板：注册表绑定 × 活动追踪 × yabai 地理 三路 join 的实时列表。
struct SessionLivePanelView: View {
    @StateObject private var sessionRegistry = SessionWindowRegistry.shared
    @StateObject private var tracker = SessionActivityTracker.shared
    @State private var geo: [UInt32: SessionWindowGeo] = [:]
    @State private var now = Date()
    @State private var geoFetchTask: Task<Void, Never>?

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let rows = SessionPanelLogic.buildRows(
            bindings: sessionRegistry.activeBindingsForUI,
            activities: tracker.activities,
            geo: geo,
            now: now
        )
        Group {
            if rows.isEmpty {
                Text("暂无活跃会话绑定")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.sessionID) { row in
                        rowView(row)
                    }
                }
            }
        }
        .onAppear { now = Date() }
        .onReceive(refreshTimer) { tick in
            now = tick
            refreshGeo()
        }
        .onDisappear { geoFetchTask?.cancel() }
    }

    /// 地理刷新：有活跃绑定才 fork（零会话零开销）；queryJSONAsync 在后台线程
    /// 执行（B180 纪律——yabai fork 永不占主线程）；旧任务未完成时跳过本轮
    /// （防 yabai 卡顿下 2s 拍堆积并发 fork）。
    private func refreshGeo() {
        guard !sessionRegistry.activeBindingsForUI.isEmpty else {
            geo = [:]
            return
        }
        guard geoFetchTask == nil else { return }
        geoFetchTask = Task { @MainActor in
            let windows = await YabaiClient.queryJSONAsync([YabaiWindowInfo].self, arguments: ["query", "--windows"])
            geo = SessionPanelLogic.geoMap(fromWindows: windows ?? [])
            geoFetchTask = nil
        }
    }

    private func rowView(_ row: SessionLiveRow) -> some View {
        HStack(spacing: 8) {
            Text(row.status.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(statusTint(row.status).opacity(0.16))
                )
                .foregroundStyle(statusTint(row.status))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.app ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                    if let project = row.project {
                        Text(project)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if row.isRemote {
                        Text("远程")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(VibeColors.neutral.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text("sess=\(row.sessionID.prefix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let screen = row.screenLabel {
                        Text(screen)
                        if let space = row.space {
                            Text("space\(space)")
                        }
                    } else {
                        Text("窗不可见/离屏")
                    }
                    if let age = SessionPanelLogic.relativeAge(row.lastActivityAt, now: now) {
                        Text(age)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer()
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

    /// 状态→色 token：等待输入=警告橙（最该看）、运行中=成功绿、其余中性。
    private func statusTint(_ status: SessionLiveStatus) -> Color {
        switch status {
        case .waiting: return VibeColors.warning
        case .running: return VibeColors.success
        case .bound, .done, .ended: return VibeColors.neutral
        }
    }
}

extension SettingsView {

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
