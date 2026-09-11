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
        // 门序锁（B80：OverlayRefreshPolicyTests 镜像退役，缺口语义转真身）：
        // suspend 判据先于 disabled——suspend+disabled+非force 走 skipSuspended 而非 skipDisabled。
        check("overlayGate A: 门序 suspend 先于 disabled（suspend+disabled+非force → skipSuspended）",
              OverlayRefreshPolicy.refreshGate(suspended: true, enabled: false, force: false) == .skipSuspended)
        // 启动首次：lastTriggerAt = distantPast → 不算重复，放行。
        check("overlayGate B: lastTriggerAt=distantPast → 放行（启动首次）",
              !OverlayRefreshPolicy.isDuplicateForceTrigger(
                lastTriggerAt: .distantPast, now: Date(timeIntervalSince1970: 1000), minInterval: 0.3))

        // B2. forceRefreshDecision 四象限（2026-09-11 停格修复的契约锁）：
        // 挂起闸门只准吞 overlay 重活，不准吞 space-state 广播——设置窗持焦期间
        // SIGUSR1/toggle 变化必须以 broadcastOnly 形态到达编排页 minimap。
        check("overlayGate B2: 常态非重复 → broadcastAndRefresh（广播+重刷）",
              OverlayRefreshPolicy.forceRefreshDecision(suspended: false, duplicate: false) == .broadcastAndRefresh)
        check("overlayGate B2: 常态连发重复 → skipDuplicate（历史语义不回退）",
              OverlayRefreshPolicy.forceRefreshDecision(suspended: false, duplicate: true) == .skipDuplicate)
        check("overlayGate B2: 挂起非重复 → broadcastOnly（广播不吞，重活跳过）",
              OverlayRefreshPolicy.forceRefreshDecision(suspended: true, duplicate: false) == .broadcastOnly)
        check("overlayGate B2: 挂起连发重复 → broadcastOnly（挂起时不去重，minimap 不许停格）",
              OverlayRefreshPolicy.forceRefreshDecision(suspended: true, duplicate: true) == .broadcastOnly)

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

        // 旧格式迁移解析（B83：parseLegacyBindings 静态缝提纯——逻辑原内联在 getter 迁移分支，
        // Standalone/LANBindingTests 镜像退役。UserDefaults 端到端迁移写回受 cfprefsd 缓存
        // 与写读一致性影响（实测不稳定），归真机验证；纯解析在此直锁）。
        check("lan: legacy 解析 Int/UInt32 双形态、垃圾值跳过、空字典 → 空",
              LANHookPreferences.parseLegacyBindings(from: ["a": UInt32(7), "b": 9, "c": "garbage"])
              == ["a": Optional(UInt32(7)), "b": Optional(UInt32(9))]
              && LANHookPreferences.parseLegacyBindings(from: [:]).isEmpty)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: WindowSettle 时长表（真实实现——B83：WindowSettleTimingTests 镜像退役）
    // 镜像锁的旧时序模型（固定 400ms yabai 档）已被轮询制取代（25ms 节拍+400ms 预算），
    // 属重度漂移——本块锁现行表：基准值 + 两级（yabai 级数百 ms / WindowServer 级数十 ms）关系不变量。

    do {
        check("settle: 基准值锁定（float 重摆预算 300ms/下限 120ms、frame 验证轮询 25ms+预算 400ms、AX 节拍 25ms、MC 150ms）",
              WindowSettle.floatRelayoutSettleMicros == 300_000
              && WindowSettle.floatRelayoutMinSettleMicros == 120_000
              && WindowSettle.frameVerifyPollIntervalMs == 25
              && WindowSettle.frameVerifyBudgetMs == 400
              && WindowSettle.axWriteSettleMicros == 25_000
              && WindowSettle.missionControlDismissSettleMicros == 150_000)
        check("settle: 等到位族锁定（条件轮询 50ms/space 切回预算 800ms/段间预算 300ms）",
              WindowSettle.conditionPollIntervalMs == 50
              && WindowSettle.spaceSwitchWaitBudgetMs == 800
              && WindowSettle.framePhaseVerifyBudgetMs == 300)
        check("settle: 两级关系不变量——重摆下限 ≤ 预算、轮询节拍 ≤ 50ms、全部预算 ≤ 1s（用户可感知路径）",
              WindowSettle.floatRelayoutMinSettleMicros <= WindowSettle.floatRelayoutSettleMicros
              && WindowSettle.frameVerifyPollIntervalMs <= 50
              && WindowSettle.conditionPollIntervalMs <= 50
              && max(WindowSettle.frameVerifyBudgetMs,
                     max(WindowSettle.spaceSwitchWaitBudgetMs, WindowSettle.framePhaseVerifyBudgetMs)) <= 1_000)
    }

    // MARK: LAN IP 选择（真实实现——B73：en0 硬编码修为 en0 优先/enX 次之/虚拟口排除）

    do {
        func ip(_ interface: String, _ address: String) -> (interface: String, ip: String) {
            (interface, address)
        }
        check("lanIP: en0 最优先（多候选时选 en0）",
              LANHookPreferences.selectLANIP(from: [
                ip("en1", "192.168.1.50"), ip("en0", "192.168.1.12"), ip("utun4", "198.18.0.1"),
              ]) == "192.168.1.12")
        check("lanIP: 无 en0 → 首个其它 enX",
              LANHookPreferences.selectLANIP(from: [
                ip("en5", "192.168.7.7"), ip("en1", "192.168.1.50"),
              ]) == "192.168.7.7")
        check("lanIP: utun/awdl/loopback 不参与",
              LANHookPreferences.selectLANIP(from: [
                ip("utun4", "198.18.0.1"), ip("awdl0", "169.254.5.6"), ip("lo0", "127.0.0.1"),
              ]) == nil)
        check("lanIP: en 口上的 loopback 地址也排除",
              LANHookPreferences.selectLANIP(from: [ip("en0", "127.0.0.1")]) == nil)
        check("lanIP: 空候选 → nil",
              LANHookPreferences.selectLANIP(from: []) == nil)
        check("lanIP: 只有虚拟口无 enX → nil（调用方回退 127.0.0.1）",
              LANHookPreferences.selectLANIP(from: [ip("bridge0", "10.0.0.1")]) == nil)
    }

    // MARK: 对外可达地址候选序（B170——远程转发器多候选试连的排序事实源）

    do {
        func ip(_ interface: String, _ address: String) -> (interface: String, ip: String) {
            (interface, address)
        }
        check("addrCandidates: en0 → 其它 enX → 虚拟口殿后",
              LANHookPreferences.orderedAddressCandidates(from: [
                ip("utun5", "10.9.0.2"), ip("en1", "192.168.7.7"), ip("en0", "192.168.3.37"),
              ]) == ["192.168.3.37", "192.168.7.7", "10.9.0.2"])
        check("addrCandidates: loopback/链路本地/198.18/0.0 全排除",
              LANHookPreferences.orderedAddressCandidates(from: [
                ip("en0", "127.0.0.1"), ip("en1", "169.254.1.2"),
                ip("utun4", "198.18.0.1"), ip("bridge0", "0.0.0.0"), ip("en2", "192.168.1.12"),
              ]) == ["192.168.1.12"])
        check("addrCandidates: 同 IP 多网卡条目去重保首序",
              LANHookPreferences.orderedAddressCandidates(from: [
                ip("en0", "192.168.3.37"), ip("en0", "192.168.3.37"), ip("utun5", "10.9.0.2"),
              ]) == ["192.168.3.37", "10.9.0.2"])
        check("addrCandidates: 全被排除 → 空数组",
              LANHookPreferences.orderedAddressCandidates(from: [ip("lo0", "127.0.0.1")]) == [])
        check("addrCandidates: 空候选 → 空数组",
              LANHookPreferences.orderedAddressCandidates(from: []) == [])
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
        // 精确匹配怪癖锁（B83：TTYNormalizationTests 镜像退役）——尾随空格不是 "not a tty" 精确串
        check("tty: 'not a tty '（尾随空格）按路径补全而非拒绝",
              WindowManager.normalizeTTY("not a tty ") == "/dev/not a tty ")

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
        // 边界怪癖锁（B84：TerminalContextMatchingTests 镜像退役）
        check("cmdMatch: ◂ 前台标记标题仍命中（子串包含）、普通连字符不命中（分隔符必须 em dash）、标题侧大小写不敏感",
              WindowManager.matchCommandToWindowTitle(
                commands: ["vim"], windows: [WindowIdentity(windowID: 3, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 3, title: "notes ◂ — vim")])?.windowID == 3
              && WindowManager.matchCommandToWindowTitle(
                commands: ["vim"], windows: [WindowIdentity(windowID: 4, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 4, title: "notes - vim")]) == nil
              && WindowManager.matchCommandToWindowTitle(
                commands: ["vim"], windows: [WindowIdentity(windowID: 5, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 5, title: "REPO — VIM")])?.windowID == 5)
        check("cmdMatch: 空命令表 → nil；标题 nil 不命中",
              WindowManager.matchCommandToWindowTitle(commands: ["claude"], windows: []) == nil
              && WindowManager.matchCommandToWindowTitle(
                commands: ["claude"], windows: [WindowIdentity(windowID: 6, pid: 100, bundleIdentifier: nil, appName: "T", windowNumber: 6, title: nil)]) == nil)

        // parseCommandBasename：路径取 basename、空行跳过
        let basenames = WindowManager.parseCommandBasename(from: "/usr/bin/claude\n\n  /opt/homebrew/bin/nvim ")
        check("cmdBasename: 取末段 + 空行跳过", basenames == ["claude", "nvim"])

        // parseItermSessionUUID / UUID / TTY 校验（注入防御 allowlist）
        check("itermUUID: 冒号后取段", WindowManager.parseItermSessionUUID("iTerm:ABC-123") == "ABC-123")
        check("itermUUID: 无冒号原样", WindowManager.parseItermSessionUUID("ABC") == "ABC")
        check("itermUUID: 冒号后空 → nil", WindowManager.parseItermSessionUUID("iTerm:") == nil)
        check("itermUUID: 多冒号按首个切分（UUID 段可含冒号）", WindowManager.parseItermSessionUUID("iTerm:AB:CD") == "AB:CD")
        check("uuidAllow: hex+连字符通过", WindowManager.isValidUUIDPart("ABC-def-0123"))
        check("uuidAllow: 元字符拒绝", !WindowManager.isValidUUIDPart("abc\"; rm"))
        check("uuidAllow: 空串恒真（allSatisfy 空集）+ 分号/空格/换行注入拒绝",
              WindowManager.isValidUUIDPart("")
              && !WindowManager.isValidUUIDPart("abc;def")
              && !WindowManager.isValidUUIDPart("abc def")
              && !WindowManager.isValidUUIDPart("abc\ndef"))
        check("ttyAllow: /dev/ttys### 通过", WindowManager.isValidTTYPath("/dev/ttys004"))
        check("ttyAllow: /dev/pty### 通过", WindowManager.isValidTTYPath("/dev/pty3"))
        check("ttyAllow: 非设备路径拒绝", !WindowManager.isValidTTYPath("/dev/tty; rm -rf"))
        check("ttyAllow: 边界怪癖（B84）——单数字通过、无编号 /dev/tty 拒、/dev/ttys 宽松通过、换行注入拒",
              WindowManager.isValidTTYPath("/dev/ttys3")
              && !WindowManager.isValidTTYPath("/dev/tty")
              && WindowManager.isValidTTYPath("/dev/ttys")
              && !WindowManager.isValidTTYPath("/dev/ttys004\n"))

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
        // 顺序/子串/注入语义补锁（B86：ClaudeCodeWindowMatchTests 镜像退役）
        let ordered = [
            Cand(windowID: 21, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "Claude Code"),
            Cand(windowID: 22, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "proj — zsh"),
        ]
        check("claudeMatch: 策略1 优先于策略2（claude 标题在前仍先查项目名命中 22）",
              WindowManager.matchClaudeCodeCandidate(ordered, projectName: "proj", isHostApp: isHost)?.candidate.windowID == 22)
        check("claudeMatch: projectName 空串跳过策略1、'claude-coded' 与 'claude code' 子串不命中",
              WindowManager.matchClaudeCodeCandidate(ordered, projectName: "", isHostApp: isHost)?.candidate.windowID == 21
              && WindowManager.matchClaudeCodeCandidate(
                [Cand(windowID: 23, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "claude-coded — zsh")],
                projectName: nil, isHostApp: isHost) == nil)
        check("claudeMatch: 多候选同中取首位、空候选 → nil、谓词注入生效",
              WindowManager.matchClaudeCodeCandidate(
                [Cand(windowID: 31, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "proj — a"),
                 Cand(windowID: 32, pid: 100, appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "proj — b")],
                projectName: "proj", isHostApp: isHost)?.candidate.windowID == 31
              && WindowManager.matchClaudeCodeCandidate([], projectName: "proj", isHostApp: isHost) == nil
              && WindowManager.matchClaudeCodeCandidate(
                [Cand(windowID: 33, pid: 100, appName: "Ghostty", bundleIdentifier: "io.ghostty", title: "claude code")],
                projectName: nil, isHostApp: { $0.appName == "Ghostty" })?.candidate.windowID == 33)
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
        // 守卫序锁（B81：FloatToggleDecisionTests 镜像退役，缺口语义转真身）：
        // 已 float 且不可管理 → already_floating（floating 检查先于 unmanaged）。
        check("floatToggle: 已 float 且无 AX 引用 → already_floating（floating 先于 unmanaged）",
              SpaceController.floatToggleDecision(isEnabled: true, info: { info(float: true, ax: false) }()).skipReason == "already_floating")

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
        // 缺口语义锁（B81：RestoreRefocusCandidateTests 镜像退役）：
        // minimized 字段缺失（旧版 yabai）按未最小化参与排序；
        // 目标 space 无可管理窗口 → nil（不跨屏聚焦）。
        check("refocus: minimized 缺失按未最小化",
              SpaceController.selectRefocusCandidate(
                windows: [YabaiWindowInfo(id: 8, pid: 100, app: "T", title: "w8", space: 5, display: 1,
                                          frame: nil, isFloatingRaw: false, hasAXReferenceRaw: true,
                                          isMinimizedRaw: nil, hasFocusRaw: false)],
                spaceIndex: 5, excludingWindowID: nil)?.id == 8)
        check("refocus: 目标 space 无窗口 → nil",
              SpaceController.selectRefocusCandidate(windows: wins, spaceIndex: 9, excludingWindowID: nil) == nil)

        // preSwitch 单维 0 值（B81 补锁）：space/display 任一缺上下文都 → noContext
        check("preSwitch: 仅缺 display 上下文（sourceYabaiDisp=0）→ noContext",
              ToggleEngine.sourceSpacePreSwitch(sourceSpace: 5, sourceYabaiDisp: 0, visibleSpaceOnSourceDisplay: 5)
              == .noContext)

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
        // 边界补锁（B89：MoveCooldownRegistryTests 镜像退役——默认 30s 档的真实参数化语义）
        check("cooldown: 恰好 30s 严格 < 不在冷却、cooldown=0 永不在冷却",
              !MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-30), now: now, cooldownSeconds: 30)
              && !MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(-1), now: now, cooldownSeconds: 0))
        check("cooldown: 未来时刻视为在冷却（时钟回拨防御，宽进严出）",
              MoveCooldownRegistry.isInCooldown(lastMove: now.addingTimeInterval(10), now: now, cooldownSeconds: 30))
        check("cooldown: 29.9s 剩 1（向上取整）、35s 过期不返回负数",
              MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-29.9), now: now, cooldownSeconds: 30) == 1
              && MoveCooldownRegistry.remainingSeconds(lastMove: now.addingTimeInterval(-35), now: now, cooldownSeconds: 30) == 0)

        // B153：实例 ops 直测（注入时钟；不动 .shared——防跨检查污染）
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = { t0 }
        let reg = MoveCooldownRegistry()
        reg.now = clock
        check("cooldownInst: 新实例无记录 → 不在冷却且剩余 0",
              !reg.isInCooldown(windowID: 1) && reg.remainingSeconds(windowID: 1) == 0)
        reg.setCooldown(windowID: 1)
        check("cooldownInst: set 以注入时钟落账；29s 在冷却、恰 30s 出冷却",
              reg.isInCooldown(windowID: 1)
              && reg.remainingSeconds(windowID: 1) == 30
              && !{ reg.now = { t0.addingTimeInterval(30) }; return reg.isInCooldown(windowID: 1) }())
        reg.now = clock
        reg.clearCooldown(windowID: 1)
        check("cooldownInst: clear 即出冷却且剩余归零",
              !reg.isInCooldown(windowID: 1) && reg.remainingSeconds(windowID: 1) == 0)
        reg.clearCooldown(windowID: 42)
        check("cooldownInst: clear 未知窗幂等不崩",
              !reg.isInCooldown(windowID: 42))
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

    // MARK: 过期绑定清理决策（B99：pruneExpiredWindowStates 保留期参数化直测——临时库）

    func runPruneExpiryTests() {
        do {
            let dir = "/tmp/vibefocus-prunetest-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let dbPath = dir + "/prune.db"
            let store = WindowStateStore(dbPath: dbPath)
            let now = Date()
            func state(_ wid: UInt32, completed: Bool, updatedAgo: TimeInterval) -> WindowState {
                var ws = WindowState(
                    windowID: wid, pid: 100, tty: nil, axWindowNumber: nil, appName: "T",
                    bundleIdentifier: nil, title: "t", termSessionID: nil, itermSessionID: nil,
                    sessionID: "s-\(wid)", bindingType: .local, isCompleted: completed,
                    createdAt: now.addingTimeInterval(-updatedAgo), updatedAt: now.addingTimeInterval(-updatedAgo)
                )
                if completed { ws.completedAt = now.addingTimeInterval(-updatedAgo) }
                return ws
            }
            store.saveWindowState(state(1, completed: false, updatedAgo: 3600))   // 活跃 1h 前 → 活跃保留期 24h 内
            store.saveWindowState(state(2, completed: false, updatedAgo: 100_000)) // 活跃 27h 前 → 过期
            store.saveWindowState(state(3, completed: true, updatedAgo: 7200))     // 完成 2h 前 → 完成保留期 4h 内
            store.saveWindowState(state(4, completed: true, updatedAgo: 20_000))   // 完成 5.5h 前 → 过期
            let removed = store.pruneExpiredWindowStates(
                activeRetention: 24 * 3600, completedRetention: 4 * 3600)
            check("prune: 活跃 24h/完成 4h 保留期——恰清 2 条过期（含已完成宽裕档）",
                  removed == 2
                  && store.findWindowState(windowID: 1) != nil
                  && store.findWindowState(windowID: 2) == nil
                  && store.findWindowState(windowID: 3) != nil
                  && store.findWindowState(windowID: 4) == nil)
            check("prune: 再跑一遍幂等（无新过期 → 0）",
                  store.pruneExpiredWindowStates(activeRetention: 24 * 3600, completedRetention: 4 * 3600) == 0)
        }
    }
}

