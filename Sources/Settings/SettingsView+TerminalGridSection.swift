import AppKit
import SwiftUI

// MARK: - 编排页（终端网格 · Claude 会话编排）
// 独立标签页：屏幕布局 minimap 为主视觉，参数/偏好/快照各归其卡。
// 2026-09-07 拆分：参数/会话卡 → +TerminalGridActions，快照卡 → +TerminalGridSnapshots，
// 通用控件 → GridSnapshotWidgets.swift。目标摘要文案提纯为 GridTargetCode.summaryText。
extension SettingsView {

    @ViewBuilder
    var terminalGridSection: some View {
        Group {
        gridMinimapPanel

        gridParamsCard

        terminalSessionCard

        // 已保存布局
        if !gridSnapshots.isEmpty {
            savedLayoutsCard
        }
        }
        .onAppear {
            refreshGridMinimap()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // 接拔显示器 / 分辨率变化后重建缩略图
            refreshGridMinimap()
        }
    }

    /// 主视觉：真实屏幕布局 minimap（点阵画布）
    var gridMinimapPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                SectionIconChip(icon: "display")

                Text("屏幕布局")
                    .font(.system(size: 13.5, weight: .semibold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(VibeColors.success)
                        .frame(width: 5, height: 5)
                        .shadow(color: VibeColors.success.opacity(0.6), radius: 2.5)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(VibeColors.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(VibeColors.success.opacity(0.10)))
                .overlay(Capsule().strokeBorder(VibeColors.success.opacity(0.20), lineWidth: 1))

                Text("点屏幕选目标屏 · 点胶囊选工作区")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if let selectedSummary = gridTargetSummary {
                    Text(selectedSummary)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(VibeColors.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(VibeColors.accent.opacity(0.09)))
                        .overlay(Capsule().strokeBorder(VibeColors.accent.opacity(0.22), lineWidth: 1))
                }
            }

            ScreenMinimapView(
                screens: gridMinimapScreens,
                selected: GridTargetCode.parse(gridTargetCode),
                gridPreviewRows: gridRows,
                gridPreviewCols: gridCols,
                height: 320,
                onSelect: { target in
                    gridTargetCode = target.code
                    TerminalGridPreferences.target = target.code
                }
            )
            .padding(.top, 12)

            if GridTargetCode.parse(gridTargetCode)?.explicitDisplayID.map({ displayID in
                !gridMinimapScreens.contains { $0.displayID == displayID }
            }) == true {
                InfoBanner(style: .warning, text: "当前编排目标的显示器已断开（\(gridTargetCode)）。") {
                    Button("重置为主屏") {
                        gridTargetCode = GridTargetCode.main.code
                        TerminalGridPreferences.target = gridTargetCode
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 12)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                .fill(Color.primary.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
    }

    /// 当前编排目标的摘要胶囊文案
    var gridTargetSummary: String? {
        GridTargetCode.parse(gridTargetCode)?.summaryText
    }

    /// minimap 数据构建：真实屏幕快照（Cocoa frame）+ yabai 空间快照。
    /// yabai 不可用时 Space 带为空，minimap 退化为纯屏幕选择，功能不缺失。
    func refreshGridMinimap() {
        let spacesByYabaiDisplay: [Int: [ScreenLayoutMapper.InputSpace]] = Dictionary(grouping: (SpaceController.shared.querySpaces() ?? []).compactMap { info -> (display: Int, space: ScreenLayoutMapper.InputSpace)? in
            guard let index = info.index, let display = info.display else { return nil }
            return (display, ScreenLayoutMapper.InputSpace(yabaiIndex: index, isVisible: info.isVisible ?? false))
        }, by: { $0.display }).mapValues { $0.map { $0.space }.sorted { $0.yabaiIndex < $1.yabaiIndex } }

        gridMinimapScreens = NSScreen.screens.map { screen in
            let displayID = CoordinateKit.cgDisplayID(for: screen) ?? 0
            let yabaiIndex = CoordinateKit.yabaiDisplayIndex(for: screen)
            return ScreenLayoutMapper.InputScreen(
                displayID: displayID,
                name: screen.localizedName,
                cocoaFrame: screen.frame,
                isMain: displayID == CGMainDisplayID(),
                spaces: yabaiIndex.flatMap { spacesByYabaiDisplay[$0] } ?? []
            )
        }
    }
}
