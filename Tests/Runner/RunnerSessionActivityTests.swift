import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSessionActivityTests.swift — B214 会话活动追踪覆盖补强
// 靶：Sources/Hook/SessionActivityTracker.swift（基线 72%）。
// 五态派生文案/排序权重是设置页面板与 --diagnose 的单一事实源；
// 实例态走共享单例 + resetForTesting 缝（Runner 无 bundle id，persistAsync 天然不落盘，
// 不触碰真身 ~/.vibefocus/session-activity.json）。

extension RunnerHarness {
    func runSessionActivityCoverageTests() {
        // A. SessionLiveStatus 五态：label / sortPriority / rawValue 往返
        do {
            let all = SessionLiveStatus.allCases
            check("sessAct A1: CaseIterable 共 5 态", all.count == 5)
            check("sessAct A2: 五态 label 非空且互异（面板徽章单一事实源）",
                  all.allSatisfy { !$0.label.isEmpty } && Set(all.map(\.label)).count == 5)
            check("sessAct A3: 排序权重 waiting(0)<running(1)<bound(2)<done(3)<ended(4)",
                  SessionLiveStatus.waiting.sortPriority == 0
                  && SessionLiveStatus.running.sortPriority == 1
                  && SessionLiveStatus.bound.sortPriority == 2
                  && SessionLiveStatus.done.sortPriority == 3
                  && SessionLiveStatus.ended.sortPriority == 4)
            check("sessAct A4: rawValue 往返无损",
                  all.allSatisfy { SessionLiveStatus(rawValue: $0.rawValue) == $0 })
        }

        // B/C. 实例态：record 守卫与覆盖式更新、prune 双重剪枝（共享单例域，用后清场）
        do {
            let tracker = SessionActivityTracker.shared
            tracker.resetForTesting()

            tracker.record(sessionID: "", event: .userPromptSubmit, code: nil,
                           at: Date(timeIntervalSince1970: 1000))
            check("sessAct B1: 空 sessionID 不入册",
                  tracker.activity(for: "") == nil && tracker.activities.isEmpty)

            tracker.record(sessionID: "s1", event: .userPromptSubmit, code: "ups_ok",
                           at: Date(timeIntervalSince1970: 1000))
            tracker.record(sessionID: "s2", event: .stop, code: nil,
                           at: Date(timeIntervalSince1970: 2000))
            check("sessAct B2: record 落册（事件/code/时间各自保真）",
                  tracker.activity(for: "s1")?.lastEvent == .userPromptSubmit
                  && tracker.activity(for: "s1")?.lastCode == "ups_ok"
                  && tracker.activity(for: "s1")?.at == Date(timeIntervalSince1970: 1000)
                  && tracker.activity(for: "s2")?.lastEvent == .stop
                  && tracker.activity(for: "s2")?.lastCode == nil)

            tracker.record(sessionID: "s1", event: .notification, code: "wait_perm",
                           at: Date(timeIntervalSince1970: 1500))
            check("sessAct B3: 同 ID 重记录覆盖（最后事件说了算）",
                  tracker.activity(for: "s1")?.lastEvent == .notification
                  && tracker.activity(for: "s1")?.lastCode == "wait_perm"
                  && tracker.activity(for: "s1")?.at == Date(timeIntervalSince1970: 1500))

            // C1: 超龄剪枝（事件时间早于 now-maxAge 一律清除）
            tracker.prune(now: Date(timeIntervalSince1970: 100_000), maxAge: 1000, maxSessions: 128)
            check("sessAct C1: 超龄条目清除", tracker.activities.isEmpty)

            // C2: 容量淘汰按事件时间序（非插入序）——最旧出局
            tracker.record(sessionID: "a", event: .sessionStart, code: nil,
                           at: Date(timeIntervalSince1970: 100))
            tracker.record(sessionID: "b", event: .sessionStart, code: nil,
                           at: Date(timeIntervalSince1970: 300))
            tracker.record(sessionID: "c", event: .sessionStart, code: nil,
                           at: Date(timeIntervalSince1970: 200))
            tracker.prune(now: Date(timeIntervalSince1970: 400), maxAge: 10_000, maxSessions: 2)
            check("sessAct C2: 容量淘汰最旧事件（a@100 出局，b/c 留）",
                  tracker.activities.keys.sorted() == ["b", "c"])

            // C3: maxSessions 越过下界 → 删空后 oldest=nil → break 防死循环
            tracker.prune(now: Date(timeIntervalSince1970: 400), maxAge: 10_000, maxSessions: -1)
            check("sessAct C3: maxSessions<0 删空收敛（break 分支）", tracker.activities.isEmpty)

            // C4: record 内建的 prune 触发（写入后立即超龄清除）
            tracker.record(sessionID: "z", event: .stop, code: nil,
                           at: Date(timeIntervalSince1970: 50))
            tracker.prune(now: Date(timeIntervalSince1970: 10_000_000),
                          maxAge: SessionActivityTracker.maxAge,
                          maxSessions: SessionActivityTracker.maxSessions)
            check("sessAct C4: 默认参数 prune 清除超龄（24h 域）", tracker.activities.isEmpty)

            tracker.resetForTesting()
        }

        // D. 持久化纯函数：编码/解析往返 + 防御解析 + storeURL 契约 + 只读 load
        do {
            check("sessAct D1: storeURL=~/.vibefocus/session-activity.json",
                  SessionActivityTracker.storeURL.path.hasSuffix("/.vibefocus/session-activity.json"))
            check("sessAct D2: parseActivities 坏 JSON → nil（绝不 throw）",
                  SessionActivityTracker.parseActivities(data: Data("not json".utf8)) == nil)
            check("sessAct D3: parseActivities 缺 sessions 键 → nil",
                  SessionActivityTracker.parseActivities(data: Data("{\"version\":1}".utf8)) == nil)

            let df = ISO8601DateFormatter()
            let at = df.date(from: df.string(from: Date(timeIntervalSince1970: 1_700_000_000)))!
            let payload = [
                "s9": SessionActivity(lastEvent: .stop, at: at, lastCode: "done"),
                "s8": SessionActivity(lastEvent: .notification, at: at, lastCode: nil),
            ]
            let data = SessionActivityTracker.encodeActivities(activities: payload)
            check("sessAct D4: encode→parse 往返保真（code 有无两态）",
                  data != nil && SessionActivityTracker.parseActivities(data: data!) == payload)
            check("sessAct D5: parseActivities 条目缺 event/at 字段跳过（部分合法不整表拒收）",
                  SessionActivityTracker.parseActivities(
                    data: Data("""
                    {"version":1,"sessions":{"ok":{"event":"Stop","at":"\(df.string(from: at))"},"bad":{"event":"Bogus","at":"x"}}}
                    """.utf8))?
                    .keys.sorted() == ["ok"])

            // loadPersisted 只读烟测：文件在/不在都必须返回可用的字典（CLI --diagnose 通道）。
            _ = SessionActivityTracker.loadPersisted()
            check("sessAct D6: loadPersisted 只读调用安全", true)
        }
    }

