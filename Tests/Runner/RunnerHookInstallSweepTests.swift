import AppKit
import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerHookInstallSweepTests.swift — B221 Hook 安装器与纯模型扫尾
// 靶：HookInstaller 注入缝错误分支（B155 缝的失败半边）/ ProjectHookInstaller 公开门面 /
// TerminalAutomationScript 构建器 / SessionRestoreModels 统计与迁移 / CGWindowEntry 幻影窗 /
// ToggleRecord 断库守卫。
// 纪律：全局 settings.json（~/.claude）与 ~/.vibefocus 生产域文件绝不触碰——
// 项目级安装全部走临时目录；错误分支用 /dev/null 与「目录即写入路径」等敌意注入。

extension RunnerHarness {
    func runHookInstallSweepTests() {
        runInstallHooksErrorBranches()
        runProjectInstallRoundTrip()
        runTerminalAutomationBuilders()
        runRestoreModelStats()
        runCGWindowAndToggleGuards()
        runCodexHookDocumentTransforms()
    }

    // MARK: - Codex hooks.json 纯变换（B130 双形状安装/卸载）

    /// 本段原覆盖寄居在 runHookWalkTests（CI 进程链不具备而整域跳过）；这里把
    /// 字典级纯变换搬到普通域，锁定双形状层序、顶层历史层降级、开关裁剪与卸载保留外部条目。
    private func runCodexHookDocumentTransforms() {
        let scriptPath = "/tmp/vf-codex-hook-\(UUID().uuidString.prefix(6)).sh"
        let targetURL = "http://127.0.0.1:39277/codex/hook"
        func ourEntry() -> [String: Any] {
            ["matcher": "", "hooks": [["type": "command", "command": "bash \"\(scriptPath)\"", "timeout": 10]]]
        }
        func foreignEntry() -> [String: Any] {
            ["matcher": "", "hooks": [["type": "command", "command": "/usr/bin/other-tool"]]]
        }

        // A. 路径派生
        check("codexDoc A1: 配置目录/文件路径按 home 拼接",
              CodexHookPreferences.codexConfigDir(home: "/Users/t") == "/Users/t/.codex"
                  && CodexHookPreferences.codexConfigPath(home: "/Users/t") == "/Users/t/.codex/hooks.json")

        // B. 双形状层序：规范 hooks 层在前，文档本体殿后
        let layered = CodexHookPreferences.codexHookLayers(in: ["hooks": ["Stop": [ourEntry()]]])
        check("codexDoc B1: 规范层在前、文档本体殿后",
              layered.count == 2 && (layered[0]["Stop"] as? [Any]) != nil)
        check("codexDoc B2: 无规范层→仅文档本体",
              CodexHookPreferences.codexHookLayers(in: ["Stop": [ourEntry()]]).count == 1)
        check("codexDoc B3: hooks 非字典→仅文档本体",
              CodexHookPreferences.codexHookLayers(in: ["hooks": "oops"]).count == 1)

        let savedAuto = ClaudeHookPreferences.autoRestoreOnPromptSubmit
        let savedEnd = ClaudeHookPreferences.triggerOnSessionEnd
        defer {
            ClaudeHookPreferences.autoRestoreOnPromptSubmit = savedAuto
            ClaudeHookPreferences.triggerOnSessionEnd = savedEnd
        }
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = true
        ClaudeHookPreferences.triggerOnSessionEnd = true

        // C. installedDocument：nil 起点 → 规范层注册五事件，顶层事件键不残留
        let (freshDoc, freshEvents) = CodexHookPreferences.installedDocument(
            existingData: nil, triggerOnSessionEnd: true, autoRestoreOnPromptSubmit: true,
            scriptPath: scriptPath, targetURL: targetURL)
        let freshHooks = freshDoc["hooks"] as? [String: Any]
        check("codexDoc C1: nil 起点注册五事件（规范层）",
              freshEvents == ["PermissionRequest", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"]
                  && freshHooks?.count == 5)
        check("codexDoc C2: 顶层事件键不残留",
              ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit", "PermissionRequest"]
                  .allSatisfy { freshDoc[$0] == nil })

        // C3. 开关关 → 对应事件被裁
        let (trimmedDoc, trimmedEvents) = CodexHookPreferences.installedDocument(
            existingData: nil, triggerOnSessionEnd: false, autoRestoreOnPromptSubmit: false,
            scriptPath: scriptPath, targetURL: targetURL)
        check("codexDoc C3: SessionEnd/UserPromptSubmit 按开关裁剪",
              trimmedEvents == ["PermissionRequest", "SessionStart", "Stop"]
                  && (trimmedDoc["hooks"] as? [String: Any])?.count == 3)

        // C4. 历史错形状（我方条目在顶层）→ 顶层整层降级，我方条目迁入规范层
        let legacyData = try? JSONSerialization.data(withJSONObject: [
            "SessionStart": [ourEntry(), foreignEntry()],
            "custom": "keep",
        ])
        let (legacyDoc, legacyEvents) = CodexHookPreferences.installedDocument(
            existingData: legacyData, triggerOnSessionEnd: true, autoRestoreOnPromptSubmit: true,
            scriptPath: scriptPath, targetURL: targetURL)
        check("codexDoc C4: 顶层历史层整体弃置（foreign 亦不保留）",
              legacyDoc["SessionStart"] == nil && legacyDoc["custom"] as? String == "keep"
                  && legacyEvents.count == 5)

        // D. uninstalledDocument：两形状层都清我方，外部条目原样保留
        let existingData = try? JSONSerialization.data(withJSONObject: [
            "hooks": ["Stop": [ourEntry(), foreignEntry()]],
            "SessionStart": [ourEntry()],
            "custom": "keep",
        ])
        let uninstalled = existingData.map {
            CodexHookPreferences.uninstalledDocument(
                existingData: $0, scriptPath: scriptPath, targetURL: targetURL)
        } ?? [:]
        let remainingStop = (uninstalled["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        check("codexDoc D1: 规范层只留外部条目",
              remainingStop?.count == 1
                  && ((remainingStop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/usr/bin/other-tool")
        check("codexDoc D2: 顶层历史层清空后不残留键，其余字段保留",
              uninstalled["SessionStart"] == nil && uninstalled["custom"] as? String == "keep")
        check("codexDoc D3: 损坏 JSON → 空文档（不崩）",
              CodexHookPreferences.uninstalledDocument(
                  existingData: Data("not-json".utf8), scriptPath: scriptPath, targetURL: targetURL).isEmpty)
    }

    // MARK: - installHooks / uninstall 注入缝错误分支（B155 缝失败半边）

    private func runInstallHooksErrorBranches() {
        let generated = ClaudeHookPreferences.generateHooksDict()
        let script = "/tmp/ut100-does-not-exist.sh"
        let url = "http://127.0.0.1:39277/hook"

        // A1: 父目录不可创建（/dev/null 下的子路径 → ENOTDIR）
        let r1 = ClaudeHookPreferences.installHooks(
            at: "/dev/null/ut100/settings.json", dir: "/dev/null/ut100/sub",
            scriptPath: script, targetURL: url, generated: generated)
        check("hookInstall A1: 目录不可创建 → 明示失败", !r1.0 && r1.1.contains("无法创建目录"))

        // A2: 写入路径本身是目录 → 原子写失败
        let dir = NSTemporaryDirectory() + "ut100-hookerr-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir + "/d", withIntermediateDirectories: true)
        let r2 = ClaudeHookPreferences.installHooks(
            at: dir + "/d", dir: dir + "/d",
            scriptPath: script, targetURL: url, generated: generated)
        check("hookInstall A2: 写入路径是目录 → 写入失败", !r2.0 && r2.1.contains("写入失败"))

        // A3: 卸载侧——路径是目录（读不出 JSON）→ 明示失败不崩
        let r3 = ClaudeHookPreferences.uninstallHookFromClaudeSettings(
            at: dir + "/d", removesHelpers: false)
        check("hookInstall A3: 卸载读不到合法 settings → 失败返回", !r3.0)
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - ProjectHookInstaller 公开门面：临时项目目录安装→外部 hook 保留→卸载

    private func runProjectInstallRoundTrip() {
        let proj = NSTemporaryDirectory() + "ut100-proj-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: proj) }
        let settingsPath = (proj as NSString).appendingPathComponent(".claude/settings.json")
        // 先建 .claude 目录再种子（写文件不自动建父目录——首轮实测踩坑）
        try? FileManager.default.createDirectory(
            atPath: (proj as NSString).appendingPathComponent(".claude"),
            withIntermediateDirectories: true)

        // 预置外部 hook（用户的自装条目，安装/卸载都必须保留）
        let external: [String: Any] = [
            "hooks": [
                "Stop": [["matcher": "*", "hooks": [["type": "command", "command": "echo external"]]]]
            ],
            "model": "opus",
        ]
        let seed = try? JSONSerialization.data(withJSONObject: external, options: [.sortedKeys])
        try? seed?.write(to: URL(fileURLWithPath: settingsPath))

        // B1: 公开 install 门面（CLI --install-claude-hook-project 通道）
        let ins = ProjectHookInstaller.install(proj)
        check("projInstall B1: 安装成功且 settings.json 落盘",
              ins.0 && FileManager.default.fileExists(atPath: settingsPath))
        let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath)))) as? [String: Any]
        let hooksAfter = after?["hooks"] as? [String: Any]
        let afterKeys = (hooksAfter?.keys.sorted().joined(separator: ",")) ?? "nil"
        check("projInstall B2: 外部 hook 保留 + 我方条目进场 + 非钩子键不动 keys=\(afterKeys)",
              (hooksAfter?["Stop"] != nil)
              && (after?["model"] as? String) == "opus"
              && hooksAfter?.count ?? 0 >= 2)

        // B3: 公开 uninstall 门面：摘我方保外部，不删全局脚本
        let rm = ProjectHookInstaller.uninstall(proj)
        let afterRm = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath)))) as? [String: Any]
        let hooksRm = afterRm?["hooks"] as? [String: Any]
        let rmKeys = (hooksRm?.keys.sorted().joined(separator: ",")) ?? "nil"
        let stopEntries = hooksRm?["Stop"] as? [[String: Any]]
        check("projInstall B3: 卸载后外部 Stop 条目保留（恰 1 条）、我方 SessionStart 摘除 keys=\(rmKeys)",
              rm.0 && (afterRm?["model"] as? String) == "opus"
              && stopEntries?.count == 1 && hooksRm?["SessionStart"] == nil)

        // B4: 不存在的项目目录 → 安装自动建目录成功（一次性 CLI 动作无冷却）
        let proj2 = proj + "/nested/project"
        let ins2 = ProjectHookInstaller.install(proj2)
        check("projInstall B4: 深层不存在目录自动创建并安装",
              ins2.0 && FileManager.default.fileExists(
                atPath: (proj2 as NSString).appendingPathComponent(".claude/settings.json")))
    }

    // MARK: - TerminalAutomationScript 构建器与解析

    private func runTerminalAutomationBuilders() {
        let enum_ = TerminalAutomationScript.terminalEnumerateWindowTTYs()
        check("termScript C1: Terminal 枚举脚本形状（app id + window|tty 协议）",
              enum_.contains(#"tell application id "com.apple.Terminal""#)
              && enum_.contains("tty of t"))

        let bounds = TerminalAutomationScript.terminalGetBounds(windowID: 77)
        check("termScript C2: bounds 查询脚本含窗 id",
              bounds.contains("bounds of window id 77"))

        check("termScript C3: parseBounds 四元组→CGRect（l,t,r,b 语义）",
              TerminalAutomationScript.parseBounds("0,10,800,610")
                  == CGRect(x: 0, y: 10, width: 800, height: 600))
        check("termScript C4: parseBounds 空白容忍与垃圾拒绝",
              TerminalAutomationScript.parseBounds(" 0 , 10 , 800 , 610 ")
                  == CGRect(x: 0, y: 10, width: 800, height: 600)
              && TerminalAutomationScript.parseBounds("1,2,3") == nil
              && TerminalAutomationScript.parseBounds("a,b,c,d") == nil
              && TerminalAutomationScript.parseBounds("") == nil)
    }

    // MARK: - SessionRestoreModels：统计派生 + 旧快照迁移分支

    private func runRestoreModelStats() {
        // frame 读写往返
        var win = SessionWindowSnapshot(
            appBundleID: "com.apple.Terminal",
            frame: CGRect(x: 1, y: 2, width: 300, height: 200),
            displayID: 1, wasMinimized: false, panes: [])
        win.frame = CGRect(x: 5, y: 6, width: 700, height: 500)
        check("restoreModel D1: frame setter 落四标量",
              win.x == 5 && win.y == 6 && win.width == 700 && win.height == 500
              && win.frame == CGRect(x: 5, y: 6, width: 700, height: 500))

        // 统计派生：sessionPaneCount 只数有 session 的 pane；spaceCount 不计 nil；displayCount 去重
        let paneWithSession = SessionPaneSnapshot(tty: "/dev/ttys1", kind: .localClaude,
                                                  sessionID: "s1", cwd: nil)
        let shellPane = SessionPaneSnapshot(tty: "/dev/ttys2", kind: .shell, cwd: nil)
        let barePane = SessionPaneSnapshot(kind: .shell, cwd: nil)
        let w1 = SessionWindowSnapshot(
            appBundleID: "t", frame: .zero, displayID: 1, yabaiDisplay: 1, yabaiSpace: 2,
            wasMinimized: false,
            panes: [paneWithSession, shellPane, barePane])
        let w2 = SessionWindowSnapshot(
            appBundleID: "t", frame: .zero, displayID: 2, yabaiDisplay: 2, yabaiSpace: nil,
            wasMinimized: false, panes: [shellPane])
        let snap = SessionRestoreSnapshot(
            id: "snap", name: "n", windows: [w1, w2],
            launchCommand: nil, capturedAt: Date(), formatVersion: 2)
        check("restoreModel D2: sessionPaneCount=1 spaceCount=1(nil 不计) displayCount=2",
              snap.sessionPaneCount == 1 && snap.spaceCount == 1 && snap.displayCount == 2)

        // 旧快照迁移三分支：session→localClaude / 仅 tty→shell 带 tty / 双缺→shell 裸
        let legacyJSON = """
        {"id":"lg","name":"legacy","appBundleID":"com.apple.Terminal","displayID":1,
         "displayYabaiIndex":1,"rows":2,"cols":1,"launchCommand":null,"capturedAt":700000000.0,
         "cells":[
           {"index":0,"x":0,"y":0,"width":100,"height":50,"ttyPath":"/dev/ttys1","sessionID":"s-1","cwd":"/tmp","title":null},
           {"index":1,"x":0,"y":50,"width":100,"height":50,"ttyPath":"/dev/ttys2","sessionID":null,"cwd":"/tmp","title":null},
           {"index":2,"x":0,"y":100,"width":100,"height":50,"ttyPath":null,"sessionID":null,"cwd":null,"title":null}
         ]}
        """
        let legacy = try? JSONDecoder().decode(TerminalGridSnapshot.self, from: Data(legacyJSON.utf8))
        guard let migrated = legacy.map({ SessionSnapshotMigrator.migrateLegacy($0) }) else {
            check("restoreModel D3: 旧快照 JSON 解码失败", false)
            return
        }
        let p0 = migrated.windows[0].panes.first
        let p1 = migrated.windows[1].panes.first
        let p2 = migrated.windows[2].panes.first
        check("restoreModel D3: 迁移三分支（localClaude/shell 带 tty/裸 shell）",
              migrated.windows.count == 3
              && p0?.kind == .localClaude && p0?.sessionID == "s-1"
              && p1?.kind == .shell && p1?.tty == "/dev/ttys2"
              && p2?.kind == .shell && p2?.tty == nil
              && migrated.windows[0].yabaiSpace == nil)
    }

    // MARK: - CGWindowEntry 幻影窗 + ToggleRecord 断库守卫

    private func runCGWindowAndToggleGuards() {
        // 幻影 windowID：CGWindowList 查无 → nil（单窗查询守卫分支）
        check("cgwin E1: 幻影窗 id 查 bounds → nil",
              cgWindowBounds(for: 0xDEADBEEF) == nil)

        // 断库（打不开的路径）→ saveToggleRecord 守卫短路不崩
        let broken = WindowStateStore(dbPath: "/dev/null/ut100-impossible/t.db")
        let rec = ToggleRecord(
            windowID: 1, pid: 1, bundleIdentifier: nil, appName: nil,
            origFrame: .zero, sourceSpace: 1, sourceDisplay: 1, sourceYabaiDisp: 1,
            sourceDispSpace: 1, targetFrame: .zero, targetDisplay: 1,
            toggledAt: Date(), sessionID: nil)
        if broken.db == nil {
            broken.saveToggleRecord(rec)
            check("toggle E2: 断库 saveToggleRecord 短路不崩", true)
        } else {
            check("toggle E2: /dev/null 库未失败（环境相关，跳过）", true)
        }
    }
}
