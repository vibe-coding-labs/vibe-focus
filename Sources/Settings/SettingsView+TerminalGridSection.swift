import AppKit
import SwiftUI

// MARK: - 编排页（终端网格 · Claude 会话编排）
// 独立标签页：屏幕布局 minimap 为主视觉，参数/偏好/快照各归其卡。
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
    private var gridMinimapPanel: some View {
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

    /// 网格参数 + 动作
    private var gridParamsCard: some View {
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
                                let stepped = (newValue / 2).rounded() * 2
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
    private var terminalSessionCard: some View {
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

    /// 已保存布局
    private var savedLayoutsCard: some View {
        SettingsCard(
            title: "已保存布局",
            subtitle: "捕获的布局快照；恢复时重建窗口并自动 cd 回工作目录、claude --resume。",
            icon: "clock.arrow.circlepath"
        ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(gridSnapshots.indices, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.05))
                                .frame(height: 1)
                        }
                        gridSnapshotRow(gridSnapshots[index])
                            .padding(.vertical, 9)
                    }
                }
            }
    }

    /// 快照行：mini 格位图 + 名称/元数据 + 动作
    private func gridSnapshotRow(_ snapshot: TerminalGridSnapshot) -> some View {
        HStack(spacing: 12) {
            GridSnapshotThumbnail(rows: snapshot.rows, cols: snapshot.cols)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(snapshot.rows)×\(snapshot.cols)")
                    Text("·")
                    Text("\(snapshot.cells.count) 窗")
                    Text("·")
                    Text("\(snapshot.cells.filter { $0.sessionID != nil }.count) session")
                    Text("·")
                    Text(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if gridAutoRestoreSnapshotID == snapshot.id {
                SettingsStatusPill(title: "开机恢复", tint: .green)
                Button("取消") {
                    gridAutoRestoreSnapshotID = nil
                    TerminalGridPreferences.autoRestoreSnapshotID = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("设为开机恢复") {
                    gridAutoRestoreSnapshotID = snapshot.id
                    TerminalGridPreferences.autoRestoreSnapshotID = snapshot.id
                    if !gridAutoRestoreEnabled {
                        gridAutoRestoreEnabled = true
                        TerminalGridPreferences.autoRestoreEnabled = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button("恢复") {
                runGridTask { await terminalGridController.restoreLayout(snapshotID: snapshot.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                terminalGridController.removeSnapshot(id: snapshot.id)
                gridSnapshots = terminalGridController.snapshotsForRefresh()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("删除快照")
        }
    }

    /// 当前编排目标的摘要胶囊文案
    private var gridTargetSummary: String? {
        guard let target = GridTargetCode.parse(gridTargetCode) else { return nil }
        switch target {
        case .main:
            return "→ 主屏"
        case .focused:
            return "→ 焦点屏"
        case .display(let displayID):
            return "→ #\(displayID) 当前 Space"
        case .displaySpace(let displayID, let spaceIndex):
            return "→ #\(displayID) · Space \(spaceIndex)"
        }
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

    /// 「终端应用」行的说明文案（随偏好/检测变化）
    private var selectionDetailText: String {
        switch gridAppPreference {
        case .auto:
            return "自动识别你最常用的终端（优先当前在运行者）；也可手动指定。"
        case .terminal:
            return "手动指定 Terminal.app（完整支持：建窗/注入/tty/精确恢复）。"
        case .iterm2:
            return "手动指定 iTerm2（部分支持：无 tty 映射，自动恢复降级为只重建缺失格）。"
        }
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

    private func runGridTask(_ operation: @escaping () async -> TerminalGridController.OperationResult) {
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

/// 快照行的 mini 格位缩略图（rows×cols 格线示意）
struct GridSnapshotThumbnail: View {
    let rows: Int
    let cols: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(VibeColors.accent.opacity(0.50), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: 30, height: 22)
        .padding(5)
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


/// 紧凑数值步进器：− 数值 ＋（系统 Stepper 在紧凑布局下只剩裸箭头、数值不可见）
struct CompactStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(symbol: "minus", enabled: value > range.lowerBound) { onChange(value - 1) }
            Text("\(value)")
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 26)
            stepButton(symbol: "plus", enabled: value < range.upperBound) { onChange(value + 1) }
        }
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                .fill(VibeColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
    }

    private func stepButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        StepIconButton(symbol: symbol, enabled: enabled, action: action)
    }
}

/// 步进器单键：悬停着色 + 按压回弹（独立视图持有 hover 状态，避免整条重绘）
private struct StepIconButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    enabled
                        ? Color.primary.opacity(isHovered ? 0.85 : 0.5)
                        : Color.primary.opacity(0.16)
                )
                .frame(width: 26, height: 26)
                .background(
                    Rectangle()
                        .fill(Color.primary.opacity(enabled && isHovered ? 0.05 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}
