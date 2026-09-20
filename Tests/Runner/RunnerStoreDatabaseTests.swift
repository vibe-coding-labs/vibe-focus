import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerStoreDatabaseTests.swift — B299：WindowStateStore+Database 域直测。
// 开库/迁移/错误分支全链在临时目录承载（VIBEFOCUS_DB_PATH 环境注入缝 + ShellRunner
// 预置 legacy 库），零触生产 ~/.vibefocus。覆盖：env 路径分支（含父目录自动创建）、
// 垃圾文件库 WAL/schema/prepare 连锁败、写锁 BUSY step 失败、PK 迁移三态
// （成功含 OR IGNORE 去重 / 建表失败 / 拷贝失败回滚）。

extension RunnerHarness {
    func runStoreDatabaseTests() {
        let dir = NSTemporaryDirectory() + "vf-ut-storedb-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // ===== A. VIBEFOCUS_DB_PATH 环境注入缝：dbPath nil 时走 env 分支，父目录自动创建 =====
        do {
            let envPath = dir + "nested/env.db"
            setenv("VIBEFOCUS_DB_PATH", envPath, 1)
            defer { unsetenv("VIBEFOCUS_DB_PATH") }
            let store = WindowStateStore()
            check("storeDB: env 注入路径开库成功（db 连接非 nil）", store.db != nil)
            check("storeDB: env 路径父目录自动创建", FileManager.default.fileExists(atPath: envPath))
        }

        // ===== B. 垃圾文件库：open 懒成功，WAL/schema/save prepare 连锁败（零崩溃）=====
        do {
            let p = dir + "garbage.db"
            try? Data("this is definitely not a sqlite database".utf8).write(to: URL(fileURLWithPath: p))
            let store = WindowStateStore(dbPath: p)
            check("storeDB: 垃圾文件库构造不崩", true)
            check("storeDB: 垃圾库 loadPreference 优雅 nil", store.loadPreference(key: "k") == nil)
            store.savePreference(key: "k", value: "v")
            check("storeDB: 垃圾库 savePreference 走 prepare 失败分支不崩", true)
            check("storeDB: 垃圾库 runSchema 走 schema error 分支不崩", true)
        }

        // ===== C. 写锁 BUSY：第二连接 BEGIN EXCLUSIVE 持锁 → savePreference step 失败分支 =====
        do {
            let p = dir + "busy.db"
            let s1 = WindowStateStore(dbPath: p)
            let s2 = WindowStateStore(dbPath: p)
            s2.runSchema("BEGIN EXCLUSIVE;")
            s1.savePreference(key: "locked", value: "v1")
            check("storeDB: 持锁期间 savePreference step 失败分支不崩", true)
            check("storeDB: 持锁期间读旧值不受影响", s1.loadPreference(key: "locked") == nil)
            s2.runSchema("COMMIT;")
            s1.savePreference(key: "locked", value: "v2")
            check("storeDB: 放锁后写入成功可读", s1.loadPreference(key: "locked") == "v2")
        }

        // ===== D. legacy PK(pid,tty) 迁移成功路：数据平移 + window_id 去重 =====
        do {
            let p = dir + "legacy-ok.db"
            let legacy = """
                CREATE TABLE windows (window_id INTEGER, pid INTEGER NOT NULL,
                    tty TEXT NOT NULL DEFAULT '', ax_window_number INTEGER, app_name TEXT,
                    bundle_id TEXT, title TEXT, term_session_id TEXT, iterm_session_id TEXT,
                    kitty_window_id TEXT, wezterm_pane TEXT, env_window_id TEXT,
                    session_id TEXT, cwd TEXT, model TEXT,
                    orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                    target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                    source_space INTEGER, source_display INTEGER, source_yabai_disp INTEGER,
                    source_disp_space INTEGER, target_display INTEGER, toggle_reason TEXT,
                    toggled_at REAL, is_completed INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL, completed_at REAL,
                    PRIMARY KEY(pid, tty));
                INSERT INTO windows(window_id,pid,tty,session_id,created_at,updated_at,is_completed)
                    VALUES (1,100,'tty1','s1',1,1,0),(1,101,'tty2','s2',1,1,0),(2,102,'tty3','s3',1,1,0);
                """
            _ = ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [p, legacy])
            let store = WindowStateStore(dbPath: p)
            check("storeDB: legacy 库迁移后连接可用", store.db != nil)
            let probe = ShellRunner.run(
                executable: "/usr/bin/sqlite3", arguments: [p, "SELECT count(*) FROM windows;"])
            check("storeDB: 迁移平移 3 行且 window_id=1 去重为 2 行",
                  probe?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
            let pk = ShellRunner.run(
                executable: "/usr/bin/sqlite3",
                arguments: [p, "SELECT name FROM pragma_table_info('windows') WHERE pk=1;"])
            check("storeDB: 迁移后 PK 变为 window_id",
                  pk?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "window_id")
        }

        // ===== E. 拷贝失败回滚：legacy 表缺列 → windows_v2 建成后 DROP，原表原样 =====
        do {
            let p = dir + "legacy-rollback.db"
            let legacy = """
                CREATE TABLE windows (pid INTEGER NOT NULL, tty TEXT NOT NULL DEFAULT '',
                    window_id INTEGER, session_id TEXT, created_at REAL NOT NULL,
                    updated_at REAL NOT NULL, is_completed INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(pid, tty));
                INSERT INTO windows(window_id,pid,tty,session_id,created_at,updated_at,is_completed)
                    VALUES (7,200,'ttyX','sX',1,1,0);
                """
            _ = ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [p, legacy])
            let store = WindowStateStore(dbPath: p)
            check("storeDB: 拷贝失败回滚后连接不悬空", store.db != nil)
            let probe = ShellRunner.run(
                executable: "/usr/bin/sqlite3",
                arguments: [p, "SELECT count(*) FROM (SELECT name FROM sqlite_master WHERE name='windows_v2');"])
            check("storeDB: 回滚后无 windows_v2 残留",
                  probe?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            let rows = ShellRunner.run(
                executable: "/usr/bin/sqlite3", arguments: [p, "SELECT count(*) FROM windows;"])
            check("storeDB: 回滚后原表数据原样", rows?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        }

        // ===== F. 建表失败：windows_v2 已被占用 → 迁移中止，原表 PK 不动 =====
        do {
            let p = dir + "legacy-v2occupied.db"
            let legacy = """
                CREATE TABLE windows (pid INTEGER NOT NULL, tty TEXT NOT NULL DEFAULT '',
                    window_id INTEGER, session_id TEXT, created_at REAL NOT NULL,
                    updated_at REAL NOT NULL, is_completed INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(pid, tty));
                CREATE TABLE windows_v2 (dummy TEXT);
                """
            _ = ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [p, legacy])
            let store = WindowStateStore(dbPath: p)
            check("storeDB: windows_v2 被占用时构造不崩", store.db != nil)
            let pk = ShellRunner.run(
                executable: "/usr/bin/sqlite3",
                arguments: [p, "SELECT count(*) FROM (SELECT name FROM pragma_table_info('windows') WHERE pk=1 AND name='pid');"])
            check("storeDB: 迁移中止后原表 PK 保持 (pid,...) 不动",
                  pk?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        }

        try? FileManager.default.removeItem(atPath: dir)
    }
}
