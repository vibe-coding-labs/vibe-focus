import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookWalkTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runHookWalkTests() {
    // MARK: 进程树行走 + 终端注册表（真实实现——B16：walkToTerminalPID 谓词注入直测）

    do {
        // 场景 1：起始 pid 即终端
        let immediate = TerminalRegistry.walkToTerminalPID(
            startPID: 500, parentPID: { _ in nil }, isTerminal: { $0 == 500 })
        check("walk: 起始即终端 (pid=500, depth=1)",
              immediate.pid == 500 && immediate.depth == 1)
        // 场景 2：沿父链上溯两级命中
        let chain: [Int32: Int32] = [900: 800, 800: 700]  // pid → parent
        let walked = TerminalRegistry.walkToTerminalPID(
            startPID: 900,
            parentPID: { chain[$0] },
            isTerminal: { $0 == 700 })
        check("walk: 父链上溯两级命中 (depth=3)",
              walked.pid == 700 && walked.depth == 3)
        // 场景 3：深度上限保护
        let infinite: (Int32) -> Int32? = { $0 - 1 }
        let capped = TerminalRegistry.walkToTerminalPID(
            startPID: 100, parentPID: infinite, isTerminal: { _ in false }, maxDepth: 4)
        check("walk: 深度上限 4 步止步", capped.pid == nil && capped.depth == 4)
        // 场景 4：ppid<=1（launchd）断链
        let launchd = TerminalRegistry.walkToTerminalPID(
            startPID: 50, parentPID: { _ in 1 }, isTerminal: { _ in false })
        check("walk: ppid=1 断链不进 init 进程", launchd.pid == nil)
        // 场景 5：自环防护（父=自身）
        let selfLoop = TerminalRegistry.walkToTerminalPID(
            startPID: 60, parentPID: { _ in 60 }, isTerminal: { _ in false })
        check("walk: 自环防护", selfLoop.pid == nil)
        // 场景 6：maxDepth<1 防御为至少 1 步
        let minDepth = TerminalRegistry.walkToTerminalPID(
            startPID: 70, parentPID: { _ in nil }, isTerminal: { _ in false }, maxDepth: 0)
        check("walk: maxDepth<1 防御为 1 步", minDepth.depth == 1 && minDepth.pid == nil)

        // 终端注册表静态集合
        check("registry: Terminal/iTerm2 bundleID 认可",
              TerminalRegistry.isTerminalBundleID("com.apple.Terminal")
              && TerminalRegistry.isTerminalBundleID("com.googlecode.iterm2"))
        check("registry: 陌生 bundleID 不认可", !TerminalRegistry.isTerminalBundleID("com.example.unknown"))
        check("registry: IDE 识别 VS Code",
              TerminalRegistry.isTerminalOrIDEApp(appName: "Code", bundleIdentifier: "com.microsoft.VSCode"))
    }

    // MARK: Hook 脚本生成器（真实实现——B17：hooks JSON 合法性/事件注册/远程安装脚本不变量）

    do {
        // hooks JSON：可解析 + SessionStart/Stop 恒注册 + 条目结构
        let hooksJSON = ClaudeHookPreferences.generateHooksJSON()
        let obj = (try? JSONSerialization.jsonObject(with: Data(hooksJSON.utf8))) as? [String: Any]
        check("hooksJSON: 合法 JSON 且含 hooks 键", obj?["hooks"] != nil)
        let hooks = obj?["hooks"] as? [String: Any]
        check("hooksJSON: SessionStart 恒注册", hooks?["SessionStart"] != nil)
        check("hooksJSON: Stop 恒注册（remoteOnly 分流在服务端）", hooks?["Stop"] != nil)
        let entry = (hooks?["SessionStart"] as? [[String: Any]])?.first
        let hookList = entry?["hooks"] as? [[String: Any]]
        check("hooksJSON: 条目含 command+timeout=10",
              hookList?.first?["type"] as? String == "command"
              && (hookList?.first?["timeout"] as? Int) == 10
              && (hookList?.first?["command"] as? String)?.contains("bash") == true)

        // 远程安装脚本不变量：host 插值 + machine_label 点号转连字符 + 严格模式
        let remote = ClaudeHookPreferences.generateRemoteInstallScript(host: "192.168.1.83")
        check("remoteScript: shebang + 严格模式", remote.contains("#!/bin/bash") && remote.contains("set -euo pipefail"))
        check("remoteScript: host 插值", remote.contains("192.168.1.83"))
        check("remoteScript: machine_label 点号转连字符", remote.contains("remote-192-168-1-83"))

        // helper 脚本不变量：端口默认值 + 上下文采集环境变量
        let helper = ClaudeHookPreferences.generateHelperScriptContent()
        check("helperScript: 默认端口 39277", helper.contains("39277"))
        check("helperScript: 采集 terminal_ctx 环境变量",
              helper.contains("TERM_SESSION_ID") && helper.contains("CLAUDE_PROJECT_DIR")
              && helper.contains("terminal_ctx"))
    }

    // MARK: yabai 错误分类器（真实实现——B18：六类别 + 优先级 + 大小写不敏感穷尽锁定）

    do {
        check("errClass: 空 stderr → none", YabaiErrorClassifier.classify(stderr: "") == .none)
        check("errClass: SA 缺失特征", YabaiErrorClassifier.classify(stderr: "yabai: error with the scripting-addition") == .scriptingAdditionMissing)
        check("errClass: mission-control 阻断", YabaiErrorClassifier.classify(stderr: "cannot focus space: mission-control is active!") == .missionControlBlocking)
        check("errClass: 无焦点窗口（预期）", YabaiErrorClassifier.classify(stderr: "could not retrieve window details") == .noFocusedWindow)
        // 分类器补锁（B92：YabaiErrorClassifierTests 镜像退役——windowNotFound/兜底/大小写/优先序）
        check("errClass: windowNotFound 与 unrecognized 兜底",
              YabaiErrorClassifier.classify(stderr: "could not locate window") == .windowNotFound
              && YabaiErrorClassifier.classify(stderr: "something odd") == .unrecognized)
        check("errClass: 大小写不敏感 + 多特征命中取表序最前（SA 优先于查询类）",
              YabaiErrorClassifier.classify(stderr: "SCRIPTING-ADDITION NOT LOADED") == .scriptingAdditionMissing
              && YabaiErrorClassifier.classify(stderr: "mission-control .. could not locate window") == .missionControlBlocking)
        check("errClass: 窗口已关闭（预期）", YabaiErrorClassifier.classify(stderr: "could not locate window") == .windowNotFound)
        check("errClass: 未识别非空 → unrecognized", YabaiErrorClassifier.classify(stderr: "segfault somewhere") == .unrecognized)
        check("errClass: 大小写不敏感", YabaiErrorClassifier.classify(stderr: "Scripting-Addition Is Missing") == .scriptingAdditionMissing)
        check("errClass: 多类命中取最前（SA 优先于 MC）",
              YabaiErrorClassifier.classify(stderr: "mission-control blocked; scripting-addition missing") == .scriptingAdditionMissing)
    }

    // MARK: 终端使用量表（真实实现——B23：record 幂等累加/lastAt 单调/半衰排序穷尽锁定）

    do {
        var table = TerminalUsageTable()
        let d0 = Date(timeIntervalSince1970: 1_000_000)
        // record：新条目 / 累加 / lastAt 只前进不后退（实测踩坑的乱序保护）
        table.record(bundleID: "a", at: d0)
        check("usage: 新条目 count=1", table.entries["a"]?.count == 1)
        table.record(bundleID: "a", at: d0.addingTimeInterval(100))
        table.record(bundleID: "a", at: d0.addingTimeInterval(50))
        check("usage: 累加且 lastAt 单调（旧日期不回拖）",
              table.entries["a"]?.count == 3
              && table.entries["a"]?.lastAt == d0.addingTimeInterval(100))

        // ranked：minCount 过滤（噪声=低频条目被滤掉；用新表隔离计数）
        var filtered = TerminalUsageTable()
        filtered.record(bundleID: "hot", at: d0)
        filtered.record(bundleID: "hot", at: d0)
        filtered.record(bundleID: "hot", at: d0)
        filtered.record(bundleID: "noise", at: d0)
        check("usage: minCount 过滤噪声（hot=3 留，noise=1 滤）",
              table.ranked(minCount: 3, now: d0).contains { $0.bundleID == "a" }
              && filtered.ranked(minCount: 3, now: d0).map { $0.bundleID } == ["hot"])

        // 持久化/解码 + 注入式 tracker（B103：TerminalUsageTracker 40% 最薄面补测——
        // Runner 进程 UserDefaults.standard 为独立域，显式清理防污染）
        do {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            var src = TerminalUsageTable()
            src.record(bundleID: "com.apple.Terminal", at: t0)
            src.record(bundleID: "com.apple.Terminal", at: t0)
            let data = src.encoded()
            let back = data.flatMap { TerminalUsageTable.decode($0) }
            check("usageIO: encoded→decode 回环保真", back?.entries["com.apple.Terminal"]?.count == 2)
            check("usageIO: 垃圾字节 → decode nil",
                  TerminalUsageTable.decode(Data("not-json".utf8)) == nil)
            let tracker = TerminalUsageTracker(table: src)
            tracker.seedUsage(bundleID: "com.googlecode.iterm2", count: 5, lastAt: t0)
            check("usageTracker: seedUsage 直写计数与 lastAt",
                  tracker.table.entries["com.googlecode.iterm2"]?.count == 5
                  && tracker.table.entries["com.googlecode.iterm2"]?.lastAt == t0
                  && tracker.table.entries["com.apple.Terminal"]?.count == 2)
            TerminalUsageTracker.saveTable(src)
            let loaded = TerminalUsageTracker.loadTable()
            check("usageIO: saveTable/loadTable 往返一致",
                  loaded.entries["com.apple.Terminal"]?.count == 2)
            UserDefaults.standard.removeObject(forKey: TerminalUsageTable.userDefaultsKey)
        }

        // ranked：半衰衰减——14 天半衰下，60 天前的旧条目权重 ≈ 0.1×，被新条目反超
        var mixed = TerminalUsageTable()
        let now = d0.addingTimeInterval(60 * 24 * 3600)
        mixed.record(bundleID: "old-heavy", at: d0)
        mixed.entries["old-heavy"]?.count = 2
        mixed.entries["old-heavy"]?.lastAt = d0
        mixed.record(bundleID: "new-light", at: now)
        mixed.entries["new-light"]?.count = 1
        let ranked = mixed.ranked(now: now)
        check("usage: 半衰衰减——近期轻用反超陈年重用", ranked.first?.bundleID == "new-light")
        check("usage: ranked 的 count 仍为原始累计（展示用）",
              ranked.first { $0.bundleID == "old-heavy" }?.count == 2)

        // 编解码回环
        let data = mixed.encoded()
        check("usage: encode→decode 回环一致", data != nil && TerminalUsageTable.decode(data!) == mixed)
        check("usage: 坏数据 → nil（loadTable 回退空表）",
              TerminalUsageTable.decode(Data("junk".utf8)) == nil)
    }

    // MARK: Codex 安装状态展示映射（真实实现——B21：三处三元收敛为单一事实源）

    do {
        check("codexStatus: 已安装 pill", SettingsView.CodexInstallPresentation.pillTitle(installed: true) == "已安装")
        check("codexStatus: 未安装 pill", SettingsView.CodexInstallPresentation.pillTitle(installed: false) == "未安装")
        check("codexStatus: 已安装 detail 指向 hooks.json",
              SettingsView.CodexInstallPresentation.detailText(installed: true).contains("hooks.json"))
        check("codexStatus: 未安装 detail", SettingsView.CodexInstallPresentation.detailText(installed: false) == "尚未安装")
        check("codexStatus: tint 成功/警示分派",
              SettingsView.CodexInstallPresentation.pillTintName(installed: true) == "success"
              && SettingsView.CodexInstallPresentation.pillTintName(installed: false) == "warning")
    }

    // MARK: PromptMoveDecision + UPSRateLimiter（真实实现——UPS 搬窗决策链与防循环限流，Batch 14）

    do {
        // A. 守护顺序穷举：每道门 + 前门不满足时才看后门。
        //    （2026-09-10 新增记录门：有 toggle 记录优先回原位——Stop 拉主屏后
        //    提交提示词回原位即本门；窗口已在主屏也照样回，因为记录指向的就是原始位置。）
        check("ups A1: 自动恢复关闭 → autoRestoreDisabled（最优先）",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: false, hasWindowIdentity: false, rateLimited: true,
                                                recentUPSCount: 99, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: true, cooldownRemainingSeconds: 5) == .autoRestoreDisabled)
        check("ups A2: 无窗口身份 → noBinding",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: false, rateLimited: true,
                                                recentUPSCount: 99, maxUPSEvents: 20, hasToggleRecord: false,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: true, cooldownRemainingSeconds: 5) == .noBinding)
        check("ups A3: 限流 → rateLimited(计数/阈值)（有记录也先限流）",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: true,
                                                recentUPSCount: 20, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: false, cooldownRemainingSeconds: 0)
              == .rateLimited(recentCount: 20, maxEvents: 20))
        check("ups A4: 有 toggle 记录 → restoreToOriginal（先于主屏/冷却判定；Stop 拉主屏后提交即回原位）",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: true,
                                                isInCooldown: true, cooldownRemainingSeconds: 5) == .restoreToOriginal)
        check("ups A4b: 有记录且窗口已被手动挪走 → 仍回原位",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: false, cooldownRemainingSeconds: 0) == .restoreToOriginal)
        // B126：记录由用户手动热键创建 = 窗口是用户自己放置的，提交不 Undo 其放置
        //（真机事故：语音输入中窗口被自动恢复甩回副屏，连续三次）
        check("ups A4c: 记录为用户手动放置 → userPlacedSkip（不 Undo 用户放置）",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: true,
                                                isOnMainScreen: true,
                                                isInCooldown: false, cooldownRemainingSeconds: 0) == .userPlacedSkip)
        check("ups A4d: 手动放置记录且窗口被挪走 → 仍 userPlacedSkip",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: true,
                                                recordCreatedByUser: true,
                                                isOnMainScreen: false,
                                                isInCooldown: false, cooldownRemainingSeconds: 0) == .userPlacedSkip)
        check("ups A5: 无记录冷却中 → cooldownActive(剩余秒)",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: false,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: true, cooldownRemainingSeconds: 7) == .cooldownActive(remainingSeconds: 7))
        check("ups A6: 无记录非主屏 → stayOnCurrentScreen（UPS 永不搬窗，拉主屏只归 Stop）",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: false,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: false,
                                                isInCooldown: false, cooldownRemainingSeconds: 0) == .stayOnCurrentScreen)
        check("ups A7: 无记录已在主屏 → alreadyOnMain",
              HookEventHandler.decidePromptMove(autoRestoreEnabled: true, hasWindowIdentity: true, rateLimited: false,
                                                recentUPSCount: 1, maxUPSEvents: 20, hasToggleRecord: false,
                                                recordCreatedByUser: false,
                                                isOnMainScreen: true,
                                                isInCooldown: false, cooldownRemainingSeconds: 0) == .alreadyOnMain)

        // B. 响应映射表：码/状态逐项锁定。
        func code(_ r: (statusCode: Int, response: ClaudeHookResponse)) -> String { r.response.code }
        check("ups B: 八决策响应码唯一且稳定",
              code(HookEventHandler.promptHttpResponse(for: .autoRestoreDisabled, sessionID: "s")) == "auto_restore_disabled"
              && code(HookEventHandler.promptHttpResponse(for: .noBinding, sessionID: "s")) == "no_binding_skip"
              && code(HookEventHandler.promptHttpResponse(for: .rateLimited(recentCount: 20, maxEvents: 20), sessionID: "s")) == "session_rate_limited"
              && code(HookEventHandler.promptHttpResponse(for: .restoreToOriginal, sessionID: "s")) == "restore_to_original"
              && code(HookEventHandler.promptHttpResponse(for: .userPlacedSkip, sessionID: "s")) == "user_placed_skip"
              && code(HookEventHandler.promptHttpResponse(for: .alreadyOnMain, sessionID: "s")) == "already_on_main_screen"
              && code(HookEventHandler.promptHttpResponse(for: .cooldownActive(remainingSeconds: 3), sessionID: "s")) == "cooldown_active"
              && code(HookEventHandler.promptHttpResponse(for: .stayOnCurrentScreen, sessionID: "s")) == "stay_on_current_screen")
        let rr = HookEventHandler.promptHttpResponse(for: .rateLimited(recentCount: 20, maxEvents: 20), sessionID: "s")
        check("ups B: 限流文案含计数与阈值、handled=false、状态码 200",
              rr.statusCode == 200 && rr.response.handled == false
              && rr.response.message == "Session UPS rate limited (20/20 in 10min), skipping move")
        let cr = HookEventHandler.promptHttpResponse(for: .cooldownActive(remainingSeconds: 9), sessionID: "s")
        check("ups B: 冷却文案含剩余秒", cr.response.message == "Auto-restore cooldown active (9s remaining)")

        // B+. 字段级收口（B65）：六决策全部 ok=true/200/sessionID 透传 + 常量分支文案逐字锁定。
        let allDecisions: [HookEventHandler.PromptMoveDecision] = [
            .autoRestoreDisabled, .noBinding, .rateLimited(recentCount: 2, maxEvents: 20),
            .alreadyOnMain, .cooldownActive(remainingSeconds: 4), .stayOnCurrentScreen,
        ]
        check("ups B+: 六决策响应 ok=true、状态码 200、sessionID 逐项透传",
              allDecisions.allSatisfy { d in
                  let r = HookEventHandler.promptHttpResponse(for: d, sessionID: "sess-77")
                  return r.statusCode == 200 && r.response.ok && r.response.sessionID == "sess-77"
              })
        check("ups B+: 常量分支文案逐字锁定",
              HookEventHandler.promptHttpResponse(for: .autoRestoreDisabled, sessionID: "s").response.message == "UserPromptSubmit received, auto restore disabled"
              && HookEventHandler.promptHttpResponse(for: .noBinding, sessionID: "s").response.message == "Could not resolve window identity"
              && HookEventHandler.promptHttpResponse(for: .alreadyOnMain, sessionID: "s").response.message == "Window already on main screen, no action needed"
              && HookEventHandler.promptHttpResponse(for: .stayOnCurrentScreen, sessionID: "s").response.message == "User is interacting on current display; window stays put")


        // D. UPSRateLimiter 滑动窗口（100% 分支）。
        var lim = UPSRateLimiter(windowDuration: 600, maxEvents: 3)
        let t0 = Date(timeIntervalSince1970: 1000)
        var r = lim.registerAndEvaluate(now: t0)
        check("ups D: 空窗口首次注册不限流（0/3）", !r.limited && r.recentCount == 0)
        r = lim.registerAndEvaluate(now: t0.addingTimeInterval(10))
        check("ups D: 窗口内 1/3 仍不限流", !r.limited && r.recentCount == 1)
        r = lim.registerAndEvaluate(now: t0.addingTimeInterval(20))
        check("ups D: 窗口内 2/3 仍不限流", !r.limited && r.recentCount == 2)
        r = lim.registerAndEvaluate(now: t0.addingTimeInterval(30))
        check("ups D: 窗口内存量 3/3 达阈值 → 限流", r.limited && r.recentCount == 3)
        r = lim.registerAndEvaluate(now: t0.addingTimeInterval(40))
        check("ups D: 被限事件同样注册（存量持续 ≥ 阈值，持续限流）", r.limited && r.recentCount == 4)
        // 剪枝：首批事件滑出窗口后存量下降，解除限流。
        r = lim.registerAndEvaluate(now: t0.addingTimeInterval(1000 + 41))
        check("ups D: 窗口滑出后剪枝解除限流（存量 0）", !r.limited && r.recentCount == 0)
        // 剪枝严格边界：恰在 windowDuration 上的事件已过期（< 为存活）。
        var lim2 = UPSRateLimiter(windowDuration: 600, maxEvents: 1)
        _ = lim2.registerAndEvaluate(now: t0)
        let r2 = lim2.registerAndEvaluate(now: t0.addingTimeInterval(600))
        check("ups D: 恰在 600s 边界的旧事件已过期（严格 < 为存活）", !r2.limited && r2.recentCount == 0)
        // 多会话独立。
        var limA = UPSRateLimiter(windowDuration: 600, maxEvents: 1)
        var limB = UPSRateLimiter(windowDuration: 600, maxEvents: 1)
        _ = limA.registerAndEvaluate(now: t0)
        let rb = limB.registerAndEvaluate(now: t0)
        check("ups D: 多会话互不干扰", !rb.limited && rb.recentCount == 0)
    }

    // MARK: HookSettingsComposition（真实实现——settings.json hooks 编排，Batch 15）

    do {
        let URL = "http://127.0.0.1:8787/hook"
        let SCRIPT = "/Users/x/.vibefocus/hook-helper.sh"
        func hook(url: String? = nil, cmd: String? = nil) -> [String: Any] {
            var h: [String: Any] = [:]
            if let url { h["url"] = url }
            if let cmd { h["command"] = cmd }
            return h
        }
        func entry(_ hooks: [[String: Any]]) -> [String: Any] { ["hooks": hooks] }

        // A. 识别判据：url 精确相等 OR command 含脚本路径。
        check("compose A: url 精确命中", HookSettingsComposition.isVibeFocusHook(hook(url: URL), targetURL: URL, scriptPath: SCRIPT))
        check("compose A: command 含路径命中", HookSettingsComposition.isVibeFocusHook(hook(cmd: "sh \(SCRIPT) --x"), targetURL: "http://none:1", scriptPath: SCRIPT))
        check("compose A: 外部条目不命中",
              !HookSettingsComposition.isVibeFocusHook(hook(url: "http://other:9", cmd: "/opt/other.sh"), targetURL: URL, scriptPath: SCRIPT))

        // B. strip：摘我们的、留外部的、无 hooks 数组原样保留。
        let entries = [
            entry([hook(url: URL)]),                       // 我们的
            entry([hook(cmd: "/opt/other.sh")]),           // 外部
            ["matcher": "x"],                              // 无 hooks 数组
        ]
        let stripped = HookSettingsComposition.stripVibeFocusEntries(from: entries, targetURL: URL, scriptPath: SCRIPT)
        check("compose B: 摘我们的留外部（removed=1）", stripped.removed == 1 && stripped.kept.count == 2)

        // C. composeDesiredHooks：键并集 + 外部共存 + 整键删除 bug 防回退。
        // 夹具形状 = 真实 Claude settings：hooks[事件] 是**条目数组**（[[String: Any]]）。
        let existing: [String: Any] = [
            "Stop": [entry([hook(url: URL)]), entry([hook(cmd: "/opt/user-stop.sh")])],  // 我们的 + 外部（分立条目）
            "UserPromptSubmit": [entry([hook(url: URL)])],                                // 仅我们（generated 关闭）→ 全空删键
            "SessionStart": [entry([hook(cmd: "/opt/user-start.sh")])],                   // 仅外部（generated 关闭）→ 键保留
        ]
        let generated: [String: Any] = [
            "Stop": [entry([hook(url: "http://127.0.0.1:9999/hook")])],                   // 新端口条目
        ]
        let composed = HookSettingsComposition.composeDesiredHooks(existing: existing, generated: generated, targetURL: URL, scriptPath: SCRIPT)
        let stopEntries = composed["Stop"] as? [[String: Any]] ?? []
        check("compose C: Stop 键外部条目保留 + 新条目并入（共 2 条目，不整键覆盖）",
              stopEntries.count == 2)
        check("compose C: 仅我们的键被摘除删除（UserPromptSubmit）", composed["UserPromptSubmit"] == nil)
        check("compose C: 仅外部的键保留（SessionStart）", composed["SessionStart"] != nil)

        // D. containsVibeFocusHook：深层命中/畸形跳过/全外布 false。
        let goodHooks: [String: Any] = ["Stop": [entry([hook(cmd: "x\(SCRIPT)y")])]]
        check("compose D: 深层 command 命中", HookSettingsComposition.containsVibeFocusHook(hooks: goodHooks, targetURL: URL, scriptPath: SCRIPT))
        let malformed: [String: Any] = [
            "Stop": "not-an-array",                        // 事件值非数组 → 跳过
            "PreToolUse": ["no-hooks-key": true],          // entry 无 hooks → 跳过
        ]
        check("compose D: 畸形结构跳过不崩返回 false",
              !HookSettingsComposition.containsVibeFocusHook(hooks: malformed, targetURL: URL, scriptPath: SCRIPT))
    }

    // MARK: ToggleTriggerGate（真实实现——热键去重门与 fallback 路由，Batch 17）

    do {
        // A. 去重门：in-flight 最优先 → 双阈值重复 → accept。
        check("triggerGate A1: in-flight 最优先（阈值再小也 skipInFlight）",
              ToggleTriggerGate.dedupDecision(isInFlight: true, sinceLastTrigger: 99, sinceLastCompletion: 99,
                                              dedupInterval: 0.15, cooldownInterval: 0.05) == .skipInFlight)
        check("triggerGate A2: 距上次触发 < 0.15 → skipDuplicate",
              ToggleTriggerGate.dedupDecision(isInFlight: false, sinceLastTrigger: 0.1, sinceLastCompletion: 99,
                                              dedupInterval: 0.15, cooldownInterval: 0.05) == .skipDuplicate)
        check("triggerGate A3: 距上次完成 < 0.05 → skipDuplicate",
              ToggleTriggerGate.dedupDecision(isInFlight: false, sinceLastTrigger: 99, sinceLastCompletion: 0.01,
                                              dedupInterval: 0.15, cooldownInterval: 0.05) == .skipDuplicate)
        check("triggerGate A4: 双阈值都越过 → accept",
              ToggleTriggerGate.dedupDecision(isInFlight: false, sinceLastTrigger: 0.2, sinceLastCompletion: 0.06,
                                              dedupInterval: 0.15, cooldownInterval: 0.05) == .accept)
        check("triggerGate A5: 恰在阈值上（< 语义）→ accept",
              ToggleTriggerGate.dedupDecision(isInFlight: false, sinceLastTrigger: 0.15, sinceLastCompletion: 0.05,
                                              dedupInterval: 0.15, cooldownInterval: 0.05) == .accept)

        // B. fallback 路由优先级矩阵。
        check("triggerGate B: repeat 一票忽略（其余全命中也 ignore）",
              ToggleTriggerGate.fallbackRoute(isARepeat: true, matchesPrimaryHotKey: true,
                                              titleEditorEnabledAndMatched: true, layoutMatch: .leftHalf) == .ignore)
        check("triggerGate B: 主热键优先于 Title/摆位",
              ToggleTriggerGate.fallbackRoute(isARepeat: false, matchesPrimaryHotKey: true,
                                              titleEditorEnabledAndMatched: true, layoutMatch: .leftHalf) == .toggle)
        check("triggerGate B: Title 次优先",
              ToggleTriggerGate.fallbackRoute(isARepeat: false, matchesPrimaryHotKey: false,
                                              titleEditorEnabledAndMatched: true, layoutMatch: .leftHalf) == .titleEditor)
        check("triggerGate B: 摆位第三",
              ToggleTriggerGate.fallbackRoute(isARepeat: false, matchesPrimaryHotKey: false,
                                              titleEditorEnabledAndMatched: false, layoutMatch: .topLeftQuarter) == .layout(.topLeftQuarter))
        check("triggerGate B: 全不命中 → ignore",
              ToggleTriggerGate.fallbackRoute(isARepeat: false, matchesPrimaryHotKey: false,
                                              titleEditorEnabledAndMatched: false, layoutMatch: nil) == .ignore)
    }

    // MARK: CGEventTap 路由（真实实现——tapDisabled 自愈/连发/命中消费，Batch 17）

    do {
        check("cgRoute: timeout 失能 → 自愈（timeout）",
              ToggleTriggerGate.cgEventRoute(type: .tapDisabledByTimeout, isAutorepeat: false, primaryMatch: true, layoutMatch: nil) == .reenableTap(.timeout))
        check("cgRoute: user_input 失能 → 自愈（user_input）",
              ToggleTriggerGate.cgEventRoute(type: .tapDisabledByUserInput, isAutorepeat: false, primaryMatch: false, layoutMatch: nil) == .reenableTap(.userInput))
        check("cgRoute: 非 keyDown（flagsChanged）→ 放行",
              ToggleTriggerGate.cgEventRoute(type: .flagsChanged, isAutorepeat: false, primaryMatch: true, layoutMatch: nil) == .ignore)
        check("cgRoute: 自动连发 → 放行",
              ToggleTriggerGate.cgEventRoute(type: .keyDown, isAutorepeat: true, primaryMatch: true, layoutMatch: nil) == .ignore)
        check("cgRoute: 主热键命中 → 消费（toggle）",
              ToggleTriggerGate.cgEventRoute(type: .keyDown, isAutorepeat: false, primaryMatch: true, layoutMatch: nil) == .toggle)
        check("cgRoute: 主键未中摆位命中 → 消费（layout）",
              ToggleTriggerGate.cgEventRoute(type: .keyDown, isAutorepeat: false, primaryMatch: false, layoutMatch: .leftHalf) == .layout(.leftHalf))
        check("cgRoute: 全未命中 → 原样放行给系统",
              ToggleTriggerGate.cgEventRoute(type: .keyDown, isAutorepeat: false, primaryMatch: false, layoutMatch: nil) == .passThrough)
        check("cgRoute: 开关关闭（layoutMatch=nil）时不消费摆位键",
              ToggleTriggerGate.cgEventRoute(type: .keyDown, isAutorepeat: false, primaryMatch: false, layoutMatch: nil) == .passThrough)
    }

    // MARK: IPS 崩溃报告解析（真实实现——B26：首行头丢弃 + JSON 载荷提取穷尽锁定）

    do {
        let report = "header-line\n{\"exception\":{\"type\":\"SIGTRAP\"},\"pid\":123}"
        let payload = CrashContextRecorder.parseIPSJSONPayload(from: report)
        check("ips: 跳首行提取 JSON 载荷",
              (payload?["pid"] as? Int) == 123
              && (payload?["exception"] as? [String: Any])?["type"] as? String == "SIGTRAP")
        check("ips: 单行输入 → nil", CrashContextRecorder.parseIPSJSONPayload(from: "{\"pid\":1}") == nil)
        check("ips: 非法 JSON → nil",
              CrashContextRecorder.parseIPSJSONPayload(from: "header\nnot-json") == nil)
        let pretty = "header-line\n{\n  \"k\": \"v\"\n}"
        check("ips: 多行 JSON 完整解析",
              (CrashContextRecorder.parseIPSJSONPayload(from: pretty)?["k"] as? String) == "v")
        check("ips: 空输入 → nil", CrashContextRecorder.parseIPSJSONPayload(from: "") == nil)
    }

    // MARK: SessionBind 决策（真实实现——SessionStart 双通道绑定裁决，Batch 19）

    do {
        func ident(_ id: UInt32) -> WindowIdentity {
            WindowIdentity(windowID: id, pid: 100, bundleIdentifier: nil, appName: "App", windowNumber: nil, title: "t")
        }
        // A. remote 通道：解析成功 → bind(.remote)；失败 → remoteBindingFailed。
        if case .bind(let identity, let bindingType) = HookEventHandler.decideSessionBind(
            isRemote: true, machineLabel: "lab-1", localResolved: nil, remoteResolved: ident(7)) {
            check("sessionBind A: remote 成功 → bind(.remote, windowID=7)",
                  identity.windowID == 7 && bindingType == .remote)
        } else {
            check("sessionBind A: remote 成功 → bind(.remote, windowID=7)", false)
        }
        check("sessionBind A: remote 映射缺失 → remoteBindingFailed(label)",
              HookEventHandler.decideSessionBind(isRemote: true, machineLabel: "lab-2",
                                                 localResolved: ident(9), remoteResolved: nil)
              == .remoteBindingFailed(label: "lab-2"))
        check("sessionBind A: remote 未配 label → 失败兜底 'nil'",
              HookEventHandler.decideSessionBind(isRemote: true, machineLabel: nil,
                                                 localResolved: nil, remoteResolved: nil)
              == .remoteBindingFailed(label: "nil"))

        // B. local 通道：成功 → bind(.local)；失败 → terminalContextMatchFailed。
        // 注：不用 == .bind(identity: ident(5), ...)——WindowIdentity 含 capturedAt: Date，
        // 两次构造通常同微秒恰好相等，但负载下跨时钟边界即假失败（2026-09-07 实测偶发）；
        // 与 A 同用 if-case 解构，按 windowID/bindingType 断言。
        if case .bind(let identity, let bindingType) = HookEventHandler.decideSessionBind(
            isRemote: false, machineLabel: "lab-1", localResolved: ident(5), remoteResolved: nil) {
            check("sessionBind B: local 成功 → bind(.local, windowID=5)",
                  identity.windowID == 5 && bindingType == .local)
        } else {
            check("sessionBind B: local 成功 → bind(.local, windowID=5)", false)
        }
        check("sessionBind B: local 匹配失败 → terminalContextMatchFailed",
              HookEventHandler.decideSessionBind(isRemote: false, machineLabel: nil,
                                                 localResolved: nil, remoteResolved: nil)
              == .terminalContextMatchFailed)

        // C. 响应映射：码/状态/handled。
        let okResp = HookEventHandler.sessionBindHttpResponse(
            for: .bind(identity: ident(1), bindingType: .local), sessionID: "s")
        let remoteResp = HookEventHandler.sessionBindHttpResponse(
            for: .bind(identity: ident(1), bindingType: .remote), sessionID: "s")
        check("sessionBind C: 本地成功 → 200 session_bound via TTY/PPID",
              okResp.statusCode == 200 && okResp.response.code == "session_bound"
              && okResp.response.handled == true
              && okResp.response.message.contains("TTY/PPID"))
        check("sessionBind C: 远程成功 → 200 session_bound via remote_label",
              remoteResp.response.message.contains("remote_label"))
        let failResp = HookEventHandler.sessionBindHttpResponse(
            for: .remoteBindingFailed(label: "lab-x"), sessionID: "s")
        check("sessionBind C: remote 失败 → 409 + label 回显",
              failResp.statusCode == 409 && failResp.response.code == "remote_binding_failed"
              && failResp.response.message.contains("lab-x") && failResp.response.handled == false)
        let matchResp = HookEventHandler.sessionBindHttpResponse(
            for: .terminalContextMatchFailed, sessionID: "s")
        check("sessionBind C: 本地匹配失败 → 409 terminal_context_match_failed",
              matchResp.statusCode == 409 && matchResp.response.code == "terminal_context_match_failed")

        // D. 决策表契约违反的诚实上报（B53：fatalError → 500 保守退让，P1 红线——
        // 一次 hook 请求不许击穿整个菜单栏应用）。
        let violateRemote = HookEventHandler.decisionContractViolationResponse(channel: "remote", sessionID: "s")
        let violateLocal = HookEventHandler.decisionContractViolationResponse(channel: "local", sessionID: "s")
        check("sessionBind D: 契约违反 → 500 decision_contract_violation 诚实上报",
              violateRemote.statusCode == 500 && violateRemote.response.ok == false
              && violateRemote.response.code == "decision_contract_violation"
              && violateRemote.response.handled == false)
        check("sessionBind D: 契约违反响应携带通道名与 sessionID 回显",
              violateRemote.response.message.contains("remote")
              && violateLocal.response.message.contains("local")
              && violateRemote.response.sessionID == "s"
              && violateLocal.response.sessionID == "s")
        // Hook token 解析/校验（B91：TokenValidationLogicTests 镜像退役转真身）
        do {
            check("token: query 优先于 header、回退 header 并 trim、双缺失空串、header 大小写不敏感",
                  ClaudeHookServer.resolveProvidedToken(query: ["token": "q"], headers: ["X-VibeFocus-Token": "h"]) == "q"
                  && ClaudeHookServer.resolveProvidedToken(query: [:], headers: ["x-vibefocus-token": "  h \n"]) == "h"
                  && ClaudeHookServer.resolveProvidedToken(query: [:], headers: [:]) == "")
            check("token: nil/空串 expected 跳过验证、相等通过、不等拒绝、空 provided 拒绝",
                  ClaudeHookServer.isTokenValid(expectedToken: nil, providedToken: nil)
                  && ClaudeHookServer.isTokenValid(expectedToken: "", providedToken: "anything")
                  && ClaudeHookServer.isTokenValid(expectedToken: "t", providedToken: "t")
                  && !ClaudeHookServer.isTokenValid(expectedToken: "t", providedToken: "x")
                  && !ClaudeHookServer.isTokenValid(expectedToken: "t", providedToken: ""))
        }
        // bind 身份合并纯决策（B98：SessionWindowRegistry.makeBoundState 提纯——别名/合并/新建三态）
        do {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let ident = WindowIdentity(windowID: 77, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                                       appName: "Terminal", windowNumber: nil, title: "repo — zsh")
            func existingState(sessionID: String?, completed: Bool) -> WindowState {
                var ws = WindowState(
                    windowID: 77, pid: 1, tty: nil, axWindowNumber: nil, appName: "Old",
                    bundleIdentifier: nil, title: "old", termSessionID: nil, itermSessionID: nil,
                    sessionID: sessionID, bindingType: .local, isCompleted: completed,
                    createdAt: now, updatedAt: now.addingTimeInterval(-60)
                )
                ws.completedAt = completed ? now.addingTimeInterval(-30) : nil
                return ws
            }
            func make(existing: WindowState?, sessionID: String) -> SessionWindowRegistry.BindOutcome {
                SessionWindowRegistry.makeBoundState(
                    existing: existing, sessionID: sessionID, identity: ident,
                    resolvedWindowNumber: 9, terminalTTY: "/dev/ttys9",
                    terminalSessionID: nil, itermSessionID: nil,
                    cwd: "/x/proj", model: "opus", bindingType: .local, now: now)
            }
            var createdOK = false
            if case .created(let st) = make(existing: nil, sessionID: "s1") {
                createdOK = st.windowID == 77 && st.sessionID == "s1" && st.appName == "Terminal"
                    && st.isCompleted == false && st.axWindowNumber == 9 && st.tty == "/dev/ttys9"
                    && st.cwd == "/x/proj" && st.model == "opus" && st.createdAt == now
            }
            check("bindState: 无既有 → created 全字段就位", createdOK)
            var aliasSID: String?
            if case .alias(let sid) = make(existing: existingState(sessionID: "sA", completed: false), sessionID: "sB") {
                aliasSID = sid
            }
            check("bindState: 他 session 活跃绑定 → alias（不覆盖）", aliasSID == "sA")
            var mergedOK = false
            if case .merged(let st) = make(existing: existingState(sessionID: "s1", completed: false), sessionID: "s1") {
                mergedOK = st.appName == "Terminal" && st.tty == "/dev/ttys9" && st.isCompleted == false
                    && st.completedAt == nil && st.updatedAt == now
            }
            check("bindState: 同 session 重绑 → merged 刷新身份字段并复活", mergedOK)
            var reuseOK = false
            if case .merged(let st) = make(existing: existingState(sessionID: "sA", completed: true), sessionID: "sB") {
                reuseOK = st.sessionID == "sB" && st.isCompleted == false
            }
            check("bindState: 已完成绑定可被新 session 复用（completed 不算活跃冲突）", reuseOK)
        }

        // clearAllBindings + tracker.start 幂等（B115：SessionWindowRegistry+State/Tracker 收尾）
        do {
            let dir = "/tmp/vibefocus-swr6-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let solo = WindowStateStore(dbPath: dir + "/swr6.db")
            let reg = SessionWindowRegistry(store: solo)
            reg.windowStates[95] = WindowState(
                windowID: 95, pid: 100, tty: nil, axWindowNumber: nil, appName: "T",
                bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                sessionID: "clear-s", bindingType: .local, isCompleted: false,
                createdAt: Date(), updatedAt: Date())
            reg.sessionAliasWindowID["alias-c"] = 95
            solo.saveWindowState(reg.windowStates[95]!)
            reg.clearAllBindings()
            check("swrState: clearAllBindings 内存/别名/描述/DB 四清",
                  reg.windowStates.isEmpty && reg.sessionAliasWindowID.isEmpty
                  && reg.lastEventDescription == "所有绑定已清除"
                  && solo.findWindowState(windowID: 95) == nil)
            // TerminalUsageTracker.start 幂等（二次调用不炸不重复注册——observer 私有，锁不崩与表不丢）
            let tracker = TerminalUsageTracker(table: TerminalUsageTable())
            tracker.start()
            tracker.start()
            check("usageTracker: start 二次调用幂等", tracker.table.entries.isEmpty)
        }

        // SessionWindowRegistry 状态族注入式直测（B100：临时库实例——此前仅 shared 字典播种的间接消费）
        do {
            let dir = "/tmp/vibefocus-swr-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let reg = SessionWindowRegistry(store: WindowStateStore(dbPath: dir + "/swr.db"))
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            reg.windowStates[50] = WindowState(
                windowID: 50, pid: 4242, tty: nil, axWindowNumber: nil, appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal", title: "repo — zsh",
                termSessionID: nil, itermSessionID: nil, sessionID: "sx",
                bindingType: .local, isCompleted: false, createdAt: t0, updatedAt: t0)
            reg.touch(sessionID: "sx", message: "UPS 收到")
            check("swrState: touch 刷新 updatedAt 且 message 上屏", {
                let st = reg.windowStates[50]!
                return st.updatedAt > t0 && reg.lastEventDescription == "UPS 收到"
            }())
            reg.sessionAliasWindowID["sx"] = 50
            reg.markCompleted(sessionID: "sx")
            check("swrState: markCompleted 完成置位+别名清理+描述更新",
                  reg.windowStates[50]!.isCompleted && reg.windowStates[50]!.completedAt != nil
                  && reg.sessionAliasWindowID["sx"] == nil
                  && reg.lastEventDescription.contains("SessionEnd"))
            reg.reactivate(sessionID: "sx")
            check("swrState: reactivate 复活（isCompleted/completedAt 复位）",
                  reg.windowStates[50]!.isCompleted == false && reg.windowStates[50]!.completedAt == nil)
            reg.setLastEventDescription("   ")
            check("swrState: setLastEventDescription 纯空白拒写",
                  reg.lastEventDescription.contains("SessionEnd"))
            reg.remapWindowID(oldWindowID: 50, newWindowID: 51)
            check("swrState: remapWindowID 内存重映射（旧键删除新键就位+DB 同步）",
                  reg.windowStates[50] == nil && reg.windowStates[51] != nil
                  && reg.windowStates[51]!.windowID == 51
                  && reg.store.findWindowState(windowID: 51) != nil
                  && reg.store.findWindowState(windowID: 50) == nil)
        }

        // 别名查找/落库 + hook 端点 URL（B104：SessionWindowRegistry+Lookup 与 ClaudeHookPreferences 薄面补测）
        do {
            let dir = "/tmp/vibefocus-swr3-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let reg = SessionWindowRegistry(store: WindowStateStore(dbPath: dir + "/swr3.db"))
            reg.windowStates[80] = WindowState(
                windowID: 80, pid: 4242, tty: nil, axWindowNumber: nil, appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal", title: "t",
                termSessionID: nil, itermSessionID: nil, sessionID: "main-s",
                bindingType: .local, isCompleted: false, createdAt: Date(), updatedAt: Date())
            reg.sessionAliasWindowID["alias-s"] = 80
            check("swrLookup: binding(for:) 别名通道解析到主绑定",
                  reg.binding(for: "alias-s")?.windowID == 80)
            reg.persistToDB(windowID: 80)
            check("swrLookup: persistToDB 落库往返", reg.store.findWindowState(windowID: 80)?.sessionID == "main-s")
        }

        // pruneExpiredBindings 内存+DB 双层清理（B111：保留期 24h 活跃/4h 完成，removed>0 才触发内存过滤）
        do {
            let dir = "/tmp/vibefocus-swr5-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let solo = WindowStateStore(dbPath: dir + "/swr5.db")
            let reg = SessionWindowRegistry(store: solo)
            let now = Date()
            func st(_ wid: UInt32, sid: String, completed: Bool, hoursAgo: Double) -> WindowState {
                var x = WindowState(
                    windowID: wid, pid: 100, tty: nil, axWindowNumber: nil, appName: "T",
                    bundleIdentifier: nil, title: "t", termSessionID: nil, itermSessionID: nil,
                    sessionID: sid, bindingType: .local, isCompleted: completed,
                    createdAt: now.addingTimeInterval(-hoursAgo * 3600),
                    updatedAt: now.addingTimeInterval(-hoursAgo * 3600))
                if completed { x.completedAt = now.addingTimeInterval(-hoursAgo * 3600) }
                return x
            }
            // 先建实例后入库（绕过 init isTerminalPID 清扫）+ 内存字典镜像播种
            let rows = [st(1, sid: "a", completed: false, hoursAgo: 25),
                        st(2, sid: "b", completed: false, hoursAgo: 1),
                        st(3, sid: "c", completed: true, hoursAgo: 5),
                        st(4, sid: "d", completed: true, hoursAgo: 2)]
            for r in rows { solo.saveWindowState(r); reg.windowStates[r.windowID] = r }
            reg.pruneExpiredBindings(shouldPersist: false)
            check("swrPrune: DB 与内存双层按保留期清理（活跃 24h/完成 4h）——A/C 清、B/D 留",
                  solo.findWindowState(windowID: 1) == nil && solo.findWindowState(windowID: 3) == nil
                  && solo.findWindowState(windowID: 2) != nil && solo.findWindowState(windowID: 4) != nil
                  && reg.windowStates[1] == nil && reg.windowStates[3] == nil
                  && reg.windowStates[2] != nil && reg.windowStates[4] != nil)
            reg.pruneExpiredBindings(shouldPersist: false)
            check("swrPrune: 幂等——再跑无新过期（removed=0 时内存过滤不误伤）",
                  reg.windowStates.count == 2)
        }

        // binding(for:) 直命中与 alias 优先级（B116 收尾：单条目确定性夹具）
        do {
            let dir = "/tmp/vibefocus-swr7-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let solo = WindowStateStore(dbPath: dir + "/swr7.db")
            let reg = SessionWindowRegistry(store: solo)
            reg.windowStates[96] = WindowState(
                windowID: 96, pid: 100, tty: nil, axWindowNumber: nil, appName: "T",
                bundleIdentifier: nil, title: nil, termSessionID: nil, itermSessionID: nil,
                sessionID: "direct-s", bindingType: .local, isCompleted: false,
                createdAt: Date(), updatedAt: Date())
            reg.sessionAliasWindowID["direct-s"] = 96
            check("swrLookup: 直命中优先于别名（同 sessionID 两者并存时取直绑定）",
                  reg.binding(for: "direct-s")?.windowID == 96)
            check("swrLookup: 无任何命中 → nil",
                  reg.binding(for: "nope") == nil)
        }
        do {
            // endpointURLString：token 缺省纯端点；配置 token 追加查询串（用后清键）
            check("hookEndpoint: 无 token → 纯端点",
                  ClaudeHookPreferences.endpointURLString(port: 39277) == "http://127.0.0.1:39277/claude/hook")
            ClaudeHookPreferences.authToken = "tok123"
            let withToken = ClaudeHookPreferences.endpointURLString(port: 39277)
            ClaudeHookPreferences.authToken = nil
            check("hookEndpoint: 配置 token → ?token= 查询串",
                  withToken == "http://127.0.0.1:39277/claude/hook?token=tok123")
        }

        // Codex 配置路径/安装检测 + lanMode 往返 + supportTable 全表（B113 薄面收尾）
        do {
            let dir = "/tmp/vibefocus-codex-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            check("codexPath: home 注入派生目录与 hooks.json 路径",
                  CodexHookPreferences.codexConfigDir(home: dir) == dir + "/.codex"
                  && CodexHookPreferences.codexConfigPath(home: dir) == dir + "/.codex/hooks.json")
            let settingsPath = CodexHookPreferences.codexConfigPath(home: dir)
            let sp = ClaudeHookPreferences.helperScriptPath
            let installedJSON = "{\"Stop\":[{\"hooks\":[{\"command\":\"" + sp + " --run\"}]}]}"
            try? FileManager.default.createDirectory(atPath: dir + "/.codex", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: settingsPath, contents: Data(installedJSON.utf8))
            check("codexInstalled: command 含 helperScriptPath → true；缺失/无匹配 → false",
                  CodexHookPreferences.isHookInstalled(at: settingsPath) == true
                  && !CodexHookPreferences.isHookInstalled(at: dir + "/missing.json"))
            // B123 双形状：0.153.4 规范形状（事件包在顶层 "hooks" 字段下）同样识别；
            // 历史错形状（顶层事件键，codex 解析失败整文件不加载）也识别以支持迁移
            let wrappedJSON = "{\"description\":\"keep\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"command\":\"" + sp + " --run\"}]}]}}"
            let wrappedPath = settingsPath + "-wrapped"
            FileManager.default.createFile(atPath: wrappedPath, contents: Data(wrappedJSON.utf8))
            check("codexInstalled: 规范形状（hooks 包裹层）识别且 description 字段共存",
                  CodexHookPreferences.isHookInstalled(at: wrappedPath) == true)
            // codex 可触发事件集：SessionStart 恒注册、SessionEnd 按开关、
            // Stop/UserPromptSubmit 为 Claude 特有不写（codex 0.153.4 实证）
            let savedSessionEnd = ClaudeHookPreferences.triggerOnSessionEnd
            defer { ClaudeHookPreferences.triggerOnSessionEnd = savedSessionEnd }
            ClaudeHookPreferences.triggerOnSessionEnd = false
            check("codexHooks: SessionEnd 关 → 仅 SessionStart（无 Stop/UserPromptSubmit）",
                  Set(CodexHookPreferences.codexHooksDict().keys) == ["SessionStart"])
            ClaudeHookPreferences.triggerOnSessionEnd = true
            check("codexHooks: SessionEnd 开 → SessionStart+SessionEnd",
                  Set(CodexHookPreferences.codexHooksDict().keys) == ["SessionEnd", "SessionStart"])
            let savedLan = LANHookPreferences.lanMode
            defer { LANHookPreferences.lanMode = savedLan }
            LANHookPreferences.lanMode = true
            check("lanMode: set/get 往返", LANHookPreferences.lanMode == true)
            LANHookPreferences.lanMode = false
            check("lanMode: 复位 false", LANHookPreferences.lanMode == false)
        }
        do {
            // supportTable 九终端全表契约（设置页 Picker 名单与自动化分级的唯一事实源）
            let expected: [String: TerminalAutomationSupportLevel] = [
                "com.apple.Terminal": .full, "com.googlecode.iterm2": .partial,
                "dev.warp.Warp-Stable": .none, "com.mitchellh.ghostty": .none,
                "io.alacritty": .none, "net.kovidgoyal.kitty": .none,
                "com.github.wez.wezterm": .none, "com.electron.hyper": .none,
                "org.tabby": .none,
            ]
            check("supportTable: 九终端全表逐项锁定（新增/删除/改级都红）",
                  TerminalSelectionResolver.supportTable == expected
                  && TerminalSelectionResolver.supportTable.count == 9)
        }

        // mergedHooks 合并+开关裁剪（B112：CodexHookInstaller 52% 薄面——幂等/外部保留/开关移除）
        do {
            let targetURL = "http://127.0.0.1:39277/claude/hook"
            let scriptPath = "/opt/vibefocus/helper.sh"
            let ourEntry: [String: Any] = ["hooks": [["url": targetURL, "timeout": 10]]]
            let foreignEntry: [String: Any] = ["hooks": [["command": "/usr/bin/other-tool"]]]
            let ourHooks: [String: Any] = [
                "Stop": ourEntry, "SessionEnd": ourEntry, "UserPromptSubmit": ourEntry,
            ]
            // 全新安装：三事件就位；外部键原样保留
            let fresh = CodexHookPreferences.mergedHooks(
                existing: ["Other": foreignEntry], ourHooks: ourHooks,
                triggerOnSessionEnd: true, autoRestoreOnPromptSubmit: true,
                scriptPath: scriptPath, targetURL: targetURL)
            check("mergedHooks: 全新安装三事件就位且外部键保留",
                  fresh["Stop"] != nil && fresh["SessionEnd"] != nil
                  && fresh["UserPromptSubmit"] != nil && fresh["Other"] != nil)
            // 开关裁剪：SessionEnd/UserPromptSubmit 按开关移除
            let trimmed = CodexHookPreferences.mergedHooks(
                existing: [:], ourHooks: ourHooks,
                triggerOnSessionEnd: false, autoRestoreOnPromptSubmit: false,
                scriptPath: scriptPath, targetURL: targetURL)
            check("mergedHooks: 开关关闭 → SessionEnd/UserPromptSubmit 移除、Stop 留存",
                  trimmed["SessionEnd"] == nil && trimmed["UserPromptSubmit"] == nil
                  && trimmed["Stop"] != nil)
            // 幂等：对合并结果再合并一次 → 结果不变（防重装叠加）
            let twice = CodexHookPreferences.mergedHooks(
                existing: fresh, ourHooks: ourHooks,
                triggerOnSessionEnd: true, autoRestoreOnPromptSubmit: true,
                scriptPath: scriptPath, targetURL: targetURL)
            check("mergedHooks: 幂等——重装不叠加（键集与 fresh 一致）",
                  Set(twice.keys) == Set(fresh.keys))
        }

        // generateHooksDict 三开关组合（B117：默认四事件字典契约——Stop 恒注册）
        do {
            let saved = (ClaudeHookPreferences.triggerOnStop,
                         ClaudeHookPreferences.triggerOnSessionEnd,
                         ClaudeHookPreferences.autoRestoreOnPromptSubmit)
            defer {
                ClaudeHookPreferences.triggerOnStop = saved.0
                ClaudeHookPreferences.triggerOnSessionEnd = saved.1
                ClaudeHookPreferences.autoRestoreOnPromptSubmit = saved.2
            }
            ClaudeHookPreferences.triggerOnStop = true
            ClaudeHookPreferences.triggerOnSessionEnd = true
            ClaudeHookPreferences.autoRestoreOnPromptSubmit = true
            let all = ClaudeHookPreferences.generateHooksDict()
            check("hooksDict: 三开关全开 → 四事件键齐且条目嵌 hooks 含 helper 命令",
                  Set(all.keys) == ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"]
                  && ((all["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] != nil)
            ClaudeHookPreferences.triggerOnSessionEnd = false
            ClaudeHookPreferences.autoRestoreOnPromptSubmit = false
            let trimmed = ClaudeHookPreferences.generateHooksDict()
            check("hooksDict: 开关关 → SessionEnd/UserPromptSubmit 不注册、Stop 恒注册",
                  Set(trimmed.keys) == ["SessionStart", "Stop"])
        }

        // uninstallHookFromCodexSettings（B114：卸载路径——外部条目保留/缺文件免卸载/坏 JSON 拒绝）
        do {
            let dir = "/tmp/vibefocus-codex2-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let settingsPath = dir + "/.codex/hooks.json"
            try? FileManager.default.createDirectory(atPath: dir + "/.codex", withIntermediateDirectories: true)
            let targetURL = "http://127.0.0.1:39277/claude/hook"
            let scriptPath = "/opt/vibefocus/helper.sh"
            let mixed = "{\"Stop\":[{\"hooks\":[{\"url\":\"" + targetURL + "\"}]},{\"hooks\":[{\"command\":\"/usr/bin/other\"}]}],\"Other\":[{\"hooks\":[{\"command\":\"keep-me\"}]}]}"
            FileManager.default.createFile(atPath: settingsPath, contents: Data(mixed.utf8))
            let (ok1, _) = CodexHookPreferences.uninstallHookFromCodexSettings(
                at: settingsPath, scriptPath: scriptPath, targetURL: targetURL)
            let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any]) ?? [:]
            check("codexUninstall: 我方条目清除、外部条目保留、返回成功",
                  ok1 && after["Stop"] != nil && after["Other"] != nil)
            let stopHooks = (after["Stop"] as? [[String: Any]])?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] } ?? []
            check("codexUninstall: Stop 内仅剩外部 command 条目",
                  stopHooks.count == 1
                  && (stopHooks.first?["command"] as? String) == "/usr/bin/other")
            check("codexUninstall: 缺文件与坏 JSON 均视为已卸载 true",
                  CodexHookPreferences.uninstallHookFromCodexSettings(
                    at: dir + "/missing.json", scriptPath: scriptPath, targetURL: targetURL).0
                  && CodexHookPreferences.uninstallHookFromCodexSettings(
                    at: dir + "/.codex/bad.json", scriptPath: scriptPath, targetURL: targetURL).0)
        }

        // resolveRemoteBinding 真实查找路径（B107：label 未映射/映射窗口已消失两分支——
        // remoteBindings 种子化进独立 UserDefaults 域，用后清键）
        do {
            let key = "remoteBindings"
            let saved = LANHookPreferences.remoteBindings
            defer {
                LANHookPreferences.remoteBindings = saved
                UserDefaults.standard.removeObject(forKey: key)
            }
            LANHookPreferences.remoteBindings = ["lab-live": 424242]
            let handler = HookEventHandler.shared
            check("remoteBind: label 未映射 → nil 且描述更新",
                  handler.resolveRemoteBinding(label: "no-such-label", sessionID: "s-x") == nil
                  && SessionWindowRegistry.shared.lastEventDescription.contains("no-such-label"))
            check("remoteBind: label 已映射但窗口已消失 → nil（window_gone）",
                  handler.resolveRemoteBinding(label: "lab-live", sessionID: "s-x") == nil)
        }


        // ensureTokenGenerated 生成/缓存契约（B120：token 稳定性有安全意义——独立域用后清键）
        do {
            let saved = ClaudeHookPreferences.authToken
            defer { ClaudeHookPreferences.authToken = saved }
            ClaudeHookPreferences.authToken = nil
            let first = ClaudeHookPreferences.ensureTokenGenerated()
            check("token: 缺失时生成 32 位小写十六进制并持久化",
                  first.count == 32
                  && first == first.lowercased()
                  && first.allSatisfy { $0.isHexDigit }
                  && ClaudeHookPreferences.authToken == first)
            check("token: 已有 token 原样返回（不轮换）",
                  ClaudeHookPreferences.ensureTokenGenerated() == first)
            ClaudeHookPreferences.authToken = nil
            let second = ClaudeHookPreferences.ensureTokenGenerated()
            check("token: 清空后重新生成 → 新随机 token", second != first && second.count == 32)
        }

        // binding(for:) DB-fallback 脏数据清理分支（B108：非终端 pid 的 DB 绑定被识别并清除）
        do {
            let dir = "/tmp/vibefocus-swr4-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let solo = WindowStateStore(dbPath: dir + "/swr4.db")
            let reg = SessionWindowRegistry(store: solo)
            // 先建实例后入库（绕过 init 的 isTerminalPID 清扫，B102 实证）：pid 12345 非真实终端进程
            var dirty = WindowState(
                windowID: 90, pid: 12345, tty: nil, axWindowNumber: nil, appName: "Ghost",
                bundleIdentifier: nil, title: "stale", termSessionID: nil, itermSessionID: nil,
                sessionID: "dirty-s", bindingType: .local, isCompleted: false,
                createdAt: Date(), updatedAt: Date())
            dirty.isCompleted = false
            solo.saveWindowState(dirty)
            check("swrLookup: DB 脏绑定（非终端 pid）→ 返回 nil 并从库清除",
                  reg.binding(for: "dirty-s") == nil
                  && solo.findWindowStateBySession(sessionID: "dirty-s") == nil)
            check("swrLookup: 清理后再查 → nil（幂等）",
                  reg.binding(for: "dirty-s") == nil)
        }

        // 编排目标候选装配（B106：selectionPreview 静态缝提纯——runningIDs/usageRank 接线锁定）
        do {
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            func rank(_ id: String, _ count: Int) -> [(bundleID: String, count: Int, lastAt: Date)] {
                [(bundleID: id, count: count, lastAt: t0)]
            }
            check("selPreview: .terminal 偏好 → manual 指定 Terminal.app（压过他端用量）",
                  TerminalGridController.selectionPreview(
                    runningBundleIDs: ["com.googlecode.iterm2"],
                    usageRank: rank("com.googlecode.iterm2", 9),
                    appPreference: .terminal).bundleID == "com.apple.Terminal")
            check("selPreview: .iterm2 偏好 → manual iterm2",
                  TerminalGridController.selectionPreview(
                    runningBundleIDs: [], usageRank: [],
                    appPreference: .iterm2).bundleID == "com.googlecode.iterm2")
            check("selPreview: .auto + 用量与运行观测接线（运行者优先于高用量）",
                  TerminalGridController.selectionPreview(
                    runningBundleIDs: ["dev.warp.Warp-Stable"],
                    usageRank: rank("com.apple.Terminal", 9),
                    appPreference: .auto).bundleID == "com.apple.Terminal")
            check("selPreview: .auto + 全零观测 → autoDefault 兜底 Terminal.app",
                  TerminalGridController.selectionPreview(
                    runningBundleIDs: [], usageRank: [],
                    appPreference: .auto).source == .autoDefault)
        }

        // Lookup/UI 支持成员（B102：SessionWindowRegistry+Lookup 29% 最薄面补测——临时库实例）
        do {
            let dir = "/tmp/vibefocus-swr2-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let reg = SessionWindowRegistry(store: WindowStateStore(dbPath: dir + "/swr2.db"))
            let base = Date().addingTimeInterval(-3600)
            func ws(_ wid: UInt32, sid: String, completed: Bool, createdAt: Date, updatedAt: Date) -> WindowState {
                var st = WindowState(
                    windowID: wid, pid: 100, tty: nil, axWindowNumber: nil, appName: "T",
                    bundleIdentifier: nil, title: "t", termSessionID: nil, itermSessionID: nil,
                    sessionID: sid, bindingType: .local, isCompleted: completed,
                    createdAt: createdAt, updatedAt: updatedAt)
                if completed { st.completedAt = updatedAt }
                return st
            }
            reg.windowStates[60] = ws(60, sid: "old-active", completed: false,
                                      createdAt: base, updatedAt: base)
            reg.windowStates[61] = ws(61, sid: "new-active", completed: false,
                                      createdAt: base.addingTimeInterval(600), updatedAt: base.addingTimeInterval(600))
            reg.windowStates[62] = ws(62, sid: "recent-done", completed: true,
                                      createdAt: base, updatedAt: Date().addingTimeInterval(-600))
            reg.windowStates[63] = ws(63, sid: "old-done", completed: true,
                                      createdAt: base, updatedAt: Date().addingTimeInterval(-3600))
            check("swrLookup: activeBindingsForUI 只含活跃且按 createdAt 降序",
                  reg.activeBindingsForUI.map(\.windowID) == [61, 60])
            check("swrLookup: recentCompletedBindings 仅 30 分钟内完成且按 updatedAt 降序",
                  reg.recentCompletedBindings.map(\.windowID) == [62])
            // findState DB 回填：内存缺失时从库装载并回填缓存
            let solo = WindowStateStore(dbPath: dir + "/solo.db")
            let reg2 = SessionWindowRegistry(store: solo)
            // 先建实例后入库：绕过 init 的 isTerminalPID 清扫（pid 100 非真实终端进程）
            solo.saveWindowState(ws(70, sid: "s-db", completed: false, createdAt: base, updatedAt: base))
            check("swrLookup: findState 内存 miss → DB 装载并回填缓存",
                  reg2.findState(windowID: 70)?.sessionID == "s-db"
                  && reg2.windowStates[70] != nil)
        }
    }
    }
}