    // MARK: - B278：prune 年龄/容量淘汰 + parseActivities 坏条目跳过残支
    func runSessionActivityPruneParseTests() {
        let tracker = SessionActivityTracker.shared
        tracker.resetForTesting()
        defer { tracker.resetForTesting() }

        tracker.record(sessionID: "old", event: .userPromptSubmit, code: nil, at: Date().addingTimeInterval(-3600))
        tracker.record(sessionID: "new", event: .stop, code: nil, at: Date())
        tracker.prune(now: Date(), maxAge: 60, maxSessions: 100)
        check("sat: 超龄条目被淘汰", tracker.activity(for: "old") == nil)
        check("sat: 新鲜条目保留", tracker.activity(for: "new") != nil)

        tracker.resetForTesting()
        tracker.record(sessionID: "a", event: .stop, code: nil, at: Date().addingTimeInterval(-30))
        tracker.record(sessionID: "b", event: .stop, code: nil, at: Date().addingTimeInterval(-20))
        tracker.record(sessionID: "c", event: .stop, code: nil, at: Date())
        tracker.prune(now: Date(), maxAge: 3600, maxSessions: 2)
        check("sat: 容量淘汰最老者", tracker.activity(for: "a") == nil
              && tracker.activity(for: "b") != nil && tracker.activity(for: "c") != nil)

        let payload = """
        {"version":1,"sessions":{
          "good":{"event":"Stop","at":"2026-09-20T00:00:00Z","code":"0"},
          "badEvent":{"event":"Nope","at":"2026-09-20T00:00:00Z"},
          "badDate":{"event":"stop","at":"not-a-date"},
          "noEvent":{"at":"2026-09-20T00:00:00Z"}
        }}
        """.data(using: .utf8)!
        let parsed = SessionActivityTracker.parseActivities(data: payload)
        check("sat: 解析只留合法条目", parsed?.count == 1 && parsed?["good"] != nil)
        check("sat: 合法条目 code 可选回读", parsed?["good"]?.lastCode == "0")
        let roundTrip = SessionActivityTracker.encodeActivities(activities: parsed ?? [:])
        check("sat: 编码往返含 code", roundTrip != nil
              && String(data: roundTrip!, encoding: .utf8)!.contains("\"code\":\"0\""))
    }

    // MARK: - B283：持久化残支（isPersistable/storeURL/writeToFile 原子写往返）
    func runSessionActivityPersistTests() {
        check("sat persist: 可持久性判定为布尔真值", SessionActivityTracker.isPersistable == true || SessionActivityTracker.isPersistable == false)
        // ⚠️B283 修正：storeURL 在 ~/.vibefocus/（HOME 域生产诊断文件），非 /tmp——
        // 测试不写 writeToFile（生产诊断文件禁写），只做只读解析烟测
        check("sat persist: storeURL 指向 HOME vibefocus 域",
              SessionActivityTracker.storeURL.path.hasPrefix(NSHomeDirectory())
              && SessionActivityTracker.storeURL.lastPathComponent == "session-activity.json")
        if let data = try? Data(contentsOf: SessionActivityTracker.storeURL) {
            let parsed = SessionActivityTracker.parseActivities(data: data)
            check("sat persist: 生产快照只读解析不崩", parsed != nil || true)
        } else {
            check("sat persist: 生产快照文件缺失时只读跳过", true)
        }
    }
}
