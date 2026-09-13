import AppKit
import SwiftUI

// MARK: - 编排页 · 已保存会话快照卡（2026-09-13 会话恢复 v2：多屏×多工作区×远程会话）
extension SettingsView {

    var savedLayoutsCard: some View {
        SettingsCard(
            title: "已保存布局",
            subtitle: "捕获完整桌面现场：全部屏幕与工作区的终端窗口、工作目录、Claude 会话（含 SSH 远程，恢复时自动登录远端并 claude --resume）。",
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

    /// 快照行：屏幕图标 + 名称/元数据 + 动作
    func gridSnapshotRow(_ snapshot: SessionRestoreSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(snapshot.windows.count) 窗")
                    if snapshot.displayCount > 1 {
                        Text("·")
                        Text("\(snapshot.displayCount) 屏")
                    }
                    if snapshot.spaceCount > 1 {
                        Text("·")
                        Text("\(snapshot.spaceCount) 工作区")
                    }
                    Text("·")
                    Text("\(snapshot.sessionPaneCount) session")
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
                runGridTask { await SessionRestoreController.shared.restoreLayout(snapshotID: snapshot.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                SessionRestoreController.shared.removeSnapshot(id: snapshot.id)
                gridSnapshots = SessionRestoreController.shared.snapshotsForRefresh()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("删除快照")
        }
    }
}
