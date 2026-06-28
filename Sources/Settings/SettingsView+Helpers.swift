import AppKit
import SwiftUI
import Foundation

extension SettingsView {

    func refreshInstallations() {
        guard !isCheckingInstallations else { return }
        isCheckingInstallations = true
        let bundleID = bundleIdentifier
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let paths = findAppBundlePaths(bundleIdentifier: bundleID)
            DispatchQueue.main.async {
                self.duplicateAppPaths = paths
                self.isCheckingInstallations = false
                logOperationDuration(
                    "[Settings] refresh installations finished",
                    startedAt: startedAt,
                    warnThresholdMs: 250,
                    fields: [
                        "bundleID": bundleID,
                        "foundCount": String(paths.count)
                    ]
                )
            }
        }
    }

    func showDuplicateInFinder(path: String) {
        // P-INST-212: Finder 定位耗时（NSWorkspace.shared.activateFileViewerSelecting LaunchServices 跨进程激活 Finder 选中文件；设置面板用户手动触发；slow-op ≥50ms warn）。
        let sdfStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sdfStart)
            if durMs >= 50 { log("[SettingsView] showDuplicateInFinder slow", level: .warn, fields: ["path": path, "durationMs": String(durMs)]) }
        }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func moveDuplicateToTrash(path: String) {
        let alert = NSAlert()
        alert.messageText = "确认删除"
        alert.informativeText = "确定要将以下应用移到废纸篓吗？\n\n\(path)\n\n此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        do {
            // P-INST-96: 单副本删除 trashItem + refreshInstallations 耗时（FileManager.trashItem 文件操作移到废纸篓 + refreshInstallations 重新扫描安装列表；设置面板用户 runModal 确认后执行，交互等待时间不计入）。
            let mdtStart = Date()
            let url = URL(fileURLWithPath: path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            refreshInstallations()
            log("[SettingsView] moveDuplicateToTrash trashItem finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: mdtStart))
            ])
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "删除失败"
            errorAlert.informativeText = "无法移到废纸篓：\(error.localizedDescription)"
            errorAlert.alertStyle = .critical
            errorAlert.addButton(withTitle: "确定")
            errorAlert.runModal()
        }
    }

    func moveAllDuplicatesToTrash() {
        let pathsToDelete = otherInstallations
        guard !pathsToDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "确认批量删除"
        alert.informativeText = "确定要将以下 \(pathsToDelete.count) 个副本全部移到废纸篓吗？\n\n此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "全部移到废纸篓")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        // P-INST-97: 批量删除副本 trashItem 循环 + refreshInstallations 耗时（N 次 FileManager.trashItem 文件操作 + refreshInstallations 重新扫描安装列表；设置面板用户 runModal 确认后执行，交互等待时间不计入）。
        let madStart = Date()
        var failedPaths: [String] = []
        for path in pathsToDelete {
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failedPaths.append(path)
            }
        }

        refreshInstallations()
        log("[SettingsView] moveAllDuplicatesToTrash batch finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: madStart)),
            "count": String(pathsToDelete.count)
        ])
        if !failedPaths.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "部分删除失败"
            errorAlert.informativeText = "以下 \(failedPaths.count) 个副本未能删除：\n\n\(failedPaths.joined(separator: "\n"))"
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "确定")
            errorAlert.runModal()
        }
    }

    // MARK: - Claude Hook Test Helpers

    func sendTestHookEvent() {
        // P-INST-251: 测试 hook 事件发送编排耗时（ensureTokenGenerated UserDefaults 写 + sendHookRequest URLSession 发起 SessionStart；设置 UI 测试按钮触发，HTTP 请求异步回调不计入 defer；slow-op ≥50ms warn）。
        let sthStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sthStart)
            if durMs >= 50 { log("[Settings] sendTestHookEvent slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        }
        let port = hookPort
        let testSessionID = "test-\(UUID().uuidString.prefix(8))"
        if hookToken.isEmpty {
            ClaudeHookPreferences.ensureTokenGenerated()
            hookToken = ClaudeHookPreferences.authToken ?? ""
        }
        let token = hookToken.isEmpty ? nil : hookToken

        log(
            "[Settings] sending test SessionStart event",
            fields: [
                "sessionID": testSessionID,
                "port": String(port),
                "hasToken": String(token != nil)
            ]
        )

        Self.sendHookRequest(
            port: port,
            endpoint: ClaudeHookPreferences.endpointPath,
            payload: [
                "event": "SessionStart",
                "session_id": testSessionID,
                "source": "test-ui"
            ],
            token: token
        ) { result in
            switch result {
            case .success:
                let endPort = port
                let endToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    log(
                        "[Settings] sending test SessionEnd event",
                        fields: [
                            "sessionID": testSessionID,
                            "port": String(endPort)
                        ]
                    )
                    Self.sendHookRequest(
                        port: endPort,
                        endpoint: ClaudeHookPreferences.endpointPath,
                        payload: [
                            "event": "SessionEnd",
                            "session_id": testSessionID,
                            "source": "test-ui"
                        ],
                        token: endToken
                    ) { endResult in
                        if case .failure(let endError) = endResult {
                            log(
                                "[Settings] test SessionEnd failed",
                                level: .error,
                                fields: [
                                    "sessionID": testSessionID,
                                    "error": endError.localizedDescription
                                ]
                            )
                        }
                    }
                }
            case .failure(let error):
                log(
                    "[Settings] test SessionStart failed",
                    level: .error,
                    fields: [
                        "sessionID": testSessionID,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    static func sendHookRequest(
        port: Int,
        endpoint: String,
        payload: [String: String],
        token: String?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        // P-INST-92: hook 测试请求网络往返耗时（URL 构造 + JSONSerialization 序列化 + URLSession POST + 等待响应；shrStart 在 completion 闭包入口记 round-trip durationMs；设置面板 sendTestHookEvent 调用，timeout 5s；本地 127.0.0.1 但可阻塞 UI 线程的 async wait）。
        let shrStart = Date()
        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else {
            completion(.failure(NSError(domain: "VibeFocus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-VibeFocus-Token")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            log("[SettingsView] sendHookRequest round-trip", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: shrStart))
            ])
            if let error {
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "VibeFocus", code: -2, userInfo: [NSLocalizedDescriptionKey: "Not HTTP response"])))
                return
            }
            if httpResponse.statusCode >= 400 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
                completion(.failure(NSError(
                    domain: "VibeFocus",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"]
                )))
                return
            }
            completion(.success(data ?? Data()))
        }
        task.resume()
    }
}
