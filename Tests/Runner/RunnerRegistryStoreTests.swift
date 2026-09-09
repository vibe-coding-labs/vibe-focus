import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerRegistryStoreTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runRegistryStoreTests() {
    // MARK: Overlay 刷新域（真实实现——防风暴门/热插拔防护/Space 快照解析，Batch 12）

    do {
        // A. refreshGate 门矩阵真身（镜像 OverlayRefreshPolicyTests 同矩阵）。
        check("overlayGate A1: suspend+非force → skipSuspended",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: true, force: false) == .skipSuspended)
        check("overlayGate A2: suspend+force → proceed（debounce 补刷新穿透 suspend）",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: true, force: true) == .proceed)
        check("overlayGate A3: disabled 恒 skip（force 不豁免）",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: false, force: true) == .skipDisabled
              && OverlayRefreshPolicy.refreshGate(suspended: false, enabled: false, force: true) == .skipDisabled)
        check("overlayGate A4: 常态 proceed",
              OverlayRefreshPolicy.refreshGate(suspended: false, enabled: true, force: false) == .proceed)

        // B. 去重判定真身。
        let last = Date(timeIntervalSince1970: 1000)
        check("overlayGate B: 连发丢弃 + 越阈放行",
              OverlayRefreshPolicy.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.29), minInterval: 0.3)
              && !OverlayRefreshPolicy.isDuplicateForceTrigger(lastTriggerAt: last, now: last.addingTimeInterval(0.31), minInterval: 0.3))

        // C. ScreenHotplugGuard 真身：集合相等语义 + 防御过滤。
        let u1 = UUID(), u2 = UUID(), u3 = UUID()
        check("overlayGate C: 热插拔集合相等（顺序无关）+ 插拔不一致",
              ScreenHotplugGuard.identityMatches(preUUIDs: [u1, u2], currentUUIDs: [u2, u1])
              && !ScreenHotplugGuard.identityMatches(preUUIDs: [u1], currentUUIDs: [u1, u2]))
        check("overlayGate C: filterStale 剔除失效条目",
              ScreenHotplugGuard.filterStale([(0, u1, 1, 1), (1, u3, 2, 3)], liveUUIDs: [u1]).count == 1)

        // D. SpaceSnapshot / AllSpaceSnapshot 解析真身（Bool/Int 双形态防御 + 缺字段跳过）。
        let mixed: [[String: Any]] = [
            ["index": 1, "display": 1, "is-visible": true, "has-focus": 1],
            ["index": 2, "display": 1, "is-visible": 0, "has-focus": 0],
            ["display": 2, "is-visible": true],                    // 缺 index → 跳过
            ["index": 3, "is-visible": true],                      // 缺 display → AllSpace 跳过
        ]
        let perScreen = SpaceSnapshot.parse(from: mixed)
        check("overlayGate D: SpaceSnapshot 双形态防御解析（缺 index 跳过）",
              perScreen.count == 3 && perScreen[0].isVisible && perScreen[1].hasFocus == false)
        let all = AllSpaceSnapshot.parse(from: mixed)
        check("overlayGate D: AllSpaceSnapshot 缺 display 跳过",
              all.count == 2 && all[1].display == 1)
        check("overlayGate D: parseJSONArray 形状不符 → nil / 合法数组解析",
              AllSpaceSnapshot.parseJSONArray(Data(#"{"a":1}"#.utf8)) == nil
              && AllSpaceSnapshot.parseJSONArray(Data(#"[{"index":1}]"#.utf8))?.count == 1)

        // E. resolveScreenSpaceIndex 真身：返回屏内位次（角标语言=「屏号-位次」，
        // 2026-09-09 用户裁定；屏号由 calculateOverlayLabel 用 yabai displayIndex 提供）。
        let spaces = [
            AllSpaceSnapshot(index: 3, display: 1, isVisible: false, hasFocus: false),
            AllSpaceSnapshot(index: 1, display: 1, isVisible: true, hasFocus: false),
            AllSpaceSnapshot(index: 2, display: 1, isVisible: true, hasFocus: true),
        ]
        check("overlayGate E: focused 命中 → 按升序位次（2）",
              AllSpaceSnapshot.resolveScreenSpaceIndex(from: spaces, focusedSpaceIndex: 2) == 2)
        check("overlayGate E: focused 属别屏 → 首个可见位次（1）",
              AllSpaceSnapshot.resolveScreenSpaceIndex(from: spaces, focusedSpaceIndex: 9) == 1)
        check("overlayGate E: 全不可见 → nil",
              AllSpaceSnapshot.resolveScreenSpaceIndex(
                from: [AllSpaceSnapshot(index: 2, display: 1, isVisible: false, hasFocus: false)],
                focusedSpaceIndex: nil) == nil)

        // E2. screenCacheChange 真身：三元组任一变化 → 需重绘；yabai 屏号纳入比较
        // （插拔后 yabai 重排而 NSScreen 序未变时，角标屏号也必须更新）。
        check("overlayGate E2: 缓存缺失（新屏）→ 重绘且无旧值",
              ScreenOverlayManager.screenCacheChange(cached: nil, currentScreenIndex: 0,
                                                     currentYabaiDisplayIndex: 3, currentSpaceIndex: 4)
              .needsApply)
        check("overlayGate E2: 三元组全同 → 不触碰 overlay",
              !ScreenOverlayManager.screenCacheChange(
                cached: (screenIndex: 1, yabaiDisplayIndex: 3, spaceIndex: 4),
                currentScreenIndex: 1, currentYabaiDisplayIndex: 3, currentSpaceIndex: 4).needsApply)
        check("overlayGate E2: 仅 space 变 → 重绘并携带旧 space 号",
              ScreenOverlayManager.screenCacheChange(
                cached: (screenIndex: 1, yabaiDisplayIndex: 3, spaceIndex: 4),
                currentScreenIndex: 1, currentYabaiDisplayIndex: 3, currentSpaceIndex: 5)
              == .init(needsApply: true, oldSpaceIndex: 4))
        check("overlayGate E2: 仅 yabai 屏号变（NSScreen 序未变）→ 重绘",
              ScreenOverlayManager.screenCacheChange(
                cached: (screenIndex: 1, yabaiDisplayIndex: 3, spaceIndex: 4),
                currentScreenIndex: 1, currentYabaiDisplayIndex: 2, currentSpaceIndex: 4).needsApply)
        check("overlayGate E2: yabai 屏号由 nil 转正（首轮解析完成）→ 重绘",
              ScreenOverlayManager.screenCacheChange(
                cached: (screenIndex: 1, yabaiDisplayIndex: nil, spaceIndex: 4),
                currentScreenIndex: 1, currentYabaiDisplayIndex: 3, currentSpaceIndex: 4).needsApply)
    }

    // MARK: SessionWindowRegistry 查找级联（真实实现 + 隔离 DB——B10：绑定查找唯一事实源）
    // 仅 VIBEFOCUS_REGISTRY_E2E=1 时运行（须配 VIBEFOCUS_DB_PATH 隔离库；E2E 互斥锁自动生效）。

    if ProcessInfo.processInfo.environment["VIBEFOCUS_REGISTRY_E2E"] == "1" {
        let registry = SessionWindowRegistry.shared
        // 取一个真实终端 app 的 pid（查找级联按「pid 仍是终端进程」判有效）
        let terminalPID = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.googlecode.iterm2" || $0.bundleIdentifier == "com.apple.Terminal" }?
            .processIdentifier ?? ProcessInfo.processInfo.processIdentifier

        func state(_ wid: UInt32, pid: Int32, session: String?) -> WindowState {
            let ws = WindowState(
                windowID: wid, pid: pid, tty: nil,
                axWindowNumber: nil, appName: "TestTerminal", bundleIdentifier: nil, title: nil,
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                envWindowID: nil, sessionID: session, cwd: nil, model: nil,
                isCompleted: false, createdAt: Date(), updatedAt: Date()
            )
            return ws
        }

        // 直命中：sessionID 精确匹配
        registry.windowStates[9001] = state(9001, pid: terminalPID, session: "sess-A")
        check("registry: 直命中 sessionID", registry.binding(for: "sess-A")?.windowID == 9001)

        // 有效 pid 优先：同 session 两条（一条 pid 已死），返回 pid 有效者
        registry.windowStates[9002] = state(9002, pid: 999_999_999, session: "sess-B")
        registry.windowStates[9003] = state(9003, pid: terminalPID, session: "sess-B")
        check("registry: 同会话多绑定优先 pid 有效者", registry.binding(for: "sess-B")?.windowID == 9003)

        // 别名通道：主表无、别名表有
        registry.sessionAliasWindowID["alias-sess"] = 9001
        check("registry: 别名通道命中", registry.binding(for: "alias-sess")?.windowID == 9001)

        // 未注册会话 → nil
        check("registry: 未注册会话 → nil", registry.binding(for: "nope") == nil)

        // markCompleted 联动（State 扩展唯一入口）
        registry.markCompleted(sessionID: "sess-A")
        check("registry: markCompleted 后绑定仍可查",
              registry.binding(for: "sess-A")?.windowID == 9001)

        // 清理：markCompleted 已持久化，仅删内存不够——查找级联第三层是 DB 兜底
        // （findWindowStateBySession），隔离库行须一并删除（本轮实测验证了该层真实存在）。
        registry.windowStates.removeValue(forKey: 9001)
        registry.windowStates.removeValue(forKey: 9002)
        registry.windowStates.removeValue(forKey: 9003)
        registry.sessionAliasWindowID.removeValue(forKey: "alias-sess")
        for wid in [UInt32(9001), 9002, 9003] {
            WindowStateStore.shared.deleteWindowState(windowID: wid)
        }
        check("registry: 内存+DB 双清后 → nil", registry.binding(for: "sess-A") == nil)

        // ===== B24：状态操作语义（markCompleted/reactivate/remap/clearAll）=====
        func mkState(_ wid: UInt32, session: String?) -> WindowState {
            let ws = WindowState(
                windowID: wid, pid: terminalPID, tty: nil,
                axWindowNumber: nil, appName: "TestTerminal", bundleIdentifier: nil, title: nil,
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                envWindowID: nil, sessionID: session, cwd: nil, model: nil,
                isCompleted: false, createdAt: Date(), updatedAt: Date()
            )
            return ws
        }
        registry.windowStates[9101] = mkState(9101, session: "b24-complete")
        registry.markCompleted(sessionID: "b24-complete")
        check("b24 state: markCompleted 置位", registry.windowStates[9101]?.isCompleted == true)
        check("b24 state: markCompleted 清别名",
              registry.sessionAliasWindowID.values.contains(9101) == false)

        registry.windowStates[9102] = mkState(9102, session: "b24-react")
        registry.markCompleted(sessionID: "b24-react")
        registry.reactivate(sessionID: "b24-react")
        check("b24 state: reactivate 复位", registry.windowStates[9102]?.isCompleted == false)

        let beforeTouch = registry.windowStates[9101]?.updatedAt
        registry.touch(sessionID: "b24-complete", message: "touched")
        check("b24 state: touch 推进 updatedAt + 记录消息",
              registry.windowStates[9101]!.updatedAt > (beforeTouch ?? .distantPast)
              && registry.lastEventDescription == "touched")

        registry.setLastEventDescription("   ")
        check("b24 state: 空白消息不覆盖 lastEventDescription",
              registry.lastEventDescription == "touched")

        registry.windowStates[9103] = mkState(9103, session: "b24-remap")
        registry.remapWindowID(oldWindowID: 9103, newWindowID: 9104)
        check("b24 state: remap 迁移绑定到新 windowID",
              registry.windowStates[9103] == nil && registry.windowStates[9104]?.sessionID == "b24-remap")

        registry.clearAllBindings()
        check("b24 state: clearAllBindings 清空内存",
              registry.windowStates.isEmpty && registry.sessionAliasWindowID.isEmpty)
        // 隔离库兜底清理（clearAllBindings 已清 DB 全表）
        check("b24 cleanup: 注册表已清空", registry.windowStates.isEmpty)
    }

    // MARK: 恢复命令组装与 shell 转义（真实实现——B25：cellCommand 分支穷尽）

    do {
        // cellCommand 分支已由并行会话直测覆盖（本文件 1385-1387），此处只补 shellQuoted 转义
        let q: Character = "\u{27}"
        let escapedSegment = String(q) + "\\" + String(q) + String(q)   // '\'' 四字符
        let expected = String(q) + "my " + escapedSegment + "proj" + escapedSegment + String(q)
        check("shellQuoted: 单引号转义惯用法",
              TerminalAutomationScript.shellQuoted("my 'proj'") == expected)
        check("shellQuoted: 无单引号原样包裹",
              TerminalAutomationScript.shellQuoted("plain") == "'plain'")
        check("shellQuoted: 空串 → ''", TerminalAutomationScript.shellQuoted("") == "''")
    }

    // MARK: LAN 远程绑定持久化（真实实现——B22：JSON 新格式/旧字典迁移/nil 过滤三层语义）
    // Runner 进程的 UserDefaults.standard 是独立域（无 bundle id），与真机应用偏好隔离。

    if ProcessInfo.processInfo.environment["VIBEFOCUS_REGISTRY_E2E"] == "1" {
        let key = "remoteBindings"
        // 起点：显式重置（Runner 域偏好跨进程持久化，不能假设为空——实测教训）

        // set：写入时 compactMapValues 丢弃 nil（已添加未选窗的表示是瞬态）
        LANHookPreferences.remoteBindings = ["m1": 100, "m2": nil]
        let afterSet = LANHookPreferences.remoteBindings
        check("lan: set 后 nil 条目不落盘", afterSet["m1"] == UInt32(100) && afterSet["m2"] == nil)

        // activeRemoteBindings 过滤 nil
        check("lan: activeRemoteBindings 仅含非空", LANHookPreferences.activeRemoteBindings == ["m1": 100])

        // 旧格式迁移分支不在本进程内测：同进程混合 set/字典塞入受 UserDefaults 缓存
        // 与 cfprefsd 写读一致性影响（实测不稳定），该路径由 Standalone/LANBindingTests
        // 镜像 + 真机验证覆盖。
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: 终端上下文匹配族 + Claude 窗口定位（真实实现——B11：镜像转直测）

    do {
        // fullDevicePath / normalizeTTY
        check("tty: fullDevicePath 补前缀", WindowManager.fullDevicePath("ttys003") == "/dev/ttys003")
        check("tty: fullDevicePath 已带前缀原样", WindowManager.fullDevicePath("/dev/ttys003") == "/dev/ttys003")
        check("tty: normalize nil/空/not-a-tty → nil",
              WindowManager.normalizeTTY(nil) == nil
              && WindowManager.normalizeTTY("") == nil
              && WindowManager.normalizeTTY("not a tty") == nil)
        check("tty: normalize 正常补全", WindowManager.normalizeTTY("ttys009") == "/dev/ttys009")

        // matchCommandToWindowTitle：倒序命令优先 + em-dash contains + 大小写
        let wins = [
            WindowIdentity(windowID: 1, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 1, title: "user — Zsh"),
            WindowIdentity(windowID: 2, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 2, title: "repo — claude"),
        ]
        check("cmdMatch: 命中 em-dash 标题",
              WindowManager.matchCommandToWindowTitle(commands: ["claude"], windows: wins)?.windowID == 2)
        check("cmdMatch: 倒序遍历（后者优先）",
              WindowManager.matchCommandToWindowTitle(commands: ["zsh", "claude"], windows: wins)?.windowID == 2)
        check("cmdMatch: 大小写敏感命令不命中小写标题",
              WindowManager.matchCommandToWindowTitle(commands: ["CLAUDE"], windows: wins) == nil)

        // parseCommandBasename：路径取 basename、空行跳过
        let basenames = WindowManager.parseCommandBasename(from: "/usr/bin/claude\n\n  /opt/homebrew/bin/nvim ")
        check("cmdBasename: 取末段 + 空行跳过", basenames == ["claude", "nvim"])

        // parseItermSessionUUID / UUID / TTY 校验（注入防御 allowlist）
        check("itermUUID: 冒号后取段", WindowManager.parseItermSessionUUID("iTerm:ABC-123") == "ABC-123")
        check("itermUUID: 无冒号原样", WindowManager.parseItermSessionUUID("ABC") == "ABC")
        check("itermUUID: 冒号后空 → nil", WindowManager.parseItermSessionUUID("iTerm:") == nil)
        check("uuidAllow: hex+连字符通过", WindowManager.isValidUUIDPart("ABC-def-0123"))
        check("uuidAllow: 元字符拒绝", !WindowManager.isValidUUIDPart("abc\"; rm"))
        check("ttyAllow: /dev/ttys### 通过", WindowManager.isValidTTYPath("/dev/ttys004"))
        check("ttyAllow: /dev/pty### 通过", WindowManager.isValidTTYPath("/dev/pty3"))
        check("ttyAllow: 非设备路径拒绝", !WindowManager.isValidTTYPath("/dev/tty; rm -rf"))

        // Claude 窗口定位：两级策略
        typealias Cand = WindowManager.WindowCandidate
        let candidates = [
            Cand(windowID: 11, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "proj — zsh"),
            Cand(windowID: 12, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "Claude Code — proj"),
        ]
        let isHost: (Cand) -> Bool = { $0.appName == "iTerm2" }
        let m1 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "proj", isHostApp: isHost)
        check("claudeMatch: 策略1 项目名命中前者",
              m1?.strategy == .hostAppProjectName && m1?.candidate.windowID == 11)
        let m2 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: nil, isHostApp: isHost)
        check("claudeMatch: 策略2 无项目名回落标题", m2?.strategy == .hostAppClaudeCodeTitle && m2?.candidate.windowID == 12)
        let m3 = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "nomatch", isHostApp: isHost)
        check("claudeMatch: 项目名未命中回落策略2", m3?.strategy == .hostAppClaudeCodeTitle && m3?.candidate.windowID == 12)
        let noHost = WindowManager.matchClaudeCodeCandidate(candidates, projectName: "proj", isHostApp: { _ in false })
        check("claudeMatch: 无 hostApp 候选 → nil", noHost == nil)
    }

    // MARK: 编排目标与终端选择解析（真实实现——B12：GridTargetCode.parse / TerminalSelectionResolver.resolve 直测）

    do {
        // GridTargetCode.parse：全形态 + 非法输入
        check("gridParse: main/focused", GridTargetCode.parse("main") == .main && GridTargetCode.parse("focused") == .focused)
        check("gridParse: 纯 display", GridTargetCode.parse("d42") == .display(displayID: 42))
        check("gridParse: display+space", GridTargetCode.parse("d7s3") == .displaySpace(displayID: 7, spaceIndex: 3))
        check("gridParse: 非法形态 → nil",
              GridTargetCode.parse(nil) == nil && GridTargetCode.parse("") == nil
              && GridTargetCode.parse("x1") == nil && GridTargetCode.parse("dx") == nil)
        check("gridParse: space 非法（0/非数字）→ nil",
              GridTargetCode.parse("d7s0") == nil && GridTargetCode.parse("d7sx") == nil)
        check("gridParse: display 非数字 → nil", GridTargetCode.parse("d-1") == nil)

        // TerminalSelectionResolver.resolve：手动优先 / auto 运行优先 / fallback
        func candidate(_ bundleID: String, running: Bool, count: Int) -> TerminalSelectionCandidate {
            TerminalSelectionCandidate(
                bundleID: bundleID, name: bundleID, support: .full,
                usageCount: count, lastUsedAt: nil, isRunning: running
            )
        }
        let cands = [candidate("com.apple.Terminal", running: false, count: 3),
                     candidate("com.googlecode.iterm2", running: true, count: 9)]
        let manual = TerminalSelectionResolver.resolve(manualBundleID: "com.apple.Terminal", candidates: cands)
        check("selection: 手动指定优先", manual.bundleID == "com.apple.Terminal")
        let auto = TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: cands)
        check("selection: auto 按使用频次排序取最常用", auto.bundleID == "com.googlecode.iterm2")
        let empty = TerminalSelectionResolver.resolve(manualBundleID: nil, candidates: [])
        check("selection: 无候选回落 Terminal.app", empty.bundleID == "com.apple.Terminal")
    }

    // MARK: float 脱管/恢复链路纯决策（真实实现——B13：FloatToggle/RestoreGuard/RefocusCandidate 镜像转直测）

    do {
        // floatToggleDecision：决策序 disabled → query_nil → already_floating → unmanaged → toggled
        func info(float: Bool, ax: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(id: 7, pid: 100, app: "T", title: "t", space: 1, display: 1,
                            frame: nil, isFloatingRaw: float, hasAXReferenceRaw: ax,
                            isMinimizedRaw: false, hasFocusRaw: false)
        }
        var lazyTouched = false
        let disabled = SpaceController.floatToggleDecision(isEnabled: false, info: { lazyTouched = true; return info(float: false, ax: true) }())
        check("floatToggle: disabled → skip 且惰性不触查询",
              disabled.outcome == .skippedNoOp && disabled.skipReason == "disabled" && !lazyTouched)
        check("floatToggle: 查询 nil → query_nil",
              SpaceController.floatToggleDecision(isEnabled: true, info: { nil }()).skipReason == "query_nil")
        check("floatToggle: 已 float → already_floating",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: true, ax: true) }()).skipReason == "already_floating")
        check("floatToggle: 无 AX 引用 → unmanaged",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: false, ax: false) }()).skipReason == "unmanaged")
        check("floatToggle: 可脱管 → toggled",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: false, ax: true) }()).outcome == .toggled)

        // selectRefocusCandidate：space/可管理/排除过滤 + 非最小化优先
        func win(_ id: Int, space: Int, ax: Bool, minimized: Bool) -> YabaiWindowInfo {
            YabaiWindowInfo(id: id, pid: 100, app: "T", title: "w\(id)", space: space, display: 1,
                            frame: nil, isFloatingRaw: false, hasAXReferenceRaw: ax,
                            isMinimizedRaw: minimized, hasFocusRaw: false)
        }
        let wins = [win(1, space: 5, ax: true, minimized: false),
                    win(2, space: 4, ax: true, minimized: false),
                    win(3, space: 5, ax: true, minimized: true),
                    win(4, space: 5, ax: false, minimized: false)]
        check("refocus: 过滤 space/可管理，非最小化优先",
              SpaceController.selectRefocusCandidate(windows: wins, spaceIndex: 5, excludingWindowID: nil)?.id == 1)
        check("refocus: 排除窗不入选",
              SpaceController.selectRefocusCandidate(windows: wins, spaceIndex: 5, excludingWindowID: 1)?.id == 3)
        check("refocus: 全最小化回落首个可管理",
              SpaceController.selectRefocusCandidate(
                windows: [win(3, space: 5, ax: true, minimized: true), win(6, space: 5, ax: true, minimized: true)],
                spaceIndex: 5, excludingWindowID: nil)?.id == 3)

        // RestoreOutcome.outcomeLabel：四分支机器可读标签
        check("outcomeLabel: restored(spaceExact=nil)",
              ToggleEngine.RestoreOutcome.restored(spaceExact: nil).outcomeLabel == "restored(spaceExact=nil)")
        check("outcomeLabel: aborted_reason",
              ToggleEngine.RestoreOutcome.aborted(reason: "no_window").outcomeLabel == "aborted_no_window")
        check("outcomeLabel: 可重试标签",
              ToggleEngine.RestoreOutcome.moveFailedRetryable.outcomeLabel == "move_failed_retryable_record_kept")
        check("outcomeLabel: 永久失败标签",
              ToggleEngine.RestoreOutcome.moveFailedPermanent.outcomeLabel == "move_failed_permanent_record_cleared")

        // isMoveFailureRetryable：origFrame 在屏与否
        check("retryable: 在屏 → 保留 record", ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: true))
        check("retryable: 不在任何屏 → 清除 record", !ToggleEngine.isMoveFailureRetryable(origFrameOnAnyDisplay: false))

        // sourceSpacePreSwitch：三态决策
        check("preSwitch: 无上下文（0 值）→ noContext",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 0, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 5) == .noContext)
        check("preSwitch: 可见性查询失败 → notNeeded（不盲切）",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: nil) == .notNeeded)
        check("preSwitch: 已在源 space → notNeeded",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: 5) == .notNeeded)
        check("preSwitch: 停在别 space → switchNeeded",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 1, visibleSpaceOnSourceDisplay: 2)
              == .switchNeeded(visibleSpace: 2))
    }

    // MARK: restore 结局播报映射（真实实现——B14：outcome→plan 总映射 + 文案/通道语义）

    do {
        // restored(spaceExact) 三态映射
        check("announce: spaceExact=nil → restoredExact",
              ToggleEngine.RestoreOutcome.restored(spaceExact: nil).restoreAnnouncementPlan == .restoredExact)
        check("announce: spaceExact=true → restoredExact",
              ToggleEngine.RestoreOutcome.restored(spaceExact: true).restoreAnnouncementPlan == .restoredExact)
        check("announce: spaceExact=false → restoredDegraded",
              ToggleEngine.RestoreOutcome.restored(spaceExact: false).restoreAnnouncementPlan == .restoredDegraded)
        check("announce: retryable → failedRetryable",
              ToggleEngine.RestoreOutcome.moveFailedRetryable.restoreAnnouncementPlan == .failedRetryable)
        check("announce: permanent → failedPermanent",
              ToggleEngine.RestoreOutcome.moveFailedPermanent.restoreAnnouncementPlan == .failedPermanent)
        check("announce: aborted → silent",
              ToggleEngine.RestoreOutcome.aborted(reason: "no_window").restoreAnnouncementPlan == .silent)

        // 文案 nil 语义（silent 不播报）+ 成败通道
        check("announce: silent 文案为 nil", RestoreAnnouncementPlan.silent.text == nil)
        check("announce: degraded 文案指向工作区不可达",
              RestoreAnnouncementPlan.restoredDegraded.text?.contains("不可达") == true)
        check("announce: 成功/降级/静默走完成通道",
              RestoreAnnouncementPlan.restoredExact.isSuccessful
              && RestoreAnnouncementPlan.restoredDegraded.isSuccessful
              && RestoreAnnouncementPlan.silent.isSuccessful)
        check("announce: 两类失败走失败音效（Basso）",
              !RestoreAnnouncementPlan.failedRetryable.isSuccessful
              && !RestoreAnnouncementPlan.failedPermanent.isSuccessful)
    }

    // MARK: 坐标换算与移动冷却（真实实现——B15：Quartz/Cocoa 互转 + 冷却纯决策）

    do {
        // Quartz ↔ Cocoa y 互转（主屏高度 = 两侧和恒等）
        check("coord: quartzY = primaryMaxY - appKitMaxY",
              CoordinateKit.quartzY(appKitRectMaxY: 300, primaryMaxY: 1117) == 817)
        check("coord: cocoaY/fromQuartzY 互逆",
              CoordinateKit.cocoaY(fromQuartzY: 500) == CoordinateKit.mainScreenHeight - 500
              && CoordinateKit.quartzY(fromCocoaY: CoordinateKit.mainScreenHeight - 500) == 500)

        // MoveCooldownRegistry：静态纯决策
        let now = Date()
        check("cooldown: 从未移动 → 不在冷却",
              !MoveCooldownRegistry.isInCooldown(lastMove: nil, now: now, cooldownSeconds: 3))
        check("cooldown: 2s 前 < 3s → 冷却中",
              MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-2), now: now, cooldownSeconds: 3))
        check("cooldown: 4s 前 > 3s → 冷却结束",
              !MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-4), now: now, cooldownSeconds: 3))
        check("cooldown: remainingSeconds 无记录 → 0（无冷却需求）",
              MoveCooldownRegistry.remainingSeconds(lastMove: nil, now: now, cooldownSeconds: 3) == 0)
        check("cooldown: remainingSeconds 边界取整向上",
              MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-2.2), now: now, cooldownSeconds: 3) == 1)
        check("cooldown: 冷却结束 remaining 归零",
              MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-5), now: now, cooldownSeconds: 3) == 0)
    }

    // MARK: WindowStateStore 记录持久层（真实 SQLite——老库 PK 迁移/KV 往返，Batch 13）

    do {
        // 迁移是「老用户首次启动新版本」才跑的代码，此前 0 覆盖。
        // 夹具：sqlite3 CLI 预建旧 schema（PK=(pid,tty)，允许 window_id 重复）+ 种子行；
        // init 触发 migrateWindowsPKIfNeeded → 断言新 PK + 去重保留 + 数据完整。
        func cli(_ sql: String, _ db: String) -> String? {
            ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [db, sql], timeout: 30)?.stdout
        }
        let dir = "/tmp/vibefocus-dbtest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dbPath = dir + "/old.db"
        let oldSchema = """
            CREATE TABLE windows (
                window_id INTEGER, pid INTEGER NOT NULL, tty TEXT NOT NULL DEFAULT '',
                ax_window_number INTEGER, app_name TEXT, bundle_id TEXT, title TEXT,
                term_session_id TEXT, iterm_session_id TEXT, kitty_window_id TEXT,
                wezterm_pane TEXT, env_window_id TEXT, session_id TEXT, cwd TEXT, model TEXT,
                orig_x REAL, orig_y REAL, orig_w REAL, orig_h REAL,
                target_x REAL, target_y REAL, target_w REAL, target_h REAL,
                source_space INTEGER, source_display INTEGER, source_yabai_disp INTEGER,
                source_disp_space INTEGER, target_display INTEGER, toggle_reason TEXT,
                toggled_at REAL, is_completed INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, completed_at REAL,
                PRIMARY KEY(pid, tty)
            );
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (1, 100, '/dev/ttys001', 'sess-A', '/tmp/a', 100.0, 100.0);
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (1, 200, '/dev/ttys002', 'sess-B', '/tmp/b', 100.0, 100.0);
            INSERT INTO windows (window_id, pid, tty, session_id, cwd, created_at, updated_at)
                VALUES (2, 300, '/dev/ttys003', 'sess-C', '/tmp/c', 100.0, 100.0);
            """
        _ = ShellRunner.run(executable: "/usr/bin/sqlite3", arguments: [dbPath, oldSchema], timeout: 30)

        // A. init 触发迁移：老 PK=(pid,tty) → 新 PK=(window_id)。
        let storeA = WindowStateStore(dbPath: dbPath)
        _ = storeA
        let pkInfo = cli("PRAGMA table_info(windows);", dbPath) ?? ""
        // 按 PRAGMA 行解析：每行末字段为 pk 标志，恰一行（window_id）pk=1。
        let pkLines = pkInfo.split(separator: "\n").filter { !$0.isEmpty && $0.split(separator: "|").last == "1" }
        check("store A: 迁移后 PK 恰为 window_id 一列",
              pkLines.count == 1 && pkLines[0].contains("window_id"))
        let count = cli("SELECT COUNT(*) FROM windows;", dbPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("store A: INSERT OR IGNORE 去重（同 window_id 双行留一，共 2 行）", count == "2")
        let sessA = cli("SELECT session_id FROM windows WHERE window_id=1 AND pid=100;", dbPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check("store A: 数据完整（pid=100 行的 session_id 保留）", sessA == "sess-A")
        let idx = cli("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='windows';", dbPath) ?? ""
        check("store A: 迁移后重建三索引",
              idx.contains("idx_windows_session_id") && idx.contains("idx_windows_pid_tty") && idx.contains("idx_windows_last_seen"))

        // B. 新库免迁移：fresh 路径直接是新 PK。
        let freshPath = dir + "/fresh.db"
        _ = WindowStateStore(dbPath: freshPath)
        let freshPK = cli("PRAGMA table_info(windows);", freshPath) ?? ""
        check("store B: 新库直接是 window_id PK", freshPK.contains("window_id|INTEGER|1||1"))

        // C. preferences KV 往返：save→load→覆盖→missing nil。
        let storeC = WindowStateStore(dbPath: dir + "/prefs.db")
        storeC.savePreference(key: "gate", value: "v1")
        check("store C: save→load 往返", storeC.loadPreference(key: "gate") == "v1")
        storeC.savePreference(key: "gate", value: "v2")
        check("store C: 同 key 覆盖 upsert", storeC.loadPreference(key: "gate") == "v2")
        check("store C: 缺失 key → nil", storeC.loadPreference(key: "nope") == nil)

        try? FileManager.default.removeItem(atPath: dir)
    }
    }
}
