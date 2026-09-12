import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPureSweepBTests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runPureSweepB() {
    // MARK: Settings 拆分文件纯函数（真实实现——B35：Hook 测试请求构造/响应裁决提纯）

    do {
        // buildHookRequest：请求契约（URL/方法/头/JSON 体）——发收改造不再需要网络测试兜底。
        func build(_ port: Int, endpoint: String, payload: [String: String], token: String?) throws -> URLRequest {
            try SettingsView.buildHookRequest(port: port, endpoint: endpoint, payload: payload, token: token)
        }
        let req = try? build(8080, endpoint: "/hook",
                             payload: ["event": "SessionStart", "session_id": "test-abc"],
                             token: "tok-1")
        check("hookReq: URL/方法/超时契约",
              req?.url?.absoluteString == "http://127.0.0.1:8080/hook"
              && req?.httpMethod == "POST" && req?.timeoutInterval == 5)
        check("hookReq: Content-Type 恒在 + 有 token 时鉴权头在场",
              req?.value(forHTTPHeaderField: "Content-Type") == "application/json"
              && req?.value(forHTTPHeaderField: "X-VibeFocus-Token") == "tok-1")
        let noToken = try? build(1, endpoint: "/hook", payload: ["event": "Stop"], token: "")
        check("hookReq: 空 token 不设鉴权头",
              noToken?.value(forHTTPHeaderField: "X-VibeFocus-Token") == nil)
        let body = (try? JSONSerialization.jsonObject(with: req?.httpBody ?? Data())) as? [String: String]
        check("hookReq: JSON 体回环",
              body?["event"] == "SessionStart" && body?["session_id"] == "test-abc")

        // hookResponseVerdict：非 HTTP/4xx/5xx/成功四态。
        func httpResp(_ code: Int) -> URLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: code,
                            httpVersion: nil, headerFields: nil)!
        }
        check("hookVerdict: 非 HTTP 响应 → 失败 code -2",
              { if case .failure(let e) = SettingsView.hookResponseVerdict(response: nil, data: nil)
                { return (e as NSError).code == -2 }; return false }())
        check("hookVerdict: 404 → 失败携带状态码与响应体",
              { if case .failure(let e) = SettingsView.hookResponseVerdict(
                    response: httpResp(404), data: Data("not found".utf8))
                { let ns = e as NSError
                  return ns.code == 404 && ns.localizedDescription.contains("not found") }
                return false }())
        check("hookVerdict: 500 无体 → 失败含占位 nil",
              { if case .failure(let e) = SettingsView.hookResponseVerdict(
                    response: httpResp(500), data: nil)
                { return (e as NSError).localizedDescription.contains("nil") }
                return false }())
        check("hookVerdict: 200 → 成功（2xx 边界含 299）",
              { if case .success = SettingsView.hookResponseVerdict(response: httpResp(200), data: nil)
                { return true }; return false }()
              && { if case .success = SettingsView.hookResponseVerdict(response: httpResp(299), data: nil)
                { return true }; return false }())
    }

    // MARK: 提示音门控 + 项目音效解析（真实实现——B36：仅镜像覆盖的纯决策转直测）

    do {
        // SoundPlayGate：免打扰（跨午夜/同日/起闭右开/无效配置）优先于节流；
        // 节流剩余秒数向上取整下限 1。UTC 固定时区注入消环境波动。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let tz = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date {
            cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 9, day: 8, hour: hour))!
        }
        func gate(_ hour: Int, quiet: Bool, start: Int, end: Int,
                  interval: Int = 0, last: Date? = nil) -> SoundPlayGateDecision {
            SoundPlayGate.decide(now: at(hour), lastPlayedAt: last,
                                 minIntervalSeconds: interval,
                                 quietEnabled: quiet, quietStartHour: start, quietEndHour: end,
                                 calendar: cal)
        }
        check("gate: 跨午夜 22→8 两侧窗口命中（23 点与 7 点）",
              gate(23, quiet: true, start: 22, end: 8) == .quietHours
              && gate(7, quiet: true, start: 22, end: 8) == .quietHours)
        check("gate: 窗口起闭右开（22 含 8 不含；21 与 8 点外放行）",
              gate(22, quiet: true, start: 22, end: 8) == .quietHours
              && gate(8, quiet: true, start: 22, end: 8) == .allow
              && gate(21, quiet: true, start: 22, end: 8) == .allow)
        check("gate: 同日窗 9→18（9 与 17 静音，18 放行）",
              gate(9, quiet: true, start: 9, end: 18) == .quietHours
              && gate(17, quiet: true, start: 9, end: 18) == .quietHours
              && gate(18, quiet: true, start: 9, end: 18) == .allow)
        check("gate: 起==止无效配置视作关闭 + 总开关关闭直放",
              gate(23, quiet: true, start: 22, end: 22) == .allow
              && gate(23, quiet: false, start: 22, end: 8) == .allow)
        check("gate: 免打扰硬静音压过节流",
              gate(23, quiet: true, start: 22, end: 8, interval: 60, last: at(23).addingTimeInterval(-5)) == .quietHours)
        check("gate: 节流剩余秒向上取整且下限 1",
              gate(12, quiet: false, start: 0, end: 0, interval: 3,
                   last: at(12).addingTimeInterval(-1.0))
              == .throttled(remainingSeconds: 2)
              && gate(12, quiet: false, start: 0, end: 0, interval: 3,
                      last: at(12).addingTimeInterval(-2.2))
              == .throttled(remainingSeconds: 1))
        check("gate: 间隔已满/首次播放/节流关闭 → 放行",
              gate(12, quiet: false, start: 0, end: 0, interval: 3,
                   last: at(12).addingTimeInterval(-3)) == .allow
              && gate(12, quiet: false, start: 0, end: 0, interval: 3, last: nil) == .allow
              && gate(12, quiet: false, start: 0, end: 0, interval: 0,
                      last: at(12).addingTimeInterval(-0.5)) == .allow)

        // ProjectSoundResolver：首命中优先/非法 rawValue 跳过/双侧归一匹配/未命中回落全局。
        func rule(_ name: String, _ sound: CompletionSoundType?) -> ProjectSoundRule {
            var r = ProjectSoundRule(projectName: name, soundType: .builtinDing)
            if let sound { r.soundRawValue = sound.rawValue } else { r.soundRawValue = "garbage" }
            return r
        }
        check("resolver: 无项目上下文（nil/空）→ 回落全局",
              ProjectSoundResolver.resolvedType(projectName: nil, rules: [rule("x", .builtinDing)], globalType: .none) == .none
              && ProjectSoundResolver.resolvedType(projectName: "", rules: [rule("x", .builtinDing)], globalType: .builtinPing) == .builtinPing)
        check("resolver: 首个命中规则优先",
              ProjectSoundResolver.resolvedType(
                projectName: "vibe-labs",
                rules: [rule("vibe-labs", .builtinDing), rule("vibe-labs", .builtinComplete)],
                globalType: .none) == .builtinDing)
        check("resolver: 非法 rawValue 规则跳过继续匹配",
              ProjectSoundResolver.resolvedType(
                projectName: "vibe-labs",
                rules: [rule("vibe-labs", nil), rule("vibe-labs", .builtinComplete)],
                globalType: .none) == .builtinComplete)
        check("resolver: 规则名可为绝对路径（归一后命中）+ 大小写不敏感",
              ProjectSoundResolver.resolvedType(
                projectName: "vibe-labs",
                rules: [rule("/Users/x/github/Vibe-Labs", .builtinDing)], globalType: .none) == .builtinDing)
        check("resolver: 无命中回落全局",
              ProjectSoundResolver.resolvedType(
                projectName: "other-proj",
                rules: [rule("vibe-labs", .builtinDing)], globalType: .builtinComplete) == .builtinComplete)
    }

    // MARK: 构建能力自检 + 屏幕映射 + 网格快照库（真实实现——B37：镜像转直测/零覆盖转直测）

    do {
        // BuildCapabilities：二进制安全字节搜索（needle 头/中/尾均可命中）+ 稳定摘要格式。
        let needleData = Data("resize channel".utf8)
        let head = needleData + Data(" padding".utf8)
        let middle = Data("x=y\n".utf8) + needleData + Data("\ngrid".utf8)
        let tail = Data("prefix-".utf8) + needleData
        let detected = BuildCapabilities.detect(in: head)
        check("capabilities: 头部命中 + 全键登记数",
              detected["ax-resize-channel"] == true && detected.count == BuildCapabilities.all.count)
        check("capabilities: 中/尾命中 + 空 Data 全 false",
              BuildCapabilities.detect(in: middle)["ax-resize-channel"] == true
              && BuildCapabilities.detect(in: tail)["ax-resize-channel"] == true
              && BuildCapabilities.all.allSatisfy { BuildCapabilities.detect(in: Data())[$0.name] == false })
        let allTrue = Dictionary(uniqueKeysWithValues: BuildCapabilities.all.map { ($0.name, true) })
        check("capabilities: summary 稳定 name=1 格式（登记序）",
              BuildCapabilities.summary(allTrue)
              == BuildCapabilities.all.map { "\($0.name)=1" }.joined(separator: " "))
        check("capabilities: missing 只列 false 项、全真返回空",
              BuildCapabilities.missing(allTrue).isEmpty
              && BuildCapabilities.missing(BuildCapabilities.detect(in: Data())) == BuildCapabilities.all.map(\.name))

        // ScreenLayoutMapper：Cocoa(y 向上)→view(y 向下) 翻转 + 缩放 + 胶囊带几何。
        let main = ScreenLayoutMapper.InputScreen(
            displayID: 1, name: "主屏", cocoaFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMain: true,
            spaces: [ScreenLayoutMapper.InputSpace(yabaiIndex: 1, isVisible: true),
                     ScreenLayoutMapper.InputSpace(yabaiIndex: 2, isVisible: false)])
        let upper = ScreenLayoutMapper.InputScreen(
            displayID: 2, name: "副屏", cocoaFrame: CGRect(x: 0, y: 100, width: 100, height: 100),
            isMain: false, spaces: [])
        let layout = ScreenLayoutMapper.map(
            screens: [main, upper], viewSize: CGSize(width: 314, height: 214))
        let mappedMain = layout.screens.first { $0.displayID == 1 }!
        let mappedUpper = layout.screens.first { $0.displayID == 2 }!
        check("mapper: y 翻转——Cocoa 上方副屏在 view 里位于主屏之上",
              mappedUpper.frame.maxY <= mappedMain.frame.minY)
        // 界并集（两屏纵向堆叠）= 100 宽 × 200 高 → scale = min(286/100, 186/200)。
        check("mapper: scale = min(可用宽/界宽, 可用高/界高)",
              abs(layout.scale - min(286.0 / 100.0, 186.0 / 200.0)) < 0.0001)
        check("mapper: contentRect 包围全部屏矩形",
              abs(layout.contentRect.maxX - (mappedMain.frame.maxX)) < 0.0001
              && layout.contentRect.minY <= mappedUpper.frame.minY)
        check("mapper: Space 胶囊等分内嵌底缘 + 可见 Space 索引取首个可见",
              mappedMain.spaces.count == 2
              && mappedMain.visibleSpaceIndex == 1
              && abs(mappedMain.spaces[0].frame.maxY - (mappedMain.frame.maxY - ScreenLayoutMapper.spaceStripInset)) < 0.0001)
        check("mapper: 无 Space 屏 visibleSpaceIndex nil",
              mappedUpper.visibleSpaceIndex == nil && !mappedUpper.hasSpaces)
        check("mapper: 空输入/非法尺寸 → 空布局",
              ScreenLayoutMapper.map(screens: [], viewSize: CGSize(width: 500, height: 500)).screens.isEmpty
              && ScreenLayoutMapper.map(screens: [main], viewSize: CGSize(width: 10, height: 10)).scale == 0)
        let cells = ScreenLayoutMapper.gridPreviewCells(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), rows: 2, cols: 2)
        check("mapper: 网格预览 2×2 等分 + 非法行列空数组",
              cells.count == 4 && cells[0] == CGRect(x: 0, y: 0, width: 50, height: 50)
              && cells[3].minX == 50 && cells[3].minY == 50
              && ScreenLayoutMapper.gridPreviewCells(screenFrame: main.cocoaFrame, rows: 0, cols: 2).isEmpty)
    }

    do {
        // TerminalGridStore：B32 式 store 注入——快照增改删/latest 语义经临时 SQLite 直测。
        func snap(_ id: String, _ name: String, _ at: Date) -> TerminalGridSnapshot {
            TerminalGridSnapshot(id: id, name: name, appBundleID: "com.apple.Terminal",
                                 displayID: 1, displayYabaiIndex: nil, rows: 2, cols: 2,
                                 cells: [], launchCommand: nil, capturedAt: at)
        }
        let dbPath = "/tmp/vibefocus-b37-\(getpid()).db"
        let store = TerminalGridStore(store: WindowStateStore(dbPath: dbPath))
        check("gridStore: 空库 → 空快照表", store.snapshots().isEmpty)
        let a = snap("a", "布局A", Date(timeIntervalSince1970: 1000))
        store.upsert(a)
        store.upsert(snap("b", "布局B", Date(timeIntervalSince1970: 2000)))
        check("gridStore: upsert 追加 + latest 取最新 capturedAt",
              store.snapshots().count == 2 && store.latest()?.id == "b")
        let aRenamed = TerminalGridSnapshot(id: "a", name: "布局A改", appBundleID: "com.apple.Terminal",
                                            displayID: 1, displayYabaiIndex: nil, rows: 2, cols: 2,
                                            cells: [], launchCommand: nil, capturedAt: a.capturedAt)
        store.upsert(aRenamed)
        check("gridStore: 同 id upsert 替换不追加", store.snapshots().count == 2
              && store.snapshots().first { $0.id == "a" }?.name == "布局A改")
        store.remove(id: "a")
        check("gridStore: remove 生效", store.snapshots().map(\.id) == ["b"]
              && store.latest()?.id == "b")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }

        // TerminalGridPreferences：钳制与显式 0 语义（标准域先存后还原，不污染用户偏好）。
        let defaults = UserDefaults.standard
        let saved = (rows: defaults.object(forKey: TerminalGridPreferences.rowsKey),
                     gap: defaults.object(forKey: TerminalGridPreferences.gapKey),
                     target: defaults.object(forKey: TerminalGridPreferences.targetKey),
                     snapID: defaults.object(forKey: TerminalGridPreferences.autoRestoreSnapshotIDKey))
        defer {
            if let v = saved.rows { defaults.set(v, forKey: TerminalGridPreferences.rowsKey) } else { defaults.removeObject(forKey: TerminalGridPreferences.rowsKey) }
            if let v = saved.gap { defaults.set(v, forKey: TerminalGridPreferences.gapKey) } else { defaults.removeObject(forKey: TerminalGridPreferences.gapKey) }
            if let v = saved.target { defaults.set(v, forKey: TerminalGridPreferences.targetKey) } else { defaults.removeObject(forKey: TerminalGridPreferences.targetKey) }
            if let v = saved.snapID { defaults.set(v, forKey: TerminalGridPreferences.autoRestoreSnapshotIDKey) } else { defaults.removeObject(forKey: TerminalGridPreferences.autoRestoreSnapshotIDKey) }
        }
        TerminalGridPreferences.rows = 99
        check("gridPrefs: 行列钳到 1...maxGridSize（上界 4）",
              TerminalGridPreferences.rows == TerminalGridPlanner.maxGridSize)
        TerminalGridPreferences.rows = 0
        check("gridPrefs: 0 落盘钳为 1（非回默认 2）", TerminalGridPreferences.rows == 1)
        TerminalGridPreferences.gap = 0
        check("gridPrefs: 显式 0 间距持久生效（旧 bug 回归锁）",
              TerminalGridPreferences.gap == 0)
        TerminalGridPreferences.gap = 99
        check("gridPrefs: 间距上钳 40", TerminalGridPreferences.gap == 40)
        TerminalGridPreferences.target = "zzz"
        check("gridPrefs: 非法 target 读取时回落 main",
              TerminalGridPreferences.target == GridTargetCode.main.code)
        TerminalGridPreferences.target = "d2s5"
        check("gridPrefs: 合法 target 原样回读", TerminalGridPreferences.target == "d2s5")
        TerminalGridPreferences.autoRestoreSnapshotID = ""
        check("gridPrefs: 空串快照 ID 归一为 nil",
              TerminalGridPreferences.autoRestoreSnapshotID == nil)
    }

    // MARK: 共存探测/热键冲突/支持级别/队列策略（真实实现——B38：仅镜像/零覆盖类型转直测收尾）

    do {
        // WindowLayoutManagerProbe.evaluate：name/bundleID 双通道 + running 蕴含 installed。
        let profile = WindowLayoutManagerProbe.evaluate(
            runningAppNames: ["Magnet"],
            runningBundleIDs: ["com.knollsoft.Rectangle"],
            installedAppNames: ["Moom", "SizeUp"])
        let rect = profile.candidates.first { $0.name == "Rectangle" }!
        let magnet = profile.candidates.first { $0.name == "Magnet" }!
        let moom = profile.candidates.first { $0.name == "Moom" }!
        check("probe: bundleID 通道命中（运行即安装）", rect.running && rect.installed)
        check("probe: name 通道兜底（bundleID 名单过期也不漏）", magnet.running && magnet.installed)
        check("probe: 仅安装未运行不冲突 + 未知名单外不生成候选",
              moom.installed && !moom.running
              && !profile.candidates.contains { $0.name == "yabai" }
              && profile.candidates.count == WindowLayoutManagerProbe.knownManagers.count)
        check("probe: conflictSummary 人读格式拼接",
              profile.conflictSummary == "Rectangle（运行中）、Magnet（运行中）"
              && profile.hasRunningConflict
              && profile.runningConflicts.map(\.name) == ["Rectangle", "Magnet"])
        let calm = WindowLayoutManagerProbe.evaluate(
            runningAppNames: [], runningBundleIDs: [], installedAppNames: ["Rectangle"])
        check("probe: 无运行竞品 → summary nil（UI 不打扰）",
              !calm.hasRunningConflict && calm.conflictSummary == nil)

        // 热键系统冲突表 + 显示串。
        check("hotKey: 默认 ⌃Q 与旧默认 ⌃⌥⌘M 显示串",
              HotKeyConfiguration.default.displayString == "⌃Q"
              && HotKeyConfiguration.legacyDefault.displayString == "⌃⌥⌘M")
        check("hotKey: 冲突表配置互异 + 非空",
              Set(HotKeyConfiguration.knownConflicts.map(\.configuration)).count
              == HotKeyConfiguration.knownConflicts.count)
        check("hotKey: 回归——默认 ⌃Q 不与系统冲突表相撞",
              !HotKeyConfiguration.knownConflicts.contains { $0.configuration == HotKeyConfiguration.default })
        let full = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A),
                                       modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        check("hotKey: 修饰键显示序固定 ⌃⌥⇧⌘", full.displayString == "⌃⌥⇧⌘A")

        // 终端自动化支持级别：三级别映射 + 未知回落。
        check("supportLevel: Terminal full / iTerm2 partial",
              TerminalSelectionResolver.supportLevel(forBundleID: "com.apple.Terminal") == .full
              && TerminalSelectionResolver.supportLevel(forBundleID: "com.googlecode.iterm2") == .partial)
        check("supportLevel: 名单内无通道 / 名单外未知 → none",
              TerminalSelectionResolver.supportLevel(forBundleID: "dev.warp.Warp-Stable") == .none
              && TerminalSelectionResolver.supportLevel(forBundleID: "com.unknown.app") == .none)
        check("supportLevel: 名单与显示名登记数一致",
              TerminalSelectionResolver.supportTable.count == TerminalSelectionResolver.knownNames.count)

        // 播报队列入队策略：FIFO 保序 + 满丢最旧 + 容量防御 + 值语义。
        let empty: [QueuedAnnouncement] = []
        let q1 = VoiceAnnouncementQueuePolicy.appendedQueue(
            empty, appending: .text("第一条"), capacity: 3)
        let q2 = VoiceAnnouncementQueuePolicy.appendedQueue(
            q1, appending: .text("第二条"), capacity: 3)
        check("voiceQueue: FIFO 保序追加", q2.map { if case .text(let t) = $0 { return t } else { return "?" } } == ["第一条", "第二条"])
        let q3 = VoiceAnnouncementQueuePolicy.appendedQueue(
            q2, appending: .text("第三条"), capacity: 3)
        let q4 = VoiceAnnouncementQueuePolicy.appendedQueue(
            q3, appending: .audioFile(path: "/tmp/a.wav"), capacity: 3)
        check("voiceQueue: 满容入队丢最旧（先进先出）",
              q4.count == 3
              && q4.map { if case .text(let t) = $0 { return t } else { return "audio" } } == ["第二条", "第三条", "audio"])
        let q5 = VoiceAnnouncementQueuePolicy.appendedQueue(q4, appending: .text("新"), capacity: 0)
        check("voiceQueue: 容量<1 防御按 1（仅留最新）",
              q5.count == 1 && { if case .text("新") = q5[0] { return true }; return false }())
        check("voiceQueue: 值语义——入参队列不被修改", q3.count == 3)
    }

    do {
        // SpacePreferences：默认开 + 标准域回环（先存后还原）。
        check("spacePrefs: 文档默认值 true",
              SpacePreferences.defaultIntegrationEnabled == true)
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SpacePreferences.integrationEnabledKey)
        defer {
            if let v = saved { defaults.set(v, forKey: SpacePreferences.integrationEnabledKey) }
            else { defaults.removeObject(forKey: SpacePreferences.integrationEnabledKey) }
        }
        SpacePreferences.integrationEnabled = false
        check("spacePrefs: 关闭后回读 false（解除 Space 集成开关）",
              SpacePreferences.integrationEnabled == false)
        SpacePreferences.integrationEnabled = true
        check("spacePrefs: 开启回读 true", SpacePreferences.integrationEnabled == true)
    }

    // MARK: Minimap 切换反馈 + 标题脚本决策（真实实现——B39：并行会话新增镜像转直测）

    do {
        // GridSpaceSwitchFeedback：三态如实反馈（空工作区失败不许静默——用户报告回归锁）。
        // 标注语言=「屏号-位次」（调用方解出 label 传入；快照缺失回退 "Space 全局号"）。
        check("switchFB: noDrift 已是当前工作区",
              GridSpaceSwitchFeedback.message(for: .noDrift, label: "3-2") == "3-2 已是当前工作区")
        check("switchFB: refocused 成功文案（postSpace 不入文案，以目标 space 表述）",
              GridSpaceSwitchFeedback.message(for: .refocused(postSpace: 9), label: "3-2") == "已切换到 3-2")
        check("switchFB: failed 失败说明含原因（不许静默）",
              GridSpaceSwitchFeedback.message(for: .failed(postSpace: 9), label: "2-1")
              == "无法切换到 2-1：该工作区没有可聚焦的窗口，且 SA 直切通道不可用（SIP 拦截）——空工作区只能通过 SA 切换")
        // B173 状态分流：missing=布局漂移、unknown=查询失败，各自如实文案（不与空工作区共用）。
        check("switchFB: missing 布局漂移文案（引导刷新屏幕布局）",
              GridSpaceSwitchFeedback.message(for: .failed(postSpace: 0), label: "2-1",
                                             state: .missing).contains("已不存在")
              && GridSpaceSwitchFeedback.message(for: .failed(postSpace: 0), label: "2-1",
                                                 state: .missing).contains("刷新"))
        check("switchFB: unknown+noDrift 不再编造「已是当前工作区」",
              GridSpaceSwitchFeedback.message(for: .noDrift, label: "2-1",
                                              state: .unknown).contains("无法确认")
              && !GridSpaceSwitchFeedback.message(for: .noDrift, label: "2-1",
                                                  state: .unknown).contains("已是当前工作区"))
        check("switchFB: unknown+failed 查询失败文案",
              GridSpaceSwitchFeedback.message(for: .failed(postSpace: 9), label: "2-1",
                                              state: .unknown).contains("yabai 查询失败"))
        check("switchFB: unknown+refocused 照常报成功（切换真实发生）",
              GridSpaceSwitchFeedback.message(for: .refocused(postSpace: 9), label: "2-1",
                                              state: .unknown) == "已切换到 2-1")

        // TitleEditor 脚本决策层：转义/模板契约/verdict 哨兵/诊断回读。
        check("titleEsc: 反斜杠与双引号转义 + 原文透传",
              TitleEditorService.escapingAppleScriptString("my \\proj \"x\"") == "my \\\\proj \\\"x\\\""
              && TitleEditorService.escapingAppleScriptString("干净标题") == "干净标题")
        let ttyScript = TitleEditorService.makeTitleScript(
            bundleID: "com.apple.Terminal", title: "vibe", targetTTY: "/dev/ttys001")
        check("titleScript: Terminal+tty 定向寻址 + 双哨兵 + 诊断显示项关闭",
              ttyScript?.contains("tty of t = \"/dev/ttys001\"") == true
              && ttyScript?.contains("return \"matched\"") == true
              && ttyScript?.contains("return \"not_found\"") == true
              && ttyScript?.contains("title displays device name to false") == true)
        let frontScript = TitleEditorService.makeTitleScript(
            bundleID: "com.apple.Terminal", title: "vibe", targetTTY: nil)
        check("titleScript: Terminal 无 tty 回退 front 窗口语义",
              frontScript?.contains("selected tab of front window") == true
              && frontScript?.contains("repeat") == false)
        let itermScript = TitleEditorService.makeTitleScript(
            bundleID: "com.googlecode.iterm2", title: "vibe", targetTTY: "/dev/ttys002")
        check("titleScript: iTerm2+tty 会话级定向",
              itermScript?.contains("tty of s = \"/dev/ttys002\"") == true
              && itermScript?.contains("set name of s to") == true)
        check("titleScript: iTerm2 无 tty 单行 front 语义",
              TitleEditorService.makeTitleScript(bundleID: "com.googlecode.iterm2", title: "v", targetTTY: nil)?
              .contains("current session of current window") == true)
        check("titleScript: 不支持的 bundleID → nil（unsupported_bundle 结局）",
              TitleEditorService.makeTitleScript(bundleID: "com.other.app", title: "x", targetTTY: nil) == nil)
        let tricky = TitleEditorService.makeTitleScript(
            bundleID: "com.apple.Terminal", title: "a\"b\\c", targetTTY: "/dev/ttys001")
        check("titleScript: 标题内引号/反斜杠已转义进模板",
              tricky?.contains("set custom title of t to \"a\\\"b\\\\c\"") == true)
        check("titleVerdict: 只有 matched 算命中（not_found/nil/大小写均否）",
              TitleEditorService.isMatchedVerdict("matched") == true
              && TitleEditorService.isMatchedVerdict("not_found") == false
              && TitleEditorService.isMatchedVerdict(nil) == false
              && TitleEditorService.isMatchedVerdict("Matched") == false)
        check("titleDiag: Terminal 诊断回读跟随 tty 定向 + target_gone 哨兵",
              TitleEditorService.makeTerminalDiagnosticScript(targetTTY: "/dev/ttys001")
              .contains("tty of t =") == true
              && TitleEditorService.makeTerminalDiagnosticScript(targetTTY: "/dev/ttys001")
              .contains("target_gone") == true
              && TitleEditorService.makeTerminalDiagnosticScript(targetTTY: nil)
              .contains("front window") == true)
    }

    // MARK: 轻量枚举与错误文案收尾（真实实现——B40：双口径扫描最后可行动项清账）

    do {
        // VoiceAnnouncementError：LLM 播报链四类错误的用户可见文案。
        check("voiceErr: 四类错误文案非空且互异",
              Set([VoiceAnnouncementError.invalidAPIBase,
                   VoiceAnnouncementError.invalidResponse,
                   VoiceAnnouncementError.httpError(502),
                   VoiceAnnouncementError.parseError].compactMap(\.errorDescription)).count == 4)
        check("voiceErr: httpError 携带状态码插值",
              VoiceAnnouncementError.httpError(502).errorDescription == "API 请求失败（HTTP 502）")
        check("voiceErr: LocalizedError 协议经 errorDescription 暴露",
              (VoiceAnnouncementError.parseError as LocalizedError).errorDescription == "无法解析 API 响应")

        // SpaceAvailability / LogLevel：String rawValue 契约（日志与 UI 状态判定的事实源）。
        check("spaceAvail: 四态 rawValue 双向回环",
              SpaceAvailability(rawValue: "available") == .available
              && SpaceAvailability(rawValue: "unknown") == .unknown
              && SpaceAvailability(rawValue: "notInstalled") == .notInstalled
              && SpaceAvailability(rawValue: "unavailable") == .unavailable
              && SpaceAvailability.available.rawValue == "available")
        check("logLevel: 四级 rawValue 契约（DEBUG/INFO/WARN/ERROR）",
              LogLevel(rawValue: "DEBUG") == .debug && LogLevel(rawValue: "INFO") == .info
              && LogLevel(rawValue: "WARN") == .warn && LogLevel(rawValue: "ERROR") == .error
              && LogLevel.warn.rawValue == "WARN" && LogLevel.error.rawValue == "ERROR")
    }

    // MARK: Admin 提权模板 + Doctor 报告端到端（真实实现——B41：编排内嵌模板提纯 + 注入式路径直测）

    do {
        // makeAdminShellScript：转义防注入 + 包装格式（模板决策与执行分离，照 TitleEditor 模式）。
        let plain = SpaceController.makeAdminShellScript("yabai --install-sa")
        check("adminScript: 普通命令包装格式",
              plain == "do shell script \"yabai --install-sa\" with administrator privileges")
        let tricky = SpaceController.makeAdminShellScript("echo \"a b\"; rm -rf x\\y")
        check("adminScript: 双引号/反斜杠转义防注入",
              tricky.contains(#"echo \"a b\"; rm -rf x\\y"#)
              && !tricky.contains(#"echo "a b""#)
              && tricky.hasSuffix("with administrator privileges"))
        check("adminScript: 分号等 shell 元字符原样保留（转义只处理引号族）",
              tricky.contains("; rm -rf x"))
    }

    do {
        // Doctor.report：DoctorPaths 全注入 → 临时日志目录端到端（原 317 行文件编排段 0 覆盖）。
        let dir = "/tmp/vibefocus-b41-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let journalPath = dir + "/exits.jsonl"
        let lines = [
            "{\"kind\":\"launch\",\"pid\":101,\"at\":\"T1\",\"exe\":\"/app/VF\",\"ax\":true}",
            "{\"kind\":\"exit\",\"pid\":101,\"at\":\"T2\",\"reason\":\"signal\",\"name\":\"SIGTRAP\"}",
            "{\"kind\":\"launch\",\"pid\":102,\"at\":\"T3\",\"exe\":\"/app/VF\",\"ax\":false}",
        ]
        try? lines.joined(separator: "\n").write(toFile: journalPath, atomically: true, encoding: .utf8)
        check("doctorE2E: 日志夹具写入成功",
              FileManager.default.fileExists(atPath: journalPath))
        let paths = DoctorPaths(
            journalPath: journalPath, logDir: dir, tmpFatalPath: dir + "/none1",
            tmpSnapshotPath: dir + "/none2", keepaliveLogPath: dir + "/none3",
            diagnosticReportsDir: dir, appLogPath: dir + "/vibefocus.log")
        let report = Doctor.report(paths: paths, now: Date(timeIntervalSince1970: 1000))
        check("doctorE2E: 报告含生命周期段与事件计数",
              report.contains("[实例生命周期]") && report.contains("共 3 条事件"))
        check("doctorE2E: 最近一次死亡段含 pid 与信号",
              report.contains("[最近一次死亡]") && report.contains("pid=101") && report.contains("SIGTRAP"))
        check("doctorE2E: 无配对 launch 现形（外部击杀实证段）",
              report.contains("pid=102"))
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: 持久化偏好微缺口收尾（真实实现——B42：仅镜像清单最后三个可锁类型）

    do {
        // ClaudeHookEventType / WindowMoveReason：线上 JSON 契约的 rawValue（与 hook 脚本/审计行互为表里）。
        check("hookEvent: 四事件 PascalCase rawValue 契约",
              ClaudeHookEventType.allCases.map(\.rawValue)
              == ["SessionStart", "Stop", "SessionEnd", "UserPromptSubmit"])
        check("moveReason: 三原因 snake_case rawValue 回环",
              WindowMoveReason(rawValue: "manual_hotkey") == .manualHotkey
              && WindowMoveReason(rawValue: "claude_session_end") == .claudeSessionEnd
              && WindowMoveReason(rawValue: "user_prompt_submit") == .userPromptSubmit
              && WindowMoveReason.manualHotkey.rawValue == "manual_hotkey")

        // VoiceAnnouncementPreferences：默认实例 Codable 回环（播报偏好持久化契约）。
        let voice = VoiceAnnouncementPreferences.default
        let voiceBack = try? JSONDecoder().decode(
            VoiceAnnouncementPreferences.self, from: JSONEncoder().encode(voice))
        check("voicePrefs: 默认实例编解码回环逐字段保真",
              voiceBack?.mode == VoiceAnnouncementMode.none && voiceBack?.templateText == "{project_name} 完成"
              && voiceBack?.volume == Float(0.7) && voiceBack?.speechRate == 180
              && voiceBack?.llmModel == "gpt-4o-mini" && voiceBack?.llmMaxChars == 30
              && voiceBack?.audioFilePath == nil)

        // TitleEditorPreferences：未设置默认 true 语义 + 回环（标准域先存后还原）。
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: "titleEditorEnabled")
        let savedHotKey = defaults.object(forKey: "titleEditorHotKeyEnabled")
        defer {
            if let v = savedEnabled { defaults.set(v, forKey: "titleEditorEnabled") } else { defaults.removeObject(forKey: "titleEditorEnabled") }
            if let v = savedHotKey { defaults.set(v, forKey: "titleEditorHotKeyEnabled") } else { defaults.removeObject(forKey: "titleEditorHotKeyEnabled") }
        }
        defaults.removeObject(forKey: "titleEditorEnabled")
        defaults.removeObject(forKey: "titleEditorHotKeyEnabled")
        check("titlePrefs: 键未设置 → 功能默认开启（双开关同语义）",
              TitleEditorPreferences.isEnabled == true && TitleEditorPreferences.isHotKeyEnabled == true)
        TitleEditorPreferences.isEnabled = false
        TitleEditorPreferences.isHotKeyEnabled = false
        check("titlePrefs: 显式关闭回读 false（显式值优先于默认）",
              TitleEditorPreferences.isEnabled == false && TitleEditorPreferences.isHotKeyEnabled == false)
    }

    // MARK: 坐标纯函数补齐（真实实现——B43：漂移和判据/夹取/主屏归属，原仅 E2E 门控覆盖）

    do {
        // originDrift/sizeDrift：曼哈顿漂移和（日志展示与收敛判定唯一公式）。
        check("coord: originDrift 绝对值求和（负向同权）",
              CoordinateKit.originDrift(CGPoint(x: 3, y: -4), CGPoint(x: 0, y: 0)) == 7
              && CoordinateKit.originDrift(CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)) == 0)
        check("coord: sizeDrift 宽高差绝对值求和",
              CoordinateKit.sizeDrift(CGSize(width: 50, height: 50), CGSize(width: 40, height: 60)) == 20)

        // isSizeConverged：漂移和 ≤ 容差（playbook 2.16a 第十二刀：禁止逐轴判据的合计超调）。
        check("coord: 漂移和判据——逐轴均贴容差但合计超调 → 不收敛",
              CoordinateKit.isSizeConverged(actual: CGSize(width: 50, height: 50),
                                            target: CGSize(width: 40, height: 60), tolerance: 10) == false
              && CoordinateKit.isSizeConverged(actual: CGSize(width: 45, height: 60),
                                               target: CGSize(width: 40, height: 60), tolerance: 10) == true)

        // isFrameConverged：origin 与 size 双维度漂移和均 ≤ 容差。
        let target = CGRect(x: 100, y: 200, width: 800, height: 600)
        check("coord: isFrameConverged 双维容差内收敛",
              CoordinateKit.isFrameConverged(actual: CGRect(x: 102, y: 198, width: 802, height: 598),
                                             target: target, tolerance: 5))
        check("coord: isFrameConverged 任一维超差即不收敛",
              !CoordinateKit.isFrameConverged(actual: CGRect(x: 106, y: 200, width: 800, height: 600),
                                              target: target, tolerance: 5)
              && !CoordinateKit.isFrameConverged(actual: CGRect(x: 100, y: 200, width: 810, height: 600),
                                                 target: target, tolerance: 5))

        // clampFrame：尺寸 min 收窄 + 位置夹回内部（右/下越界与居中内不动）。
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        check("coord: clampFrame 界内原样 + 超界夹边",
              CoordinateKit.clampFrame(CGRect(x: 100, y: 100, width: 800, height: 600), into: bounds)
              == CGRect(x: 100, y: 100, width: 800, height: 600)
              && CoordinateKit.clampFrame(CGRect(x: 5000, y: 500, width: 800, height: 600), into: bounds)
              == CGRect(x: 200, y: 400, width: 800, height: 600))
        check("coord: clampFrame 超大 frame 尺寸收窄到 bounds",
              CoordinateKit.clampFrame(CGRect(x: -50, y: -50, width: 5000, height: 3000), into: bounds)
              == bounds)

        // isOnMainScreen(rect:mainScreenFrame:)：中心点包含判定（全仓唯一主屏归属实现）。
        let mainFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        check("coord: isOnMainScreen 中心点在主屏内/外",
              CoordinateKit.isOnMainScreen(CGRect(x: 800, y: 500, width: 100, height: 100),
                                           mainScreenFrame: mainFrame)
              && !CoordinateKit.isOnMainScreen(CGRect(x: 2000, y: 500, width: 100, height: 100),
                                               mainScreenFrame: mainFrame))
    }

    // MARK: 热键校验真身（真实实现——B45：Runner 内同语义镜像删除，改直测 validate）

    do {
        // 无修饰键 → 拒绝；已知系统冲突 → 携带原因；合法组合 → nil。
        let noMod = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        check("hotKeyValidate: 无 ⌘/⌥/⌃ 修饰 → 拒绝",
              HotKeyManager.validationError(for: noMod)?.contains("⌘") == true)
        let spotLight = HotKeyConfiguration(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        check("hotKeyValidate: 已知冲突 → 携带冲突原因",
              HotKeyManager.validationError(for: spotLight)?.contains("Spotlight") == true)
        check("hotKeyValidate: 默认 ⌃Q 合法 → nil",
              HotKeyManager.validationError(for: .default) == nil)
        check("hotKeyValidate: shiftKey 单独不算有效修饰",
              HotKeyManager.validationError(
                for: HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)))
              != nil)
    }

    // MARK: 音效解析计划（真实实现——B46：resolveSound 内嵌映射提纯，免 IO 直锁）

    do {
        typealias Plan = SoundManager.SoundResolution
        func plan(_ type: CompletionSoundType, explicit: String? = nil, configured: String? = nil) -> Plan {
            SoundManager.soundResolutionPlan(for: type, explicitPath: explicit, configuredPath: configured)
        }
        let missingFile = "/tmp/vibefocus-b46-nonexistent-\(getpid()).wav"
        let existingFile = "/tmp/vibefocus-b46-existing-\(getpid()).m4a"
        try? "".write(toFile: existingFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: existingFile) }

        check("soundPlan: none 不发声；四内置音效映射 Bundle 资源名",
              plan(.none) == .none
              && plan(.builtinDing) == .bundled(resource: "ding")
              && plan(.builtinPing) == .bundled(resource: "ping")
              && plan(.builtinComplete) == .bundled(resource: "complete")
              && plan(.builtinAreYouOk) == .bundled(resource: "are-you-ok"))
        check("soundPlan: 系统默认映射 Hero 命名音",
              plan(.systemDefault) == .system(name: "Hero"))
        check("soundPlan: custom 文件存在 → file 通道",
              plan(.custom, explicit: existingFile) == .file(path: existingFile))
        check("soundPlan: custom 文件缺失 → 降级系统默认（轮次 3 行为）",
              plan(.custom, explicit: missingFile) == .system(name: "Hero"))
        check("soundPlan: custom 路径双缺/空串 → 不发声",
              plan(.custom) == .none
              && plan(.custom, configured: "") == .none)
        check("soundPlan: 显式路径优先于已配置路径",
              plan(.custom, explicit: existingFile, configured: missingFile) == .file(path: existingFile))
    }

    // MARK: Doctor 报告全段落端到端（真实实现——B47：B41 生命周期段之外的六个段落补齐）

    do {
        let dir = "/tmp/vibefocus-b47-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let journalPath = dir + "/exits.jsonl"
        let journal = [
            "{\"kind\":\"launch\",\"pid\":101,\"at\":\"T1\",\"exe\":\"/app/VF\",\"ax\":true}",
            "{\"kind\":\"exit\",\"pid\":101,\"at\":\"T2\",\"reason\":\"signal\",\"name\":\"SIGTRAP\"}",
            "{\"kind\":\"launch\",\"pid\":102,\"at\":\"T3\",\"exe\":\"/app/VF\",\"ax\":false}",
        ]
        try? journal.joined(separator: "\n").write(toFile: journalPath, atomically: true, encoding: .utf8)
        let tmpFatal = dir + "/fatal.tmp"
        try? "FATAL".write(toFile: tmpFatal, atomically: true, encoding: .utf8)
        try? "keepalive line 1".write(toFile: dir + "/keepalive.log", atomically: true, encoding: .utf8)
        try? "fatal archive".write(toFile: dir + "/crash-fatal-1.log", atomically: true, encoding: .utf8)
        try? "ips body".write(toFile: dir + "/VibeFocus-2026-09-08.ips", atomically: true, encoding: .utf8)

        let paths = DoctorPaths(
            journalPath: journalPath, logDir: dir, tmpFatalPath: tmpFatal,
            tmpSnapshotPath: dir + "/none2", keepaliveLogPath: dir + "/keepalive.log",
            diagnosticReportsDir: dir, appLogPath: dir + "/vibefocus.log")
        let report = Doctor.report(paths: paths, now: Date(timeIntervalSince1970: 1000))

        check("doctorFull: 授权时间线段——当前状态与翻转计数",
              report.contains("[辅助功能授权] 当前：未授权")
              && report.contains("检测到 1 次翻转"))
        check("doctorFull: 疑似外部击杀段计数（launch 无配对 exit）",
              report.contains("[疑似外部击杀（launch 无配对 exit，SIGKILL 类）] 1 个"))
        check("doctorFull: 致命信号现场段——存在含 size 标注、缺失报不存在",
              report.contains("[致命信号记录现场]")
              && report.contains("/tmp fatal: 存在 size=")
              && report.contains("/tmp snapshot: 不存在"))
        check("doctorFull: .ips 崩溃报告段列出夹具文件",
              report.contains("[.ips 崩溃报告]") && report.contains("VibeFocus-2026-09-08.ips"))
        check("doctorFull: keepalive 决策段回显夹具行",
              report.contains("[keepalive 决策]") && report.contains("keepalive line 1"))
        check("doctorFull: 构建能力标记段恒在场（自检字节级）",
              report.contains("[构建能力标记]"))

        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: NSScreen ↔ yabai display 几何匹配（真实实现——minimap 对应关系修复，Batch 33）

    do {
        // 回归主案例：yabai 序与 NSScreen 序相反（同尺寸双副屏），按几何必须配对正确。
        let cocoaAB = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let quartzReversed = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        ]
        let matchA = CoordinateKit.matchYabaiDisplayIndices(
            cocoaFrames: cocoaAB, mainHeight: 1080,
            yabaiIndices: [1, 2, 3], yabaiQuartzFrames: quartzReversed)
        check("yabaiMatchDirect A: 反序副屏几何配对（左→3 / 右→2）",
              matchA[0] == 1 && matchA[1] == 3 && matchA[2] == 2)
        let matchB = CoordinateKit.matchYabaiDisplayIndices(
            cocoaFrames: [
                CGRect(x: 0, y: 0, width: 1728, height: 1117),
                CGRect(x: 0, y: 1117, width: 1920, height: 1080),
            ],
            mainHeight: 1117,
            yabaiIndices: [1, 2],
            yabaiQuartzFrames: [
                CGRect(x: 0, y: 0, width: 1728, height: 1117),
                CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            ])
        check("yabaiMatchDirect B: 主屏上方副屏（quartz 负 y）翻转匹配",
              matchB[0] == 1 && matchB[1] == 2)
        check("yabaiMatchDirect C: 数量不符/空输入 → 空表回退",
              CoordinateKit.matchYabaiDisplayIndices(
                cocoaFrames: cocoaAB, mainHeight: 1080,
                yabaiIndices: [1], yabaiQuartzFrames: quartzReversed).isEmpty
              && CoordinateKit.matchYabaiDisplayIndices(
                cocoaFrames: [], mainHeight: 1080, yabaiIndices: [], yabaiQuartzFrames: []).isEmpty)
    }

    // MARK: 零命中纯函数清扫 II（真实实现——Overlay 几何/免打扰门/绑定校验/端口钳制，Batch 37）

    do {
        // A. SoundPlayGate.decide：免打扰时间窗 + 节流的完整决策表（固定时区消歧义）。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ h: Int, _ m: Int = 0, _ sec: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: h, minute: m, second: sec))!
        }
        check("pureSweep2 A1: 同日窗（9..18）hour=12 → 静音",
              SoundPlayGate.decide(now: at(12), lastPlayedAt: nil, minIntervalSeconds: 0,
                                   quietEnabled: true, quietStartHour: 9, quietEndHour: 18, calendar: cal) == .quietHours)
        check("pureSweep2 A2: 起闭右开——hour=9 静音、hour=18 不静音",
              SoundPlayGate.decide(now: at(9), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                   quietStartHour: 9, quietEndHour: 18, calendar: cal) == .quietHours
              && SoundPlayGate.decide(now: at(18), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                      quietStartHour: 9, quietEndHour: 18, calendar: cal) == .allow)
        check("pureSweep2 A3: 跨午夜窗（22→8）hour=23/7 静音、hour=8/21 不静音",
              SoundPlayGate.decide(now: at(23), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                   quietStartHour: 22, quietEndHour: 8, calendar: cal) == .quietHours
              && SoundPlayGate.decide(now: at(7), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                      quietStartHour: 22, quietEndHour: 8, calendar: cal) == .quietHours
              && SoundPlayGate.decide(now: at(8), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                      quietStartHour: 22, quietEndHour: 8, calendar: cal) == .allow
              && SoundPlayGate.decide(now: at(21), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                      quietStartHour: 22, quietEndHour: 8, calendar: cal) == .allow)
        check("pureSweep2 A4: start==end 配置无效视作不启用；开关关闭不静音",
              SoundPlayGate.decide(now: at(12), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: true,
                                   quietStartHour: 9, quietEndHour: 9, calendar: cal) == .allow
              && SoundPlayGate.decide(now: at(12), lastPlayedAt: nil, minIntervalSeconds: 0, quietEnabled: false,
                                      quietStartHour: 9, quietEndHour: 18, calendar: cal) == .allow)
        check("pureSweep2 A5: 节流——间隔未到 throttled(remaining≥1)、跨阈放行、首播放行、间隔 0 关闭",
              SoundPlayGate.decide(now: at(12, 0, 4), lastPlayedAt: at(12, 0, 0), minIntervalSeconds: 5,
                                   quietEnabled: false, quietStartHour: 0, quietEndHour: 0, calendar: cal)
              == .throttled(remainingSeconds: 1)
              && SoundPlayGate.decide(now: at(12, 0, 5), lastPlayedAt: at(12, 0, 0), minIntervalSeconds: 5,
                                      quietEnabled: false, quietStartHour: 0, quietEndHour: 0, calendar: cal) == .allow
              && SoundPlayGate.decide(now: at(12), lastPlayedAt: nil, minIntervalSeconds: 5,
                                      quietEnabled: false, quietStartHour: 0, quietEndHour: 0, calendar: cal) == .allow
              && SoundPlayGate.decide(now: at(12), lastPlayedAt: at(12), minIntervalSeconds: 0,
                                      quietEnabled: false, quietStartHour: 0, quietEndHour: 0, calendar: cal) == .allow)
        check("pureSweep2 A6: 静音优先于节流（quiet 先裁决）",
              SoundPlayGate.decide(now: at(12), lastPlayedAt: at(12), minIntervalSeconds: 5,
                                   quietEnabled: true, quietStartHour: 9, quietEndHour: 18, calendar: cal) == .quietHours)

        // B. Overlay 几何三件套：六方位原点 / 尺寸地板 / 标签映射。
        let screen = CGRect(x: 100, y: 50, width: 1920, height: 1080)
        let size = CGSize(width: 120, height: 40)
        check("pureSweep2 B1: 六方位原点（Cocoa y 向上，top=maxY-h-m / bottom=minY+m）",
              OverlayWindow.calculateOverlayOrigin(position: .topLeft, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 112, y: 1078)
              && OverlayWindow.calculateOverlayOrigin(position: .topRight, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 1888, y: 1078)
              && OverlayWindow.calculateOverlayOrigin(position: .bottomLeft, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 112, y: 62)
              && OverlayWindow.calculateOverlayOrigin(position: .bottomRight, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 1888, y: 62)
              && OverlayWindow.calculateOverlayOrigin(position: .topCenter, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 1000, y: 1078)
              && OverlayWindow.calculateOverlayOrigin(position: .bottomCenter, screenFrame: screen, windowSize: size, margin: 12)
              == CGPoint(x: 1000, y: 62))
        check("pureSweep2 B2: 负 margin 钳 0",
              OverlayWindow.calculateOverlayOrigin(position: .topLeft, screenFrame: screen, windowSize: size, margin: -5)
              == CGPoint(x: 100, y: 1090))
        check("pureSweep2 B3: 尺寸 = 文本+双倍 padding，且不小于字号地板",
              OverlayWindow.calculateOverlaySize(textWidth: 200, textHeight: 50, scaledFontSize: 20)
              == CGSize(width: 232, height: 70)
              && OverlayWindow.calculateOverlaySize(textWidth: 10, textHeight: 5, scaledFontSize: 20)
              == CGSize(width: 70, height: 40))
        check("pureSweep2 B4: 标签 = yabai 屏号-工作区全局号（与 minimap 屏N/S 同源）",
              OverlayWindow.calculateOverlayLabel(screenIndex: 0, yabaiDisplayIndex: 3, spaceIndex: 5) == "3-5"
              && OverlayWindow.calculateOverlayLabel(screenIndex: 1, yabaiDisplayIndex: nil, spaceIndex: 2) == "2-2")

        // C. BindingVerifier 决策表：pid 消亡 / 窗口缺失 / PID 错位（带关联值）/ 有效。
        func winEntry(_ pid: Int32) -> CGWindowEntry {
            CGWindowEntry(from: [kCGWindowNumber as String: UInt32(7),
                                 kCGWindowOwnerPID as String: pid,
                                 kCGWindowLayer as String: 0])!
        }
        check("pureSweep2 C1: pid 不存在 → pidNoLongerExists（先决）",
              SessionWindowRegistry.decideBindingVerification(pidExists: false, windowEntry: winEntry(100), expectedPID: 100)
              == .pidNoLongerExists)
        check("pureSweep2 C2: pid 在但窗口缺失 → windowNotFound",
              SessionWindowRegistry.decideBindingVerification(pidExists: true, windowEntry: nil, expectedPID: 100)
              == .windowNotFound)
        check("pureSweep2 C3: 窗口属主 PID 与期望错位 → windowPIDMismatch(带双方 PID)",
              SessionWindowRegistry.decideBindingVerification(pidExists: true, windowEntry: winEntry(200), expectedPID: 100)
              == .windowPIDMismatch(expectedPID: 100, actualPID: 200))
        check("pureSweep2 C4: 属主一致 → valid",
              SessionWindowRegistry.decideBindingVerification(pidExists: true, windowEntry: winEntry(100), expectedPID: 100)
              == .valid)

        // D. Hook 端口钳制：normalizePort 硬钳；clampedUserPort 的 0=恢复默认语义。
        check("pureSweep2 D1: normalizePort 双边钳制（1023→1024 / 65536→65535）",
              ClaudeHookPreferences.normalizePort(1023) == 1024
              && ClaudeHookPreferences.normalizePort(1024) == 1024
              && ClaudeHookPreferences.normalizePort(65535) == 65535
              && ClaudeHookPreferences.normalizePort(65536) == 65535)
        check("pureSweep2 D2: clampedUserPort——0=恢复默认，非 0 同钳制",
              ClaudeHookPreferences.clampedUserPort(0, defaultValue: 8787) == 8787
              && ClaudeHookPreferences.clampedUserPort(99999, defaultValue: 8787) == 65535)

        // B92 补：并行重构产物直测——isInQuietHours（私有助手经 internal 化直测）与
        // ProjectSoundResolver.ruleMatches（双侧归一比较）。
        func at2(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: h))! }
        check("quietHelper: 同日窗 9..<18（含头不含尾）",
              SoundPlayGate.isInQuietHours(date: at2(9), startHour: 9, endHour: 18, calendar: cal)
              && SoundPlayGate.isInQuietHours(date: at2(17), startHour: 9, endHour: 18, calendar: cal)
              && !SoundPlayGate.isInQuietHours(date: at2(18), startHour: 9, endHour: 18, calendar: cal)
              && !SoundPlayGate.isInQuietHours(date: at2(8), startHour: 9, endHour: 18, calendar: cal))
        check("quietHelper: 跨午夜 22..6 → OR 语义",
              SoundPlayGate.isInQuietHours(date: at2(23), startHour: 22, endHour: 6, calendar: cal)
              && SoundPlayGate.isInQuietHours(date: at2(2), startHour: 22, endHour: 6, calendar: cal)
              && !SoundPlayGate.isInQuietHours(date: at2(6), startHour: 22, endHour: 6, calendar: cal)
              && !SoundPlayGate.isInQuietHours(date: at2(21), startHour: 22, endHour: 6, calendar: cal))
        check("quietHelper: start==end 退化 → 常假（正常语义下无静音时段）",
              !SoundPlayGate.isInQuietHours(date: at2(9), startHour: 9, endHour: 9, calendar: cal))
        check("ruleMatch: 双侧归一（大小写/路径末段）等价即匹配",
              ProjectSoundResolver.ruleMatches(ruleName: "MyProj", liveProjectName: "/Users/x/work/myproj")
              && ProjectSoundResolver.ruleMatches(ruleName: "/Users/x/work/MyProj", liveProjectName: "myproj"))
        check("ruleMatch: 不同项目 → false；live 全斜杠归一为 nil → false",
              !ProjectSoundResolver.ruleMatches(ruleName: "alpha", liveProjectName: "beta")
              && !ProjectSoundResolver.ruleMatches(ruleName: "alpha", liveProjectName: "///"))
    }

    // MARK: 零命中纯函数清扫 III（真实实现——保留区自愈推理/屏内本地序，Batch 38）

    do {
        // A. DisplayWorkArea.inferInsets：副屏隐形保留区自愈的推理核心。
        // 坐标语义 = Quartz（minY=顶边，y 向下）。贴边 = 距规划边 <0.5；
        // 学习 = 推离 >1.5 且 ≤200；同边取最小推离；任一格触边（推离 0）→ 该边不学。
        let plan = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func ins(_ t: CGFloat, _ l: CGFloat, _ b: CGFloat, _ r: CGFloat) -> WorkAreaInsets {
            WorkAreaInsets(top: t, left: l, bottom: b, right: r)
        }
        func topCell(_ push: CGFloat) -> CGRect { CGRect(x: 0, y: push, width: 200, height: 40) }
        check("insets A1: 顶部贴边格被推离 25 → 只学 top（菜单栏保留区）",
              DisplayWorkArea.inferInsets(planned: [topCell(0)], actual: [CGRect?(topCell(25))],
                                          planningFrame: plan) == ins(25, 0, 0, 0))
        check("insets A2: 1px 抖动（≤1.5）不算钳制；2px 跨阈学习",
              DisplayWorkArea.inferInsets(planned: [topCell(0)], actual: [CGRect?(topCell(1))],
                                          planningFrame: plan) == .zero
              && DisplayWorkArea.inferInsets(planned: [topCell(0)], actual: [CGRect?(topCell(2))],
                                             planningFrame: plan) == ins(2, 0, 0, 0))
        check("insets A3: 同边取最小推离；任一格触边（推离 0）→ 该边不学习",
              DisplayWorkArea.inferInsets(planned: [topCell(0), topCell(0)],
                                          actual: [CGRect?(topCell(45)), CGRect?(topCell(25))],
                                          planningFrame: plan) == ins(25, 0, 0, 0)
              && DisplayWorkArea.inferInsets(planned: [topCell(0), topCell(0)],
                                             actual: [CGRect?(topCell(45)), CGRect?(topCell(0))],
                                             planningFrame: plan) == .zero)
        check("insets A4: 推离 =maxInset(200) 学习；>200 视为异常读数不学习",
              DisplayWorkArea.inferInsets(planned: [topCell(0)], actual: [CGRect?(topCell(200))],
                                          planningFrame: plan) == ins(200, 0, 0, 0)
              && DisplayWorkArea.inferInsets(planned: [topCell(0)], actual: [CGRect?(topCell(250))],
                                             planningFrame: plan) == .zero)
        check("insets A5: 四边独立推断（top=两格取小 / left=两格取小 / bottom 未贴边不学）",
              DisplayWorkArea.inferInsets(
                planned: [topCell(0), CGRect(x: 300, y: 0, width: 200, height: 40),
                          CGRect(x: 0, y: 300, width: 200, height: 40)],
                actual: [CGRect?(CGRect(x: 25, y: 25, width: 200, height: 40)),
                         CGRect?(CGRect(x: 300, y: 50, width: 200, height: 40)),
                         CGRect?(CGRect(x: 30, y: 300, width: 200, height: 40))],
                planningFrame: plan) == ins(25, 25, 0, 0))
        check("insets A6: 底边 Dock 推离学习（bottom = plan.maxY - act.maxY）；actual=nil 跳过",
              DisplayWorkArea.inferInsets(
                planned: [topCell(0), CGRect(x: 0, y: 1040, width: 200, height: 40)],
                actual: [nil, CGRect?(CGRect(x: 0, y: 1022, width: 200, height: 40))],
                planningFrame: plan) == ins(0, 0, 18, 0))

        // B. resolveDisplayLocalSpaceIndex：全局 space 序 → 屏内本地序（1-based，按 index 升序位次）。
        func spaceInfo(_ display: Int, _ index: Int?) -> YabaiSpaceInfo {
            YabaiSpaceInfo(id: nil, index: index, display: display, isVisible: false)
        }
        let spaces = [spaceInfo(1, 1), spaceInfo(1, 2), spaceInfo(2, 3), spaceInfo(2, 5), spaceInfo(2, nil)]
        check("sweepIII B1: 屏 2 的全局 3/5 → 本地 1/2（按 index 升序位次）",
              SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 2, spaces: spaces) == 1
              && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 5, displayIndex: 2, spaces: spaces) == 2)
        check("sweepIII B2: 不属于该屏的全局序 / 缺输入 → nil",
              SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 1, displayIndex: 2, spaces: spaces) == nil
              && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: nil, displayIndex: 2, spaces: spaces) == nil
              && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: nil, spaces: spaces) == nil
              && SpaceController.resolveDisplayLocalSpaceIndex(spaceIndex: 3, displayIndex: 2, spaces: nil) == nil)
    }
    }
}
