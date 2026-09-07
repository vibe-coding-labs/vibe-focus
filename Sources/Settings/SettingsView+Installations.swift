import AppKit
import SwiftUI
import Foundation


import UniformTypeIdentifiers

// 重复安装检测与处置（2026-09-07 B35 从 SettingsView+Helpers 拆分：原文件混装安装检测与 Hook 测试两域）
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
        #if PERF_INSTRUMENT
        let sdfStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: sdfStart)
            if durMs >= 50 { log("[SettingsView] showDuplicateInFinder slow", level: .warn, fields: ["path": path, "durationMs": String(durMs)]) }
        }
        #endif
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
}
