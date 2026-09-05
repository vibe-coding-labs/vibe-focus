import AppKit
import SwiftUI

// MARK: - 终端网格设置（Claude 会话编排）
extension SettingsView {

    @ViewBuilder
    var terminalGridSection: some View {
        SettingsCard(
            title: "终端网格（Claude 会话编排）",
            subtitle: "在目标屏上创建 n×m 终端窗口网格；捕获当前摆法可记住每个终端位置与正在运行的 Claude Code session，恢复时自动 claude --resume。"
        ) {
            HStack(spacing: 24) {
                SettingsRow(title: "行 × 列", detail: "每格一个终端窗口（1…4）") {
                    HStack(spacing: 8) {
                        Stepper("\(gridRows)", value: Binding(
                            get: { gridRows },
                            set: { gridRows = $0; TerminalGridPreferences.rows = $0 }
                        ), in: 1...TerminalGridPlanner.maxGridSize)
                        .frame(width: 84)
                        .labelsHidden()

                        Text("×").foregroundStyle(.secondary)

                        Stepper("\(gridCols)", value: Binding(
                            get: { gridCols },
                            set: { gridCols = $0; TerminalGridPreferences.cols = $0 }
                        ), in: 1...TerminalGridPlanner.maxGridSize)
                        .frame(width: 84)
                        .labelsHidden()
                    }
                }
            }

            Divider()

            SettingsRow(title: "目标屏 / 工作区", detail: "列出所有连接的显示器，yabai 可用时细分到工作区（Space）；选定后编排落在该处") {
                Picker("", selection: Binding(
                    get: { gridTargetCode },
                    set: { gridTargetCode = $0; TerminalGridPreferences.target = $0 }
                )) {
                    ForEach(gridTargetOptions) { option in
                        Text(option.label).tag(option.target.code)
                    }
                }
                .frame(width: 300)
                .labelsHidden()
            }

            Divider()

            SettingsRow(title: "格子间距", detail: "0 = 无缝铺满（Rectangle 默认风格）；相邻格子共享边缘") {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { gridGap },
                        set: { newValue in
                            let stepped = (newValue / 2).rounded() * 2
                            gridGap = stepped
                            TerminalGridPreferences.gap = CGFloat(stepped)
                        }
                    ), in: 0...24, step: 2)
                    .frame(width: 150)

                    Text(gridGap == 0 ? "无缝" : "\(Int(gridGap)) px")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 56, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

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

            HStack(spacing: 12) {
                Button("创建 \(gridRows)×\(gridCols) 网格") {
                    runGridTask { await terminalGridController.createGrid() }
                }
                .buttonStyle(.borderedProminent)

                Button("捕获当前布局") {
                    runGridTask { await terminalGridController.captureLayout() }
                }
                .buttonStyle(.bordered)

                Button("恢复上次布局") {
                    runGridTask { await terminalGridController.restoreLayout() }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    gridSnapshots = terminalGridController.snapshotsForRefresh()
                    gridAutoRestoreSnapshotID = TerminalGridPreferences.autoRestoreSnapshotID
                    refreshGridTargetOptions()
                    refreshSelectionInfo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新快照列表")
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
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                    Text(favoriteWarning)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
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

            if !gridResultMessage.isEmpty {
                Text(gridResultMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(gridResultIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }

            if !gridSnapshots.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("已保存快照")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(gridSnapshots, id: \.id) { snapshot in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(snapshot.name)（\(snapshot.rows)×\(snapshot.cols)，\(snapshot.cells.count) 窗）")
                                    .font(.system(size: 12, weight: .medium))
                                let sessionCount = snapshot.cells.filter { $0.sessionID != nil }.count
                                Text("捕获于 \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(sessionCount) 个 Claude session")
                                    .font(.system(size: 11))
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
                            }
                            Button("恢复") {
                                runGridTask { await terminalGridController.restoreLayout(snapshotID: snapshot.id) }
                            }
                            .buttonStyle(.bordered)
                            Button {
                                terminalGridController.removeSnapshot(id: snapshot.id)
                                gridSnapshots = terminalGridController.snapshotsForRefresh()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help("删除快照")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear {
            refreshGridTargetOptions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // 接拔显示器 / 分辨率变化后重建目标目录
            refreshGridTargetOptions()
        }
    }

    /// 目标目录构建：真实屏幕快照 + yabai 空间快照 → Picker 选项。
    /// 显式选择失效（屏断开等）时附加占位项，避免 Picker 选中值悬空。
    func refreshGridTargetOptions() {
        let screens = NSScreen.screens.map { screen in
            GridTargetCatalog.ScreenInput(
                displayID: CoordinateKit.cgDisplayID(for: screen) ?? 0,
                name: screen.localizedName,
                width: Int(screen.frame.width),
                height: Int(screen.frame.height),
                isMain: CoordinateKit.cgDisplayID(for: screen) == CGMainDisplayID(),
                yabaiDisplayIndex: CoordinateKit.yabaiDisplayIndex(for: screen)
            )
        }
        let spaces = (SpaceController.shared.querySpaces() ?? []).compactMap { info -> GridTargetCatalog.SpaceInput? in
            guard let index = info.index, let display = info.display else { return nil }
            return GridTargetCatalog.SpaceInput(yabaiIndex: index, yabaiDisplayIndex: display, isVisible: info.isVisible ?? false)
        }
        var options = GridTargetCatalog.options(screens: screens, spaces: spaces)
        if let current = GridTargetCode.parse(gridTargetCode), !options.contains(where: { $0.target == current }) {
            options.append(GridTargetOption(target: current, label: "（已断开）\(current.code)", isActiveSpace: true))
        }
        gridTargetOptions = options
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