// MARK: - B131：purgeClosedWindows 注入缝直测（活/完成/离屏三态保留清理语义）

extension RunnerHarness {
    func runRegistryPurgeTests() {
        do {
            let dir = "/tmp/vf-b131-purge-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let reg = SessionWindowRegistry(store: WindowStateStore(dbPath: dir + "/swr.db"))

            func cgEntry(_ id: UInt32) -> CGWindowEntry {
                CGWindowEntry(from: [
                    kCGWindowNumber as String: id,
                    kCGWindowOwnerPID as String: pid_t(487),
                    kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 80],
                ])!
            }
            func mkState(_ id: UInt32, completed: Bool) -> WindowState {
                WindowState(
                    windowID: id, pid: 487, tty: nil, axWindowNumber: nil,
                    appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2",
                    title: nil, termSessionID: nil, itermSessionID: nil,
                    sessionID: "s-\(id)", bindingType: .remote,
                    isCompleted: completed, createdAt: Date(), updatedAt: Date())
            }

            // 注入固定 CG 枚举：活窗 100/200（300/400 不在屏幕上）
            reg.windowsProvider = { [cgEntry(100), cgEntry(200)] }
            reg.windowStates[100] = mkState(100, completed: false)   // 活窗 → 保留
            reg.windowStates[200] = mkState(200, completed: true)    // 已完成且活 → 保留
            reg.windowStates[300] = mkState(300, completed: false)   // 未完成且离屏 → 清理
            reg.windowStates[400] = mkState(400, completed: true)    // 已完成且离屏 → 保留
            reg.sessionAliasWindowID["s-300"] = 300

            reg.purgeClosedWindows()

            check("purge: 未完成且不在活列表 → 清理（含 DB 行）",
                  reg.windowStates[300] == nil && reg.sessionAliasWindowID["s-300"] == nil)
            check("purge: 活窗未完成 / 离屏但已完成 / 活窗已完成 → 全保留",
                  reg.windowStates[100] != nil && reg.windowStates[200] != nil
                  && reg.windowStates[400] != nil)

            // touch：消息分支更新描述；无消息不覆盖
            reg.touch(sessionID: "s-100", message: "vf-touch-msg")
            check("purge: touch 携带消息 → 描述更新",
                  reg.lastEventDescription == "vf-touch-msg")
            reg.touch(sessionID: "s-100", message: nil)
            check("purge: touch 无消息 → 描述不被覆盖",
                  reg.lastEventDescription == "vf-touch-msg")
        }

