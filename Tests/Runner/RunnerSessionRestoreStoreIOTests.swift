import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionRestoreStoreIOTests.swift — B216：SessionRestoreStore 实例 IO
// 直测（此前仅 merge() 纯函数有覆盖，upsert/remove/latest/v2 版本过滤/legacy 双库删除 11% 覆盖）。
// 注入缝 init(store:) 定向隔离 DB，偏好键真身读写走 WindowStateStore preference 表。

@MainActor
extension RunnerHarness {
    func runSessionRestoreStoreIOTests() {
        do {
            let dir = "/tmp/vibefocus-srs-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = WindowStateStore(dbPath: dir + "/srs.db")
            let sut = SessionRestoreStore(store: store)

            // ===== 空库起点 =====
            check("srsIO: 空库 snapshots 为空", sut.snapshots().isEmpty)
            check("srsIO: 空库 latest 为 nil", sut.latest() == nil)

            // ===== upsert 新增 + 同 id 替换 + capturedAt 排序 =====
            let older = SessionRestoreSnapshot(id: "s1", name: "旧", windows: [], launchCommand: nil,
                                               capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let newer = SessionRestoreSnapshot(id: "s2", name: "新", windows: [], launchCommand: "claude",
                                               capturedAt: Date(timeIntervalSince1970: 1_700_000_100))
            sut.upsert(older)
            sut.upsert(newer)
            check("srsIO: upsert 两条按 capturedAt 升序",
                  sut.snapshots().map(\.id) == ["s1", "s2"])
            check("srsIO: latest 取最新", sut.latest()?.id == "s2")
            let replaced = SessionRestoreSnapshot(id: "s1", name: "旧改名", windows: [], launchCommand: nil,
                                                  capturedAt: Date(timeIntervalSince1970: 1_700_000_050))
            sut.upsert(replaced)
            check("srsIO: 同 id upsert 替换不追加",
                  sut.snapshots().map(\.name) == ["旧改名", "新"] && sut.snapshots().count == 2)

            // ===== v2 版本过滤：异版本快照读不出（解码护栏） =====
            let stale = SessionRestoreSnapshot(id: "s3", name: "异版本", windows: [], launchCommand: nil,
                                               formatVersion: 99)
            store.savePreference(key: "sessionRestoreSnapshotsV2",
                                 value: String(data: try! JSONEncoder().encode([stale, replaced, newer]),
                                               encoding: .utf8)!)
            check("srsIO: formatVersion≠2 的行被护栏滤除",
                  sut.snapshots().map(\.id) == ["s1", "s2"])

            // ===== legacy 迁移视图：v2 缺席时 legacy 顶上；同 id v2 优先 =====
            let legacy = TerminalGridSnapshot(
                id: "leg-1", name: "旧格子", appBundleID: "com.apple.Terminal",
                displayID: 1, displayYabaiIndex: 1, rows: 1, cols: 1,
                cells: [TerminalGridCellSnapshot(index: 0, x: 0, y: 0, width: 400, height: 300,
                                                 ttyPath: "/dev/ttys001", sessionID: "sid", cwd: "/a", title: nil)],
                launchCommand: nil, capturedAt: Date(timeIntervalSince1970: 1_700_000_200))
            store.savePreference(key: "terminalGridSnapshots",
                                 value: String(data: try! JSONEncoder().encode([legacy]),
                                               encoding: .utf8)!)
            check("srsIO: legacy 经迁移视图出现在列表尾",
                  sut.snapshots().map(\.id) == ["s1", "s2", "leg-1"]
                  && sut.snapshots()[2].windows.count == 1
                  && sut.snapshots()[2].windows[0].panes[0].kind == .localClaude)
            // 同 id 双库并存 → v2 优先
            let v2Shadow = SessionRestoreSnapshot(id: "leg-1", name: "v2 同名", windows: [], launchCommand: nil,
                                                  capturedAt: Date(timeIntervalSince1970: 1_700_000_300))
            sut.upsert(v2Shadow)
            check("srsIO: 同 id v2 优先 legacy 隐身",
                  sut.snapshots().filter { $0.id == "leg-1" }.count == 1
                  && sut.snapshots().first { $0.id == "leg-1" }?.name == "v2 同名")

            // ===== remove：v2 + legacy 双库同清 =====
            sut.remove(id: "leg-1")
            check("srsIO: remove 后 v2/legacy 双库均无此 id",
                  sut.snapshots().filter { $0.id == "leg-1" }.isEmpty)
            let legacyAfter = store.loadPreference(key: "terminalGridSnapshots") ?? "[]"
            check("srsIO: legacy 库同 id 行被物理清掉", !legacyAfter.contains("leg-1"))

            // ===== remove 只删目标 id =====
            sut.remove(id: "s1")
            check("srsIO: remove 不伤及他人", sut.snapshots().map(\.id) == ["s2"])

            // ===== remove 后 latest 跟随 =====
            check("srsIO: 删完 latest 落到剩余最新", sut.latest()?.id == "s2")
        }
    }
}
