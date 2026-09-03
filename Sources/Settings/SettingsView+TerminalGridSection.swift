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

            SettingsRow(title: "目标屏", detail: "网格摆放的显示器") {
                Picker("", selection: Binding(
                    get: { gridDisplayMode },
                    set: { gridDisplayMode = $0; TerminalGridPreferences.displayMode = $0 }
                )) {
                    Text("主屏").tag(TerminalGridPreferences.DisplayMode.main)
                    Text("焦点所在屏").tag(TerminalGridPreferences.DisplayMode.focused)
                }
                .frame(width: 140)
                .labelsHidden()
            }

            Divider()

            SettingsRow(title: "终端应用", detail: "auto = iTerm2 在运行则用 iTerm2，否则 Terminal.app") {
                Picker("", selection: Binding(
                    get: { gridAppPreference },
                    set: { gridAppPreference = $0; TerminalGridPreferences.appPreference = $0 }
                )) {
                    Text("自动").tag(TerminalGridPreferences.AppPreference.auto)
                    Text("Terminal.app").tag(TerminalGridPreferences.AppPreference.terminal)
                    Text("iTerm2").tag(TerminalGridPreferences.AppPreference.iterm2)
                }
                .frame(width: 160)
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
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新快照列表")
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
    }

    private func runGridTask(_ operation: @escaping () async -> TerminalGridController.OperationResult) {
        gridResultMessage = "执行中…"
        gridResultIsError = false
        Task {
            let result = await operation()
            gridResultMessage = result.message
            gridResultIsError = !result.ok
            gridSnapshots = terminalGridController.snapshotsForRefresh()
        }
    }
}
