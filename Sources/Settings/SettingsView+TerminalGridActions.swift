import AppKit
import SwiftUI

// MARK: - 编排页 · 网格参数与会话偏好卡（2026-09-07 从 TerminalGridSection 拆分，行为不变）
extension SettingsView {

    /// 网格参数 + 动作
    var gridParamsCard: some View {
        SettingsCard(
            title: "网格",
            subtitle: "行列决定 minimap 预览与落格数量；0 间距 = Rectangle 式无缝铺满。",
            icon: "square.grid.2x2"
        ) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("行 × 列")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        CompactStepper(value: gridRows, range: 1...TerminalGridPlanner.maxGridSize) { newValue in
                            gridRows = newValue
                            TerminalGridPreferences.rows = newValue
                        }
                        Text("×").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        CompactStepper(value: gridCols, range: 1...TerminalGridPlanner.maxGridSize) { newValue in
                            gridCols = newValue
                            TerminalGridPreferences.cols = newValue
                        }
                    }
                }

                Divider()
                    .frame(height: 36)

                VStack(alignment: .leading, spacing: 6) {
                    Text("格子间距")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { gridGap },
                            set: { newValue in
                                let stepped = TerminalGridPlanner.steppedGap(newValue)
                                gridGap = stepped
                                TerminalGridPreferences.gap = CGFloat(stepped)
                            }
                        ), in: 0...24, step: 2)
                        .frame(width: 140)

                        Text(gridGap == 0 ? "无缝" : "\(Int(gridGap))px")
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 48, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    runGridTask { await terminalGridController.createGrid() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                        Text("创建 \(gridRows)×\(gridCols) 网格")
                    }
                    .frame(width: 176)
                }
                .buttonStyle(.vibeProminent)
            }

            HStack(spacing: 10) {
                Button("捕获当前布局") {
                    runGridTask { await terminalGridController.captureLayout() }
                }
                .buttonStyle(.bordered)

                Button("恢复上次布局") {
                    runGridTask { await terminalGridController.restoreLayout() }
                }
                .buttonStyle(.bordered)

                Button {
                    gridSnapshots = terminalGridController.snapshotsForRefresh()
                    gridAutoRestoreSnapshotID = TerminalGridPreferences.autoRestoreSnapshotID
                    refreshGridMinimap()
                    refreshSelectionInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新快照列表与屏幕布局")

                Spacer()

                if !gridResultMessage.isEmpty {
                    Text(gridResultMessage)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(gridResultIsError ? Color.red : Color.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460, alignment: .trailing)
                }
            }
        }
    }

    /// 终端与会话偏好
    var terminalSessionCard: some View {
        SettingsCard(
            title: "终端与会话",
            subtitle: "选择编排目标终端；捕获的布局会记住每个终端的工作目录与 Claude Code session。",
            icon: "terminal"
        ) {
            SettingsRow(title: "终端应用", detail: selectionDetailText) {
                Picker("", selection: Binding(
                    get: { gridAppPreference },
                    set: { gridAppPreference = $0; TerminalGridPreferences.appPreference = $0; refreshSelectionInfo() }
                )) {
                    Text("自动（最近常用）").tag(TerminalGridPreferences.AppPreference.auto)
                    Text("Terminal.app · 完整").tag(TerminalGridPreferences.AppPreference.terminal)
                    Text("iTerm2 · 部分").tag(TerminalGridPreferences.AppPreference.iterm2)
                }
                .frame(width: 190)
                .labelsHidden()
            }

            Divider()

            SettingsRow(title: "每格启动命令", detail: "如 claude；创建网格时逐格执行（恢复有 session 的格子时优先 --resume）") {
                TextField("留空 = 纯 shell", text: Binding(
                    get: { gridLaunchCommand },
                    set: { gridLaunchCommand = $0; TerminalGridPreferences.launchCommand = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .font(.system(size: 12, design: .monospaced))
            }

            Divider()

            SettingsRow(
                title: "自动检测结果",
                detail: gridSelectionPreview?.reason ?? "尚未检测（打开本页时自动检测，或点刷新）"
            ) {
                Button("重新检测") {
                    refreshSelectionInfo()
                }
                .buttonStyle(.bordered)
            }

            if let favoriteWarning = gridFavoriteWarning {
                InfoBanner(style: .tip, text: favoriteWarning)
            }

            Divider()

            SettingsRow(
                title: "重启 / 登录后自动恢复",
                detail: "勾选后每次启动 VibeFocus 自动还原勾选的布局：窗口位置、每个终端的工作目录、Claude 会话（claude --resume）。仍活着的会话不会重复拉起；快照未指定时使用最新一份。"
            ) {
                Toggle("", isOn: Binding(
                    get: { gridAutoRestoreEnabled },
                    set: { newValue in
                        gridAutoRestoreEnabled = newValue
                        TerminalGridPreferences.autoRestoreEnabled = newValue
                        if newValue && gridAutoRestoreSnapshotID == nil {
                            gridAutoRestoreSnapshotID = terminalGridController.snapshotsForRefresh().last?.id
                            TerminalGridPreferences.autoRestoreSnapshotID = gridAutoRestoreSnapshotID
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    /// 「终端应用」行的说明文案（随偏好/检测变化）
    var selectionDetailText: String {
        gridAppPreference.selectionDetailText
    }

    func refreshSelectionInfo() {
        let preview = terminalGridController.selectionPreview()
        gridSelectionPreview = preview
        let usageRank = TerminalUsageTracker.shared.table.ranked(minCount: 5)
        gridFavoriteWarning = TerminalSelectionResolver.unsupportedFavoriteWarning(
            usageRank: usageRank.map { ($0.bundleID, $0.count, $0.lastAt) },
            candidates: TerminalSelectionResolver.supportTable.keys.sorted().map { bundleID in
                TerminalSelectionCandidate(
                    bundleID: bundleID,
                    name: TerminalSelectionResolver.knownNames[bundleID] ?? bundleID,
                    support: TerminalSelectionResolver.supportLevel(forBundleID: bundleID),
                    usageCount: usageRank.first { $0.bundleID == bundleID }?.count ?? 0,
                    lastUsedAt: usageRank.first { $0.bundleID == bundleID }?.lastAt,
                    isRunning: false
                )
            }
        )
    }

    func runGridTask(_ operation: @escaping () async -> TerminalGridController.OperationResult) {
        gridResultMessage = "执行中…"
        gridResultIsError = false
        Task {
            let result = await operation()
            gridResultMessage = result.message
            gridResultIsError = !result.ok
            gridSnapshots = terminalGridController.snapshotsForRefresh()
            gridAutoRestoreSnapshotID = TerminalGridPreferences.autoRestoreSnapshotID
        }
    }
}
