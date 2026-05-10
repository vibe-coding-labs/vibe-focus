import SwiftUI

struct LANSettingsView: View {
    @AppStorage(LANHookPreferences.lanModeKey) var lanMode = false
    @State var remoteBindings: [String: UInt32?] = LANHookPreferences.remoteBindings
    @State var newMachineLabel = ""

    var body: some View {
        SettingsCard(
            title: "局域网 Hook",
            subtitle: "允许局域网内其他机器发送 Hook 事件到本机。"
        ) {
            SettingsRow(
                title: "局域网模式",
                detail: "开启后监听 0.0.0.0，允许局域网设备连接"
            ) {
                Toggle("", isOn: Binding(
                    get: { lanMode },
                    set: { newValue in
                        lanMode = newValue
                        LANHookPreferences.lanMode = newValue
                        if ClaudeHookPreferences.isEnabled {
                            ClaudeHookServer.shared.applyPreferences()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }

            if lanMode {
                lanDetailSection
            }
        }
    }

    private var lanDetailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            SettingsRow(
                title: "本机 LAN IP",
                detail: "远程机器的 hook-forwarder 需要指向此地址"
            ) {
                Text(LANHookPreferences.currentLANIP())
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("远程机器映射")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("刷新") {
                    remoteBindings = LANHookPreferences.remoteBindings
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            remoteBindingsList

            addMachineRow

            Text("在远程机器的 ~/.vibefocus/hook-config.json 中添加 \"machine_label\": \"标签名\"")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remoteBindingsList: some View {
        VStack(spacing: 8) {
            let sortedLabels = remoteBindings.keys.sorted()
            if sortedLabels.isEmpty {
                Text("暂无远程机器")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedLabels, id: \.self) { label in
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))

                    Text(label)
                        .font(.system(size: 12, weight: .medium))

                    Spacer()

                    if let windowID = remoteBindings[label] ?? nil {
                        Text("窗口 \(windowID)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未映射")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Button("映射当前窗口") {
                        mapCurrentWindow(for: label)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("删除") {
                        var updated = remoteBindings
                        updated.removeValue(forKey: label)
                        remoteBindings = updated
                        LANHookPreferences.remoteBindings = updated
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            }
        }
    }

    private var addMachineRow: some View {
        HStack {
            TextField("machine_label", text: $newMachineLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .font(.system(size: 12))
            Button("添加") {
                let trimmed = newMachineLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var updated = remoteBindings
                if updated[trimmed] == nil {
                    updated[trimmed] = nil
                    remoteBindings = updated
                    LANHookPreferences.remoteBindings = updated
                }
                newMachineLabel = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(newMachineLabel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func mapCurrentWindow(for label: String) {
        guard let identity = WindowManager.shared.captureFocusedWindowIdentity() else {
            return
        }
        var updated = remoteBindings
        updated[label] = identity.windowID
        remoteBindings = updated
        LANHookPreferences.remoteBindings = updated
    }
}
