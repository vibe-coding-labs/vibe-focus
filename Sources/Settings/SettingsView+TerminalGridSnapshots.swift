import AppKit
import SwiftUI

// MARK: - 编排页 · 已保存布局快照卡（2026-09-07 从 TerminalGridSection 拆分，行为不变）
extension SettingsView {

    var savedLayoutsCard: some View {
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
    func gridSnapshotRow(_ snapshot: TerminalGridSnapshot) -> some View {
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
}
