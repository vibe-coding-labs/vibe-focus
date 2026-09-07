import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSoundVoiceHookTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runSoundVoiceHookTests() {
    // MARK: SoundPreferences 兼容解码 + CustomSoundStatus（真实实现——持久化铁律：旧 JSON 缺字段不得静默重置）

    do {
        // 旧版本 JSON：只有 soundType 一个字段（v1 时代用户保存的形态）
        let legacyJSON = Data(#"{"soundType":"builtin_ding"}"#.utf8)
        let legacy = try? JSONDecoder().decode(SoundPreferences.self, from: legacyJSON)
        check("prefs: 旧 JSON 可解码", legacy != nil)
        check("prefs: soundType 保留", legacy?.soundType == .builtinDing)
        check("prefs: customSoundPath 缺省 nil", legacy?.customSoundPath == nil)
        check("prefs: minPlayIntervalSeconds 缺省 2", legacy?.minPlayIntervalSeconds == 2)
        check("prefs: quietHours 缺省关闭", legacy?.quietHoursEnabled == false)
        check("prefs: quietStart/End 缺省 22/8",
              legacy?.quietStartHour == 22 && legacy?.quietEndHour == 8)
        check("prefs: projectRules 缺省空", legacy?.projectRules.isEmpty == true)

        // 全字段往返
        let full = SoundPreferences(
            soundType: .custom, customSoundPath: "/tmp/a.m4a",
            volume: 0.5, minPlayIntervalSeconds: 7,
            quietHoursEnabled: true, quietStartHour: 1, quietEndHour: 6,
            projectRules: [ProjectSoundRule(projectName: "p", soundType: .builtinPing)]
        )
        let roundtrip = try? JSONDecoder().decode(SoundPreferences.self, from: JSONEncoder().encode(full))
        check("prefs: 全字段往返一致", roundtrip == full)

        // 未来版本多字段（向前容忍：JSONDecoder 默认忽略未知键）
        let futureJSON = Data(#"{"soundType":"builtin_ping","futureField":123}"#.utf8)
        let future = try? JSONDecoder().decode(SoundPreferences.self, from: futureJSON)
        check("prefs: 未来字段不炸解码", future?.soundType == .builtinPing)

        // 非法 JSON → nil（调用方 loadPreferences 回退 .default）
        check("prefs: 非法 JSON 解码失败可被捕获",
              (try? JSONDecoder().decode(SoundPreferences.self, from: Data("not-json".utf8))) == nil)

        // CustomSoundStatus.evaluate 真实实现分支（文件系统交互）
        check("soundStatus: nil → notSet", CustomSoundStatus.evaluate(path: nil) == .notSet)
        check("soundStatus: 空串 → notSet", CustomSoundStatus.evaluate(path: "") == .notSet)
        check("soundStatus: 不存在文件 → missing",
              CustomSoundStatus.evaluate(path: "/tmp/vf-definitely-missing-\(UUID().uuidString).wav") == .missing)
        let tmp = "/tmp/vf-sound-status-\(UUID().uuidString).wav"
        FileManager.default.createFile(atPath: tmp, contents: Data([0]))
        check("soundStatus: 存在文件 → valid", CustomSoundStatus.evaluate(path: tmp) == .valid)
        try? FileManager.default.removeItem(atPath: tmp)
        check("soundStatus: 文件删除后 → missing", CustomSoundStatus.evaluate(path: tmp) == .missing)
    }

    // MARK: 编排页提纯单元（真实实现——B3：目标摘要/终端说明文案/间距步进）

    do {
        // GridTargetCode.summaryText：四分支
        check("targetSummary: main", GridTargetCode.main.summaryText == "→ 主屏")
        check("targetSummary: focused", GridTargetCode.focused.summaryText == "→ 焦点屏")
        check("targetSummary: display", GridTargetCode.display(displayID: 7).summaryText == "→ #7 当前 Space")
        check("targetSummary: displaySpace", GridTargetCode.displaySpace(displayID: 7, spaceIndex: 3).summaryText == "→ #7 · Space 3")
        check("targetSummary: parse→summary 集成",
              GridTargetCode.parse("d2s5")?.summaryText == "→ #2 · Space 5")

        // AppPreference.selectionDetailText：三分支非空且互异
        let details = [
            TerminalGridPreferences.AppPreference.auto,
            .terminal,
            .iterm2
        ].map { $0.selectionDetailText }
        check("appPrefDetail: 三分支非空且互异",
              details.allSatisfy { !$0.isEmpty } && Set(details).count == 3)
        check("appPrefDetail: terminal 指明完整支持", details[1].contains("完整支持"))
        check("appPrefDetail: iterm2 指明部分支持", details[2].contains("部分支持"))

        // TerminalGridPlanner.steppedGap：2px 步进取整
        check("steppedGap: 0 → 0（无缝）", TerminalGridPlanner.steppedGap(0) == 0)
        check("steppedGap: 1.2 → 2（向上取档）", TerminalGridPlanner.steppedGap(1.2) == 2)
        check("steppedGap: 3.9 → 4（恰档不动）", TerminalGridPlanner.steppedGap(3.9) == 4)
        check("steppedGap: 24 → 24（上界）", TerminalGridPlanner.steppedGap(24) == 24)
        check("steppedGap: 23 → 24（越上界取整）", TerminalGridPlanner.steppedGap(23) == 24)
    }

    // MARK: SA 恢复状态机（真实实现——B4：recoveryVerdict/autoRecoveryAllowed/saProbeVerdict 穷尽锁定）

    do {
        // recoveryVerdict：成功/SIP 阻断/用户拒绝（大小写容忍）/其他失败
        check("saVerdict: success → succeeded",
              SpaceController.recoveryVerdict(success: true, outputOrError: "") == .succeeded)
        check("saVerdict: success 优先于错误文本",
              SpaceController.recoveryVerdict(success: true, outputOrError: "System Integrity Protection") == .succeeded)
        check("saVerdict: SIP 文本 → blockedBySIP",
              SpaceController.recoveryVerdict(success: false, outputOrError: "yabai: System Integrity Protection forbids") == .blockedBySIP)
        check("saVerdict: User Canceled 大小写容忍 → userDeclined",
              SpaceController.recoveryVerdict(success: false, outputOrError: "script error: User Canceled.") == .userDeclined)
        check("saVerdict: 其他输出 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "connection invalid") == .failedOther)
        check("saVerdict: 空输出 → failedOther",
              SpaceController.recoveryVerdict(success: false, outputOrError: "") == .failedOther)

        // autoRecoveryAllowed：冷静期矩阵（含边界小时）
        let week: TimeInterval = 7 * 24
        check("saRetry: blockedBySIP 永不自动重试",
              !SpaceController.autoRecoveryAllowed(verdict: .blockedBySIP, hoursSince: week * 52))
        check("saRetry: succeeded 无需恢复",
              !SpaceController.autoRecoveryAllowed(verdict: .succeeded, hoursSince: week))
        check("saRetry: userDeclined 冷静期未满拒",
              !SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: week - 1))
        check("saRetry: userDeclined 冷静期满放行",
              SpaceController.autoRecoveryAllowed(verdict: .userDeclined, hoursSince: week))
        check("saRetry: failedOther 24h 未满拒",
              !SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 23.9))
        check("saRetry: failedOther 24h 满放行",
              SpaceController.autoRecoveryAllowed(verdict: .failedOther, hoursSince: 24))

        // saProbeVerdict（真实实现直测，收敛 Standalone 镜像语义）
        check("saProbe: exit 0 → 通过",
              SpaceController.saProbeVerdict(exitCode: 0, stderr: ""))
        check("saProbe: SA 缺失 → 不通过",
              !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: error with the scripting-addition"))
        check("saProbe: mission-control 阻断 → 不通过",
              !SpaceController.saProbeVerdict(exitCode: 1, stderr: "yabai: cannot focus space: mission-control is active!"))
        check("saProbe: 其他错误 → 通过（非 SA 类失败不判死）",
              SpaceController.saProbeVerdict(exitCode: 2, stderr: "yabai: unknown command"))
    }

    // MARK: 语音播报插值与队列策略（真实实现——B5：消镜像漂移，直测 Sources）

    do {
        func payload(cwd: String?, projectDir: String?, model: String?, sessionID: String) -> ClaudeHookPayload {
            ClaudeHookPayload(
                event: .stop, sessionID: sessionID, source: "test", timestamp: nil,
                cwd: cwd,
                model: model,
                terminalCtx: TerminalContext(
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                    weztermPane: nil, tty: nil, ppid: nil,
                    claudeProjectDir: projectDir, windowID: nil, machineLabel: nil
                ),
                lastAssistantMessage: nil, transcriptPath: nil
            )
        }
        let p = payload(cwd: "/tmp/repo", projectDir: "/Users/u/github/vibe-coding-labs/", model: "GLM", sessionID: "sess-1")
        check("interpolate: 四变量全替换",
              VoiceAnnouncementTemplate.interpolate("{project_name}/{model}@{cwd}#{session_id}", payload: p)
              == "vibe-coding-labs/GLM@/tmp/repo#sess-1")
        check("interpolate: projectDir 去首尾斜杠取末段", !VoiceAnnouncementTemplate.interpolate("{project_name}", payload: p).contains("/"))
        let noCtx = payload(cwd: nil, projectDir: nil, model: nil, sessionID: "s2")
        check("interpolate: 缺 ctx → 未知项目/未知模型/cwd 空串",
              VoiceAnnouncementTemplate.interpolate("{project_name}|{model}|{cwd}", payload: noCtx) == "未知项目|未知模型|")
        check("interpolate: sessionID 原样保留（无兜底）",
              VoiceAnnouncementTemplate.interpolate("{session_id}", payload: noCtx) == "s2")
        check("interpolate: 无变量模板原样返回",
              VoiceAnnouncementTemplate.interpolate("对话完成", payload: p) == "对话完成")

        // 队列策略：容量边界与丢最旧顺序
        func q(_ items: [Int]) -> [QueuedAnnouncement] {
            items.map { .text("t\($0)") }
        }
        func ids(_ items: [QueuedAnnouncement]) -> [String] {
            items.map { if case .text(let s) = $0 { return s } ; return "?" }
        }
        var queue = VoiceAnnouncementQueuePolicy.appendedQueue([], appending: .text("t1"), capacity: 3)
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t2"), capacity: 3)
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t3"), capacity: 3)
        check("queue: 未满按序保留", ids(queue) == ["t1", "t2", "t3"])
        queue = VoiceAnnouncementQueuePolicy.appendedQueue(queue, appending: .text("t4"), capacity: 3)
        check("queue: 满则丢最旧", ids(queue) == ["t2", "t3", "t4"])
        let defensive = VoiceAnnouncementQueuePolicy.appendedQueue(q([1]), appending: .text("x"), capacity: 0)
        check("queue: capacity<1 防御为 1（新条目总在）", ids(defensive) == ["x"])
    }

    // MARK: 提示音设置页提纯（真实实现——B9：节流/免打扰文案 + 规则兜底音效）

    do {
        check("throttleLabel: 0 → 关闭", SoundSectionText.throttleLabel(seconds: 0) == "关闭")
        check("throttleLabel: 7 → 7 秒", SoundSectionText.throttleLabel(seconds: 7) == "7 秒")
        check("quietHoursDetail: 开启 → 静音说明",
              SoundSectionText.quietHoursDetail(enabled: true).contains("保持静音"))
        check("quietHoursDetail: 关闭 → 设定说明",
              SoundSectionText.quietHoursDetail(enabled: false).contains("设定静音时间段"))

        let ruleWithSound = ProjectSoundRule(projectName: "p", soundType: .builtinPing)
        check("ruleSound: 显式音效生效", ruleWithSound.effectiveSoundType == .builtinPing)
        let ruleRaw = ProjectSoundRule(projectName: "p2", soundType: .builtinComplete)
        var ruleEmpty = ruleRaw
        ruleEmpty.soundRawValue = "not-a-sound"
        check("ruleSound: 非法 rawValue → 兜底 builtinComplete",
              ruleEmpty.effectiveSoundType == .builtinComplete)
    }

    // MARK: Hook 数据契约（真实实现——B6：ClaudeHookPayload 容错解码/TerminalContext 绑定判据穷尽锁定）

    do {
        func decode(_ json: String) throws -> ClaudeHookPayload {
            try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
        }
        // 事件键双别名
        check("payload: event 键", (try? decode(#"{"event":"Stop","session_id":"s1"}"#))?.event == .stop)
        check("payload: hook_event_name 别名", (try? decode(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#))?.event == .sessionStart)
        check("payload: 两键皆缺 → 抛错", (try? decode(#"{"session_id":"s1"}"#)) == nil)
        check("payload: 未知事件值 → 抛错", (try? decode(#"{"event":"Nonsense","session_id":"s1"}"#)) == nil)
        // 会话键别名 + trim + 空拒绝
        check("payload: session_id 键", (try? decode(#"{"event":"Stop","session_id":"  abc  "}"#))?.sessionID == "abc")
        check("payload: sessionId 别名", (try? decode(#"{"event":"Stop","sessionId":"abc"}"#))?.sessionID == "abc")
        check("payload: 空白会话 → 抛错", (try? decode(#"{"event":"Stop","session_id":"   "}"#)) == nil)
        check("payload: 缺会话 → 抛错", (try? decode(#"{"event":"Stop"}"#)) == nil)
        // 可选字段缺省 nil
        let minimal = try! decode(#"{"event":"Stop","session_id":"m1"}"#)
        check("payload: 可选字段缺省 nil",
              minimal.source == nil && minimal.cwd == nil && minimal.model == nil
              && minimal.terminalCtx == nil && minimal.lastAssistantMessage == nil
              && minimal.transcriptPath == nil)
        // 嵌套 terminalCtx（snake_case 键）+ 文本字段
        let rich = try! decode("""
        {"event":"UserPromptSubmit","session_id":"r1","source":"cc","cwd":"/w",
         "model":"m","transcript_path":"/t.jsonl","last_assistant_message":"hi",
         "terminal_ctx":{"tty":"/dev/ttys004","claude_project_dir":"/repo","window_id":"42"}}
        """)
        check("payload: 嵌套 ctx 解码", rich.terminalCtx?.tty == "/dev/ttys004"
              && rich.terminalCtx?.claudeProjectDir == "/repo" && rich.terminalCtx?.windowID == "42")
        check("payload: 其余可选字段解码", rich.source == "cc" && rich.cwd == "/w"
              && rich.model == "m" && rich.transcriptPath == "/t.jsonl"
              && rich.lastAssistantMessage == "hi")

        // TerminalContext.hasUsefulContext：五因子判定（绑定前置判据）
        func ctx(tty: String? = nil, term: String? = nil, iterm: String? = nil,
                 ppid: String? = nil, machine: String? = nil) -> TerminalContext {
            TerminalContext(termSessionID: term, itermSessionID: iterm, kittyWindowID: nil,
                            weztermPane: nil, tty: tty, ppid: ppid,
                            claudeProjectDir: nil, windowID: nil, machineLabel: machine)
        }
        check("ctx: tty 单独即有用", ctx(tty: "/dev/ttys001").hasUsefulContext)
        check("ctx: termSessionID 单独即有用", ctx(term: "t").hasUsefulContext)
        check("ctx: itermSessionID 单独即有用", ctx(iterm: "i").hasUsefulContext)
        check("ctx: 有效 ppid(>1) 即有用", ctx(ppid: "123").hasUsefulContext)
        check("ctx: ppid=1 无用（init 进程排除）", !ctx(ppid: "1").hasUsefulContext)
        check("ctx: ppid 非数字无用", !ctx(ppid: "abc").hasUsefulContext)
        check("ctx: machineLabel 单独即有用", ctx(machine: "srv-1").hasUsefulContext)
        check("ctx: 全空无用", !ctx(tty: "", term: "", iterm: "", ppid: "", machine: "").hasUsefulContext)
        check("ctx: 全 nil 无用", !ctx().hasUsefulContext)
        check("ctx: isRemote 有标签 true", ctx(machine: "srv").isRemote)
        check("ctx: isRemote 空/nil 标签 false", !ctx(machine: "").isRemote && !ctx().isRemote)

        // ClaudeHookResponse 编码：sessionID 走 snake_case
        let respObj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ClaudeHookResponse(ok: true, code: "ok", message: "done", sessionID: "s9", handled: true)
        ))) as? [String: Any]
        check("response: session_id snake_case 键", respObj?["session_id"] as? String == "s9" && respObj?["ok"] as? Bool == true)
    }

    // MARK: Hook 窗移决策树（真实实现——B7：守护顺序契约从镜像转 Runner 直测，决策树唯一事实源）

    do {
        typealias D = HookEventHandler.WindowMoveDecision
        // 守护顺序逐条锁定（顺序即生产契约：前一条满足时后条不可达）
        check("decide: autoFocus 关闭最优先",
              HookEventHandler.decideWindowMove(autoFocusEnabled: false, hasBinding: false, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .autoFocusDisabled)
        check("decide: remoteOnly → localBindingSkip（跳过全部绑定语义）",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true, remoteOnly: true) == .localBindingSkip)
        check("decide: 无绑定 → noBindingSkip",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: false, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .noBindingSkip)
        check("decide: 绑定未验证 → bindingVerificationFailed",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: false, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: nil, isTerminalOrIDE: false) == .bindingVerificationFailed)
        check("decide: 已在主屏 → alreadyOnMainScreen",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: true, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .alreadyOnMainScreen)
        check("decide: 恢复冷却 → restoreCooldownActive",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: true, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .restoreCooldownActive)
        check("decide: 陈旧绑定+pid 失配 → staleBindingPIDMismatch",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1801, pidMatches: false, isTerminalOrIDE: true) == .staleBindingPIDMismatch)
        check("decide: pid 失配但未超龄 → 继续移动",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1799, pidMatches: false, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))
        check("decide: 非终端窗 → nonTerminalWindow",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: false) == .nonTerminalWindow)
        check("decide: 全绿 → proceedToMove(binding)",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 0, pidMatches: true, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))
        check("decide: pidMatches nil（查询失败）+ 超龄 → 不判死继续移动",
              HookEventHandler.decideWindowMove(autoFocusEnabled: true, hasBinding: true, bindingVerified: true, isWindowOnMainScreen: false, isInCooldown: false, bindingAge: 1801, pidMatches: nil, isTerminalOrIDE: true) == .proceedToMove(source: "binding"))

        // 决策 → HTTP 响应映射表：8 跳过类全部 200+handled=false+code 对应；proceed → nil
        for (decision, code) in [(D.autoFocusDisabled, "auto_focus_disabled"),
                                 (D.localBindingSkip, "trigger_disabled_skip"),
                                 (D.noBindingSkip, "no_binding_skip"),
                                 (D.bindingVerificationFailed, "binding_verification_failed"),
                                 (D.alreadyOnMainScreen, "already_on_main_screen"),
                                 (D.restoreCooldownActive, "restore_cooldown_active"),
                                 (D.staleBindingPIDMismatch, "stale_binding_pid_mismatch"),
                                 (D.nonTerminalWindow, "non_terminal_window")] as [(HookEventHandler.WindowMoveDecision, String)] {
            guard let resp = HookEventHandler.httpResponse(for: decision, triggerName: "T", sessionID: "s") else {
                check("httpResponse: \(code) 应有响应", false)
                continue
            }
            check("httpResponse: \(code) → 200/handled=false/code 对应",
                  resp.statusCode == 200 && resp.response.ok && !resp.response.handled
                  && resp.response.code == code)
        }
        check("httpResponse: proceedToMove → nil（响应由执行器产生）",
              HookEventHandler.httpResponse(for: .proceedToMove(source: "binding"), triggerName: "T", sessionID: "s") == nil)
        check("logDescription: proceed 带源标注",
              D.proceedToMove(source: "binding").logDescription == "proceed_to_move(source=binding)")
    }

    // MARK: Space 投递决策（真实实现——B8：七分支决策表从镜像转 Runner 直测）

    do {
        typealias Dec = TerminalGridController.SpaceDeliveryDecision
        typealias Args = (
            targetSpaceIndex: Int?, targetDisplayVisibleSpace: Int?,
            targetDisplayIndex: Int?, windowDisplayIndex: Int?,
            hasParkingDisplay: Bool, windowSpaceIndex: Int?
        )
        func decide(_ a: Args) -> TerminalGridController.SpaceDeliveryDecision {
            TerminalGridController.spaceDeliveryDecision(
                targetSpaceIndex: a.targetSpaceIndex,
                targetDisplayVisibleSpace: a.targetDisplayVisibleSpace,
                targetDisplayIndex: a.targetDisplayIndex,
                windowDisplayIndex: a.windowDisplayIndex,
                hasParkingDisplay: a.hasParkingDisplay,
                windowSpaceIndex: a.windowSpaceIndex
            )
        }
        // 全参便利：显式目标 Space 5 / 目标屏 display 1 / 双屏
        let base = Args(5, 5, 1, 1, true, 5)
        check("delivery: 窗已在目标 space → notNeeded", decide(base) == .notNeeded)
        check("delivery: 非显式 space 目标 → notApplicable",
              decide(Args(nil, 5, 1, 1, true, 5)) == .notApplicable)
        check("delivery: yabai 不可用（可见 space nil）→ skipNoYabai",
              decide(Args(5, nil, 1, 1, true, 5)) == .skipNoYabai)
        check("delivery: 目标屏视角未在目标 space → skipViewNotOnTarget",
              decide(Args(5, 4, 1, 1, true, 5)) == .skipViewNotOnTarget)
        check("delivery: 跨屏窗 + 有泊位屏 → deliverCrossDisplay",
              decide(Args(5, 5, 1, 2, true, nil)) == .deliverCrossDisplay)
        check("delivery: 同屏错位 + 有泊位屏 → deliverRoundTrip",
              decide(Args(5, 5, 1, 1, true, 3)) == .deliverRoundTrip)
        check("delivery: 同屏错位 + 单屏无泊位 → skipNoParkingDisplay",
              decide(Args(5, 5, 1, 1, false, 3)) == .skipNoParkingDisplay)
        check("delivery: 窗 space 查询失败（nil）按需投递（同屏）",
              decide(Args(5, 5, 1, 1, true, nil)) == .deliverRoundTrip)
        check("delivery: 窗 display 查询失败（nil）≠ 目标屏 → 跨屏",
              decide(Args(5, 5, 1, nil, true, nil)) == .deliverCrossDisplay)
    }
    }
}