        // MARK: ToggleRecord 持久层（真实实现——B152：save/load/byPID/clear 此前 8.76% 覆盖；
        // 文件头「列所有权」约定首次成文锁定：UPDATE 只写 toggle 列不动 session_id，INSERT 才落 session）
        do {
            let dir = "/tmp/vibefocus-b152-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = WindowStateStore(dbPath: dir + "/swr.db")
            let t1 = Date(timeIntervalSince1970: 1_800_000_000)

            func mkRec(_ wid: UInt32, pid: Int32 = 700, toggledAt: Date, session: String?) -> ToggleRecord {
                ToggleRecord(
                    windowID: wid, pid: pid,
                    bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2",
                    origFrame: CGRect(x: -810, y: -710, width: 1146, height: 707),
                    sourceSpace: 3, sourceDisplay: 2, sourceYabaiDisp: 2, sourceDispSpace: 1,
                    targetFrame: CGRect(x: 0, y: 0, width: 3220, height: 1080),
                    targetDisplay: 1,
                    toggledAt: toggledAt, sessionID: session, reason: "Stop"
                )
            }
            func mkState(_ wid: UInt32, session: String?) -> WindowState {
                WindowState(
                    windowID: wid, pid: 700, tty: nil, axWindowNumber: nil,
                    appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: nil,
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                    envWindowID: nil, sessionID: session, cwd: nil, model: nil,
                    isCompleted: false, createdAt: Date(), updatedAt: Date()
                )
            }

            // INSERT 路径：行不存在 → fallback INSERT，全字段往返（含 session_id 落库）
            store.saveToggleRecord(mkRec(5001, toggledAt: t1, session: "tr-ins"))
            let ins = store.loadToggleRecord(windowID: 5001)
            check("toggleRec: INSERT 全字段往返（frames/space 族/reason/session）",
                  ins?.origFrame.origin.x == -810 && ins?.origFrame.height == 707
                  && ins?.targetFrame.width == 3220 && ins?.targetFrame.origin.y == 0
                  && ins?.sourceSpace == 3 && ins?.sourceDisplay == 2
                  && ins?.sourceYabaiDisp == 2 && ins?.sourceDispSpace == 1
                  && ins?.targetDisplay == 1 && ins?.reason == "Stop"
                  && ins?.sessionID == "tr-ins" && ins?.pid == 700
                  && ins?.bundleIdentifier == "com.googlecode.iterm2"
                  && ins?.toggledAt.timeIntervalSince1970 == t1.timeIntervalSince1970)

            // UPDATE 路径：已有绑定行 → toggle 列更新而 session_id 不被抹（列所有权约定）
            store.saveWindowState(mkState(5002, session: "tr-bind"))
            store.saveToggleRecord(mkRec(5002, toggledAt: t1.addingTimeInterval(10), session: nil))
            let upd = store.loadToggleRecord(windowID: 5002)
            check("toggleRec: UPDATE 落 toggle 列且行上既有绑定 session 保留",
                  upd?.reason == "Stop" && upd?.sessionID == "tr-bind"
                  && store.findWindowState(windowID: 5002)?.sessionID == "tr-bind")

            // loadToggleRecord：缺行 nil；纯绑定行（无 toggle 列）nil
            store.saveWindowState(mkState(5003, session: "tr-plain"))
            check("toggleRec: 缺行 → nil；纯绑定行（toggle_reason NULL）→ nil",
                  store.loadToggleRecord(windowID: 5999) == nil
                  && store.loadToggleRecord(windowID: 5003) == nil)

            // loadToggleRecordByPID：同 pid 双记录取最近 toggled_at；无命中 nil
            store.saveToggleRecord(mkRec(5004, pid: 701, toggledAt: t1, session: nil))
            store.saveToggleRecord(mkRec(5005, pid: 701, toggledAt: t1.addingTimeInterval(60), session: nil))
            check("toggleRec: byPID 同 pid 取最近 toggled_at，无命中 nil",
                  store.loadToggleRecordByPID(pid: 701)?.windowID == 5005
                  && store.loadToggleRecordByPID(pid: 9999) == nil)

            // clear：toggle 列清空（load 回 nil）而绑定行与 session 保留
            store.saveToggleRecord(mkRec(5006, toggledAt: t1, session: nil))
            store.saveWindowState(mkState(5006, session: "tr-keep"))
            store.clearToggleRecord(windowID: 5006)
            check("toggleRec: clear 清 toggle 列、绑定行与 session 保留",
                  store.loadToggleRecord(windowID: 5006) == nil
                  && store.findWindowState(windowID: 5006)?.sessionID == "tr-keep")
        }
    }
}
