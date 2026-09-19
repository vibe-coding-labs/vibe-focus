import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerGeneratorDoctorTailTests.swift — B232：installer 家族纯函数尾巴 +
// Doctor 诊断边支（llvm-cov 0 计数行定向）。全纯/临时 DB：无生产 IO。
// ①HookScriptGenerator 开关联动矩阵（generateHooksDict 四开关决定事件集）+
//   远程 $HOME 路径铁律（B124：Mac 绝对路径在远程静默断链）；
// ②Doctor.runtimeAXFlipLine 两态 + auditNewestAgeSeconds 四路（打开失败/无表/空表/有行）。

extension RunnerHarness {
    func runGeneratorDoctorTailTests() {
        // ===== HookScriptGenerator：开关联动事件矩阵（存-还四开关） =====
        do {
            let keys = [
                ClaudeHookPreferences.triggerOnSessionEndKey,
                ClaudeHookPreferences.autoRestoreOnPromptSubmitKey,
                ClaudeHookPreferences.notifyOnNotificationKey,
            ]
            var saved: [String: Any?] = [:]
            for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
            defer {
                for (k, v) in saved {
                    if let v { UserDefaults.standard.set(v, forKey: k) }
                    else { UserDefaults.standard.removeObject(forKey: k) }
                }
            }
            for k in keys { UserDefaults.standard.set(false, forKey: k) }
            let minimal = ClaudeHookPreferences.generateHooksDict()
            check("genTail: 三开关全关 → 仅 SessionStart+Stop 恒注册",
                  Set(minimal.keys) == Set(["SessionStart", "Stop"]))

            UserDefaults.standard.set(true, forKey: ClaudeHookPreferences.triggerOnSessionEndKey)
            UserDefaults.standard.set(true, forKey: ClaudeHookPreferences.autoRestoreOnPromptSubmitKey)
            UserDefaults.standard.set(true, forKey: ClaudeHookPreferences.notifyOnNotificationKey)
            let full = ClaudeHookPreferences.generateHooksDict()
            check("genTail: 三开关全开 → 五事件全注册",
                  Set(full.keys)
                  == Set(["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit", "Notification"]))

            // JSON 形态：顶层 hooks 包裹 vs 裸字典（B84 合并语义防漂移）
            let settingsJSON = ClaudeHookPreferences.generateHooksJSON()
            let settingsObj = (try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8))) as? [String: Any]
            check("genTail: generateHooksJSON 顶层带 hooks 包裹",
                  settingsObj?["hooks"] is [String: Any])
            let bareJSON = ClaudeHookPreferences.generateHooksDictJSON(scriptPath: "/custom/path.sh")
            let bareObj = (try? JSONSerialization.jsonObject(with: Data(bareJSON.utf8))) as? [String: Any]
            let entries = bareObj?["SessionStart"] as? [[String: Any]]
            let hookList = entries?.first?["hooks"] as? [[String: Any]]
            let command = hookList?.first?["command"] as? String
            check("genTail: 裸字典 JSON 自定义 scriptPath 贯穿 command",
                  command == "bash \"/custom/path.sh\"")
        }

        // ===== 远程 $HOME 铁律（B124 回归锁） =====
        do {
            let entry = ClaudeHookPreferences.makeRemoteHookEntry()
            let hooks = entry["hooks"] as? [[String: Any]]
            let cmd = (hooks?.first?["command"] as? String) ?? ""
            check("genTail: 远程条目用 $HOME 形态路径",
                  cmd.contains("$HOME/.vibefocus/hook-forwarder.sh"))
            check("genTail: 远程条目不含 Mac 绝对家目录",
                  !cmd.contains(NSHomeDirectory()))
        }

        // ===== Codex hooks JSON：恒注册事件集（B207 单一事实源） =====
        do {
            let json = ClaudeHookPreferences.generateCodexHooksDictJSON()
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let events = Set(obj?.keys.map { $0 } ?? [])
            check("genTail: codex 事件集含 SessionStart/Stop（服务端门控恒注册）",
                  events.contains("SessionStart") && events.contains("Stop"))
        }

        // ===== Doctor.runtimeAXFlipLine 两态 =====
        do {
            check("docTail: 翻转计数 0 → nil",
                  Doctor.runtimeAXFlipLine(count: 0, direction: nil, lastAt: 0) == nil)
            let line = Doctor.runtimeAXFlipLine(count: 3, direction: "false→true",
                                                lastAt: 1_700_000_000)
            check("docTail: 有翻转 → 行含次数与方向",
                  line?.contains("3 次") == true && line?.contains("false→true") == true)
        }

        // ===== Doctor.auditNewestAgeSeconds 四路（临时 DB 注入） =====
        do {
            let dir = "/tmp/vibefocus-doctail-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            // 路 1：文件不存在 → 打开只读失败 nil
            check("docTail: 审计库不存在 → nil",
                  Doctor.auditNewestAgeSeconds(dbPath: dir + "/missing.db") == nil)

            // 路 2：库存在但无审计表 → prepare 失败 nil
            let emptyPath = dir + "/empty.db"
            var db: OpaquePointer?
            sqlite3_open(emptyPath, &db)
            sqlite3_exec(db, "CREATE TABLE t(x);", nil, nil, nil)
            sqlite3_close(db)
            check("docTail: 无审计表 → nil",
                  Doctor.auditNewestAgeSeconds(dbPath: emptyPath) == nil)

            // 路 3+4：有表有行 → 正年龄；空表 MAX=NULL → nil
            let dbPath = dir + "/audit.db"
            sqlite3_open(dbPath, &db)
            sqlite3_exec(db, """
                CREATE TABLE window_audit_log (id INTEGER PRIMARY KEY, created_at REAL);
                INSERT INTO window_audit_log (created_at) VALUES (1700000000.0);
                """, nil, nil, nil)
            sqlite3_close(db)
            let age = Doctor.auditNewestAgeSeconds(dbPath: dbPath,
                                                   now: Date(timeIntervalSince1970: 1_700_000_100))
            check("docTail: 有行 → 年龄=now-MAX(created_at)",
                  age == 100.0)

            let nullPath = dir + "/nulltable.db"
            sqlite3_open(nullPath, &db)
            sqlite3_exec(db, "CREATE TABLE window_audit_log (id INTEGER PRIMARY KEY, created_at REAL);", nil, nil, nil)
            sqlite3_close(db)
            check("docTail: 空表 MAX=NULL → nil",
                  Doctor.auditNewestAgeSeconds(dbPath: nullPath) == nil)
        }
    }
}
