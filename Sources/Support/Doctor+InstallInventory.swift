import AppKit
import Foundation

// MARK: - Doctor · 安装副本盘点域
// 2026-09-10 从 Doctor.swift 按域拆分（纯文件搬移，零行为变更）：副本扫描、
// 运行实例枚举、签名身份判定、盘点排版与判定。与 Journal/AX 取证域分开——
// 它们的数据源与失败模式互不相关。
//
// 历史教训（签名身份）：ad-hoc 签名每次构建 DR 都变，装机即毒化 TCC 授权的元凶；
// 证书签名（Authority=）授权可跨重装存续——判定结果直接进 Doctor 报告。

extension Doctor {

    // MARK: - 数据模型

    struct InstallCopyInfo: Equatable {
        var path: String
        var bundleID: String
        var version: String
        /// 证书名 / "adhoc" / "unsigned" / "?"
        var signature: String
        /// .app.backup-* 改名目录：LaunchServices 不注册，open/点按都不会拉起
        var isBackup: Bool
    }

    struct RunningInstanceInfo: Equatable {
        var pid: Int32
        var bundleID: String?
        var path: String?
    }

    // MARK: - 排版（纯函数）

    /// 副本盘点排版（纯函数）：运行实例、活体安装、备份目录、双版本/多实例判定。
    static func installInventoryLines(
        copies: [InstallCopyInfo],
        running: [RunningInstanceInfo]
    ) -> [String] {
        var lines: [String] = []
        for r in running {
            lines.append("  ▶ 运行中 pid=\(r.pid) bundle=\(r.bundleID ?? "?") exe=\(r.path ?? "?")")
        }
        if running.isEmpty {
            lines.append("  （当前无运行实例）")
        }
        for c in copies where !c.isBackup {
            let liveMark = running.contains { $0.path == c.path } ? "  ← 运行中" : ""
            lines.append("  ● \(c.path)  \(c.bundleID) \(c.version)  签名: \(c.signature)\(liveMark)")
        }
        for c in copies where c.isBackup {
            lines.append("  ○ \(c.path)  （备份目录，LaunchServices 不注册，不会拉起）")
        }
        let liveCount = copies.filter { !$0.isBackup }.count
        switch (liveCount, running.count) {
        case (1, 1):
            lines.append("  ✅ 单份安装、单实例，无双版本。")
        case (1, 0):
            lines.append("  ✅ 单份安装（当前无运行实例）。")
        case (_, 0):
            lines.append("  ⚠️ 检测到 \(liveCount) 份活体安装（疑似双版本）。")
        case (1, _):
            lines.append("  ⚠️ 检测到 \(running.count) 个运行实例（多实例冲突或僵尸）。")
        default:
            lines.append("  ⚠️ 检测到 \(liveCount) 份活体安装 + \(running.count) 个运行实例（疑似双版本/多实例）。")
        }
        return lines
    }

    // MARK: - IO

    /// 扫描两个标准安装位 + 枚举运行实例。历史遗留 bundle id（com.vibefocus.app）
    /// 与现行 id（com.openai.vibe-focus）都认，执行文件路径含 VibeFocus 也兜底认。
    static func gatherInstallInventory() -> (copies: [InstallCopyInfo], running: [RunningInstanceInfo]) {
        let scanDirs = [NSHomeDirectory() + "/Applications", "/Applications"]
        var copies: [InstallCopyInfo] = []
        for dir in scanDirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where name.hasPrefix("VibeFocus") {
                let path = dir + "/" + name
                let infoPlist = path + "/Contents/Info.plist"
                guard FileManager.default.fileExists(atPath: infoPlist),
                      let plist = NSDictionary(contentsOfFile: infoPlist) as? [String: Any] else {
                    continue
                }
                copies.append(InstallCopyInfo(
                    path: path,
                    bundleID: plist["CFBundleIdentifier"] as? String ?? "?",
                    version: plist["CFBundleShortVersionString"] as? String ?? "?",
                    signature: detectSignatureKind(bundlePath: path),
                    isBackup: path.contains(".app.backup-")
                ))
            }
        }
        let knownBundleIDs: Set<String> = ["com.openai.vibe-focus", "com.vibefocus.app"]
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                if let b = app.bundleIdentifier, knownBundleIDs.contains(b) { return true }
                return app.executableURL?.path.contains("VibeFocus") == true
            }
            .map {
                RunningInstanceInfo(
                    pid: $0.processIdentifier,
                    bundleID: $0.bundleIdentifier,
                    path: $0.executableURL?.path
                )
            }
        return (copies, running)
    }

    /// 签名身份：codesign -dv 一发判定——有 Authority= → 证书名（TCC 授权可跨重装
    /// 存续）；Signature=adhoc → adhoc（每次构建 DR 都变，装机即毒化授权的元凶）；
    /// 未签名 → unsigned；解析失败 → "?"。
    static func detectSignatureKind(bundlePath: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=2", bundlePath]
        let pipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return "?"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if let range = text.range(of: "Authority=") {
            let name = text[range.upperBound...].prefix { !$0.isNewline }
            return String(name)
        }
        if text.contains("Signature=adhoc") { return "adhoc" }
        if text.contains("code object is not signed") { return "unsigned" }
        return "?"
    }
}
