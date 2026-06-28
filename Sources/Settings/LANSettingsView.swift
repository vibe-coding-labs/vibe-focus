import SwiftUI

/// Settings view for configuring LAN hook remote machine bindings.
struct LANSettingsView: View {
    @AppStorage(LANHookPreferences.lanModeKey) var lanMode = LANHookPreferences.defaultLanMode
    @State var remoteBindings: [String: UInt32?] = LANHookPreferences.remoteBindings
    @State var newMachineLabel = ""
    @State var remoteInstallMessage: String?
    @State var remoteInstallSucceeded = true

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

            Divider()

            remoteInstallSection

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

    private var remoteInstallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("远程一键安装")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                    .font(.system(size: 12))
                Text("复制以下命令，在运行 Claude Code 的远程机器终端执行即可。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            let lanIP = LANHookPreferences.currentLANIP()
            let installScript = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)

            ScrollView {
                Text(installScript)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
            }
            .frame(maxHeight: 200)

            HStack(spacing: 12) {
                Button("复制安装命令") {
                    let lanIP = LANHookPreferences.currentLANIP()
                    let script = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)
                    // P-INST-241: 复制远程安装命令到剪贴板耗时（NSPasteboard.clearContents + setString；设置 UI 按钮触发，currentLANIP P-INST-146/generateRemoteInstallScript 已单独计时；slow-op ≥5ms warn）。
                    let cisStart = Date()
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(script, forType: .string)
                    let durMs = elapsedMilliseconds(since: cisStart)
                    if durMs >= 5 { log("[LANSettings] copy install cmd slow", level: .warn, fields: ["durationMs": String(durMs)]) }
                    remoteInstallMessage = "已复制到剪贴板（\(script.count) 字符）"
                    remoteInstallSucceeded = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("复制 curl 一行命令") {
                    let lanIP = LANHookPreferences.currentLANIP()
                    let script = ClaudeHookPreferences.generateRemoteInstallScript(host: lanIP)
                    let encoded = script.data(using: .utf8)?.base64EncodedString() ?? ""
                    let oneLiner = "echo '\(encoded)' | base64 -d | bash"
                    // P-INST-242: 复制 curl 一行命令到剪贴板耗时（NSPasteboard.clearContents + setString；设置 UI 按钮触发，base64 编码纯 CPU；slow-op ≥5ms warn）。
                    let clsStart = Date()
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(oneLiner, forType: .string)
                    let durMs = elapsedMilliseconds(since: clsStart)
                    if durMs >= 5 { log("[LANSettings] copy oneliner slow", level: .warn, fields: ["durationMs": String(durMs)]) }
                    remoteInstallMessage = "已复制一行命令（\(oneLiner.count) 字符）"
                    remoteInstallSucceeded = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            if let msg = remoteInstallMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(remoteInstallSucceeded ? .green : .red)
            }

            Text("注意：安装命令包含认证 Token，仅在可信网络中使用。卸载需在远程机器手动清理 ~/.vibefocus 和 ~/.claude/settings.json。")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mapCurrentWindow(for label: String) {
        // P-INST-165: 远程绑定映射当前窗口耗时（captureFocusedWindowIdentity 4 AX P-INST-25 + LANHookPreferences.remoteBindings set CFPreferences 写 P-INST-145；设置 UI「映射当前窗口」按钮调用，AX 在副屏可阻塞）。
        let mcwStart = Date()
        defer {
            log("[LANSettings] mapCurrentWindow finished", level: .debug, fields: [
                "label": label,
                "durationMs": String(elapsedMilliseconds(since: mcwStart))
            ])
        }
        guard let identity = WindowManager.shared.captureFocusedWindowIdentity() else {
            return
        }
        var updated = remoteBindings
        updated[label] = identity.windowID
        remoteBindings = updated
        LANHookPreferences.remoteBindings = updated
    }
}
