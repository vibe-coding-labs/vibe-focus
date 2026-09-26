import Foundation
import Csqlite3
@testable import VibeFocusKit

// Tests/Runner/RunnerAuditWindowHotkeyTests.swift — Window 域审计批回归锁。
// 覆盖：windows 表 PK 迁移事务化（旧 (pid,tty) PK 库 → window_id PK 且数据保留；
// 审计实锚：原实现 DROP→RENAME 两条独立 DDL，进程死于中间=丢整表）。
// 二次迁移幂等（已正确 PK 的库重复 init 不再迁移、数据不动）。

extension RunnerHarness {
    func runAuditWindowHotkeyTests() {

        // MARK: A. 旧 PK 库迁移（事务化路径）
        do {
            let path = NSTemporaryDirectory() + "vf-mig-\(UUID().uuidString.prefix(8)).db"
            defer { try? FileManager.default.removeItem(atPath: path) }

            // 手工造旧 schema：PK = (pid, tty)，插一行带 session_id 的数据
            var db: OpaquePointer?
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                check("auditMig: 旧库构造失败（环境）", false)
                return
            }
            // 历史 schema 实锚：宽列齐全、PK=(pid,tty)、window_id 是普通列
            sqlite3_exec(db, """
                CREATE TABLE windows (
                    window_id INTEGER NOT NULL,
                    pid INTEGER NOT NULL,
                    tty TEXT NOT NULL,
                    ax_window_number INTEGER,
                    app_name TEXT,
                    bundle_id TEXT,
                    title TEXT,
                    term_session_id TEXT,
                    iterm_session_id TEXT,
                    kitty_window_id TEXT,
                    wezterm_pane TEXT,
                    env_window_id TEXT,
                    session_id TEXT,
                    cwd TEXT,
                    model TEXT,
                    orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                    target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                    source_space INTEGER,
                    source_display INTEGER,
                    source_yabai_disp INTEGER,
                    source_disp_space INTEGER,
                    target_display INTEGER,
                    toggle_reason TEXT,
                    toggled_at REAL,
                    is_completed INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    PRIMARY KEY (pid, tty)
                );
                INSERT INTO windows VALUES (5001, 1234, 'ttys001', NULL, 'iTerm2', 'com.googlecode.iterm2', 't1', NULL, NULL, NULL, NULL, NULL, 'sess-abc', '/tmp', NULL, 0,0,0,0, 100,0,800,600, 2,1,1,1, 1, 'manual_hotkey', 1.0, 0, 1.0, 1.0, NULL);
                INSERT INTO windows VALUES (5002, 1234, 'ttys002', NULL, 'iTerm2', 'com.googlecode.iterm2', 't2', NULL, NULL, NULL, NULL, NULL, NULL, '/tmp', NULL, 0,0,0,0, 100,0,800,600, 2,1,1,1, 1, 'manual_hotkey', 2.0, 0, 2.0, 2.0, NULL);
                """, nil, nil, nil)
            sqlite3_close(db)

            // 打开即触发迁移（事务化路径）
            _ = WindowStateStore(dbPath: path)

            // 验证：PK 已是 window_id，两行数据仍在，session_id 保留
            // ⚠️连接与语句必须分变量（句柄/语句混用是 C API 经典错误——首批实锤）
            var verifyDB: OpaquePointer?
            var pkOK = false
            var rowCount = -1
            var sessionKept = false
            if sqlite3_open(path, &verifyDB) == SQLITE_OK {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(verifyDB, "PRAGMA table_info('windows');", -1, &stmt, nil) == SQLITE_OK {
                    var pk: [String] = []
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if sqlite3_column_int(stmt, 5) > 0,
                           let name = sqlite3_column_text(stmt, 1) {
                            pk.append(String(cString: name))
                        }
                    }
                    sqlite3_finalize(stmt)
                    pkOK = pk == ["window_id"]
                }
                if sqlite3_prepare_v2(verifyDB, "SELECT COUNT(*), SUM(session_id = 'sess-abc') FROM windows;", -1, &stmt, nil) == SQLITE_OK,
                   sqlite3_step(stmt) == SQLITE_ROW {
                    rowCount = Int(sqlite3_column_int(stmt, 0))
                    sessionKept = sqlite3_column_int(stmt, 1) == 1
                }
                if stmt != nil { sqlite3_finalize(stmt) }
            }
            sqlite3_close(verifyDB)

            check("auditMig: 迁移后 PK=window_id", pkOK)
            check("auditMig: 迁移后数据两行保留", rowCount == 2)
            check("auditMig: session_id 数据保留", sessionKept)

            // 幂等：再开一次（PK 已正确）不迁移不破坏
            _ = WindowStateStore(dbPath: path)
            var stillTwo = -1
            var v2: OpaquePointer?
            if sqlite3_open(path, &v2) == SQLITE_OK,
               sqlite3_prepare_v2(v2, "SELECT COUNT(*) FROM windows;", -1, &v2, nil) == SQLITE_OK,
               sqlite3_step(v2) == SQLITE_ROW {
                stillTwo = Int(sqlite3_column_int(v2, 0))
            }
            if v2 != nil { sqlite3_finalize(v2) }
            sqlite3_close(v2)
            check("auditMig: 幂等重开数据不动", stillTwo == 2)
        }
    }
}
