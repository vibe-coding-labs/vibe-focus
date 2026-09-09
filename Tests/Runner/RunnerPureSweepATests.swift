import ApplicationServices
import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerPureSweepATests.swift — B56 自 main.swift 按域拆分（逐字搬移，零内容变更）

extension RunnerHarness {
    func runPureSweepA() {
    // MARK: LayoutFrameCalculator（真实实现——摆位几何，Batch 20）

    do {
        let vis = CGRect(x: 0, y: 0, width: 2000, height: 1000)

        // A. gap=0：与 Rectangle 一致（铺满分割无缝隙）。
        check("layout: leftHalf 铺满左半", LayoutFrameCalculator.frame(for: .leftHalf, visibleFrame: vis) == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        check("layout: rightHalf 铺满右半", LayoutFrameCalculator.frame(for: .rightHalf, visibleFrame: vis) == CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        check("layout: topHalf 铺满上半（Y 向下，top=小 y）", LayoutFrameCalculator.frame(for: .topHalf, visibleFrame: vis) == CGRect(x: 0, y: 0, width: 2000, height: 500))
        check("layout: bottomHalf 铺满下半", LayoutFrameCalculator.frame(for: .bottomHalf, visibleFrame: vis) == CGRect(x: 0, y: 500, width: 2000, height: 500))
        check("layout: 四分（TL/TR/BL/BR）",
              LayoutFrameCalculator.frame(for: .topLeftQuarter, visibleFrame: vis) == CGRect(x: 0, y: 0, width: 1000, height: 500)
              && LayoutFrameCalculator.frame(for: .topRightQuarter, visibleFrame: vis) == CGRect(x: 1000, y: 0, width: 1000, height: 500)
              && LayoutFrameCalculator.frame(for: .bottomLeftQuarter, visibleFrame: vis) == CGRect(x: 0, y: 500, width: 1000, height: 500)
              && LayoutFrameCalculator.frame(for: .bottomRightQuarter, visibleFrame: vis) == CGRect(x: 1000, y: 500, width: 1000, height: 500))
        check("layout: maximize=可见区", LayoutFrameCalculator.frame(for: .maximize, visibleFrame: vis) == vis)
        check("layout: nextDisplay=可见区", LayoutFrameCalculator.frame(for: .nextDisplay, visibleFrame: vis) == vis)

        // B. gap>0：外缘让 gap、接缝让 gap/2。
        let g: CGFloat = 20
        check("layout: gap 左半 span=(w-2g-g/2)/2",
              LayoutFrameCalculator.frame(for: .leftHalf, visibleFrame: vis, gap: g) == CGRect(x: 20, y: 20, width: 975, height: 960))
        check("layout: gap 右半 x=minX+g+span+g/2",
              LayoutFrameCalculator.frame(for: .rightHalf, visibleFrame: vis, gap: g) == CGRect(x: 1005, y: 20, width: 975, height: 960))
        check("layout: gap 四分 BR",
              LayoutFrameCalculator.frame(for: .bottomRightQuarter, visibleFrame: vis, gap: g) == CGRect(x: 1005, y: 505, width: 975, height: 475))

        // C. 极小可见区：max(0,...) 防负尺寸。
        let tiny = CGRect(x: 0, y: 0, width: 5, height: 5)
        let tinyFrame = LayoutFrameCalculator.frame(for: .leftHalf, visibleFrame: tiny, gap: 100)
        check("layout: 极小区防负尺寸（width≥0）", tinyFrame != nil && tinyFrame!.width >= 0)

        // D. center：保持尺寸居中 / 超大钳制 / 无窗口 frame → nil。
        check("layout: center 保持尺寸几何居中",
              LayoutFrameCalculator.frame(for: .center, visibleFrame: vis, windowFrame: CGRect(x: 500, y: 300, width: 400, height: 200))
              == CGRect(x: 800, y: 400, width: 400, height: 200))
        check("layout: center 超大窗口钳到可视区",
              LayoutFrameCalculator.frame(for: .center, visibleFrame: vis, windowFrame: CGRect(x: -50, y: -50, width: 5000, height: 3000))
              == CGRect(x: 0, y: 0, width: 2000, height: 1000))
        check("layout: center 无窗口 frame → nil",
              LayoutFrameCalculator.frame(for: .center, visibleFrame: vis) == nil)
    }

    // MARK: ClaudeHookServer 鉴权门（真实实现——LAN token 三函数纯判定，Batch 27 补做丢失的 Batch 16）

    do {
        // A. resolveHeaderValue：精确命中 / 大小写不敏感回退 / 未命中 nil。
        let headers = ["Content-Type": "application/json", "x-vibefocus-token": "abc"]
        check("hookAuth A1: 精确键直取",
              ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "Content-Type") == "application/json")
        check("hookAuth A2: 大小写不敏感命中（GCDWebServer 保留原始大小写）",
              ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-VibeFocus-Token") == "abc")
        check("hookAuth A3: 未命中 → nil",
              ClaudeHookServer.resolveHeaderValue(from: headers, forKey: "X-Forwarded-For") == nil)

        // B. resolveProvidedToken：query 优先 → header（trim）→ 双缺空串（永不 nil）。
        check("hookAuth B1: query 优先于 header",
              ClaudeHookServer.resolveProvidedToken(query: ["token": "q1"], headers: ["X-VibeFocus-Token": "h1"]) == "q1")
        check("hookAuth B2: 无 query 落 header 并 trim 空白",
              ClaudeHookServer.resolveProvidedToken(query: [:], headers: ["X-VibeFocus-Token": "  h2  "]) == "h2")
        check("hookAuth B3: 双缺 → 空串（非 nil）",
              ClaudeHookServer.resolveProvidedToken(query: [:], headers: [:]) == "")
        check("hookAuth B4: query 空串也算提供（不回退 header）",
              ClaudeHookServer.resolveProvidedToken(query: ["token": ""], headers: ["X-VibeFocus-Token": "h3"]) == "")

        // C. isTokenValid：未配置放行（nil/空串）→ 配置后精确匹配（大小写敏感）。
        check("hookAuth C1: 未配置 token（nil）→ 放行",
              ClaudeHookServer.isTokenValid(expectedToken: nil, providedToken: "anything"))
        check("hookAuth C2: 配置为空串 → 放行（等同未配置）",
              ClaudeHookServer.isTokenValid(expectedToken: "", providedToken: nil))
        check("hookAuth C3: 精确匹配 → 通过",
              ClaudeHookServer.isTokenValid(expectedToken: "secret", providedToken: "secret"))
        check("hookAuth C4: 大小写不匹配 → 拒绝",
              !ClaudeHookServer.isTokenValid(expectedToken: "secret", providedToken: "Secret"))
        check("hookAuth C5: 值不同 → 拒绝",
              !ClaudeHookServer.isTokenValid(expectedToken: "secret", providedToken: "wrong"))
        check("hookAuth C6: 未提供（空串/nil）→ 拒绝",
              !ClaudeHookServer.isTokenValid(expectedToken: "secret", providedToken: "")
              && !ClaudeHookServer.isTokenValid(expectedToken: "secret", providedToken: nil))

        // C7. serverNeedsRestart：重启判定纯函数（2026-09-10 LAN 模块审计修复——
        // 绑定模式曾是判定盲区：服务运行中翻转「局域网模式」不重绑定，
        // 开 LAN 无效、关 LAN 继续暴露 0.0.0.0 直到重启 app）。
        let baseArgs = (isRunning: true, activePort: Optional(39277),
                        configuredToken: Optional("tok"), configuredBindToLocalhost: Optional(true))
        check("hookAuth C7a: 同端口同 token 同绑定模式 → 不重启",
              !ClaudeHookServer.serverNeedsRestart(
                isRunning: baseArgs.isRunning, activePort: baseArgs.activePort,
                configuredToken: baseArgs.configuredToken,
                configuredBindToLocalhost: baseArgs.configuredBindToLocalhost,
                port: 39277, token: "tok", bindToLocalhost: true))
        check("hookAuth C7b: 仅绑定模式翻转（开/关 局域网模式）→ 必须重启重绑定",
              ClaudeHookServer.serverNeedsRestart(
                isRunning: baseArgs.isRunning, activePort: baseArgs.activePort,
                configuredToken: baseArgs.configuredToken,
                configuredBindToLocalhost: baseArgs.configuredBindToLocalhost,
                port: 39277, token: "tok", bindToLocalhost: false))
        check("hookAuth C7c: 端口或 token 变化 → 重启",
              ClaudeHookServer.serverNeedsRestart(
                isRunning: baseArgs.isRunning, activePort: baseArgs.activePort,
                configuredToken: baseArgs.configuredToken,
                configuredBindToLocalhost: baseArgs.configuredBindToLocalhost,
                port: 39278, token: "tok", bindToLocalhost: true)
              && ClaudeHookServer.serverNeedsRestart(
                isRunning: baseArgs.isRunning, activePort: baseArgs.activePort,
                configuredToken: baseArgs.configuredToken,
                configuredBindToLocalhost: baseArgs.configuredBindToLocalhost,
                port: 39277, token: "tok2", bindToLocalhost: true))
        check("hookAuth C7d: 未运行 → 重启（首次启动）",
              ClaudeHookServer.serverNeedsRestart(
                isRunning: false, activePort: nil, configuredToken: nil,
                configuredBindToLocalhost: nil,
                port: 39277, token: "tok", bindToLocalhost: true))
        check("hookAuth C7e: 绑定模式由 nil 转正（旧实例升级后首轮判定）→ 重启",
              ClaudeHookServer.serverNeedsRestart(
                isRunning: true, activePort: 39277, configuredToken: "tok",
                configuredBindToLocalhost: nil,
                port: 39277, token: "tok", bindToLocalhost: true))
    }

    // MARK: Overlay 偏好层 + Space 解码漂移补缺（真实实现——B28：缺口审计零覆盖直测）

    do {
        // IndexPosition：6 形态 rawValue 双向 + 展示映射互异（设置 Picker 唯一事实源）。
        check("idxPos: 6 case + rawValue 双向回环",
              IndexPosition.allCases.count == 6
              && IndexPosition.allCases.allSatisfy { IndexPosition(rawValue: $0.rawValue) == $0 })
        let names = IndexPosition.allCases.map(\.displayName)
        check("idxPos: displayName 互异非空",
              names.allSatisfy { !$0.isEmpty } && Set(names).count == 6)
        check("idxPos: icon 全非空",
              IndexPosition.allCases.allSatisfy { !$0.icon.isEmpty })
        let jsonStr: (String) -> Data = { Data(("\"" + $0 + "\"").utf8) }
        check("idxPos: JSON 按 rawValue 解码 + 垃圾值 → nil",
              (try? JSONDecoder().decode(IndexPosition.self, from: jsonStr("topCenter"))) == .topCenter
              && (try? JSONDecoder().decode(IndexPosition.self, from: jsonStr("junk"))) == nil)
    }

    do {
        // CodableColor：Codable 契约（键名 + 分量保真）——漂移会静默重置用户配色。
        //（自定义 init(Color) 抑制了 memberwise，故经解码构造实例。）
        func decodeColor(_ data: Data) throws -> CodableColor {
            try JSONDecoder().decode(CodableColor.self, from: data)
        }
        let c = try? decodeColor(Data(#"{"red":0.25,"green":0.5,"blue":0.75,"opacity":0.8}"#.utf8))
        check("codableColor: 解码分量保真",
              c?.red == 0.25 && c?.green == 0.5 && c?.blue == 0.75 && c?.opacity == 0.8)
        let back = c.flatMap { try? decodeColor(JSONEncoder().encode($0)) }
        check("codableColor: 编解码回环保真",
              back?.red == 0.25 && back?.green == 0.5 && back?.blue == 0.75 && back?.opacity == 0.8)
        let keys = (c.flatMap { try? JSONEncoder().encode($0) })
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] }
        check("codableColor: 键集锁定 rgba 四键",
              keys?["red"] == 0.25 && keys?["green"] == 0.5 && keys?["blue"] == 0.75
              && keys?["opacity"] == 0.8 && keys?.count == 4)
    }

    do {
        // legacy 迁移解码（纯函数）：旧格式缺 panelScale/panelMargin → 补默认；per-screen 强制开。
        let legacyMinimal = """
        {"isEnabled":true,"position":"bottomLeft","fontSize":32,"opacity":0.5,
         "textColor":{"red":1,"green":1,"blue":1,"opacity":1},
         "backgroundColor":{"red":0,"green":0,"blue":0,"opacity":0.6},
         "yabaiPath":"/opt/homebrew/bin/yabai"}
        """
        let migrated = ScreenIndexPreferences.loadLegacyPreferences(from: Data(legacyMinimal.utf8))
        check("screenPrefs: legacy 最小格式补默认 scale/margin + per-screen 强制",
              migrated?.panelScale == 1.0 && migrated?.panelMargin == 20
              && migrated?.usePerScreenSpaceIndexing == true
              && migrated?.position == .bottomLeft
              && migrated?.yabaiPath == "/opt/homebrew/bin/yabai")
        let legacyFull = """
        {"isEnabled":false,"position":"topCenter","fontSize":64,"opacity":0.9,
         "textColor":{"red":1,"green":0,"blue":0,"opacity":1},
         "backgroundColor":{"red":0,"green":0,"blue":1,"opacity":0.5},
         "panelScale":2.0,"panelMargin":10,"yabaiPath":null}
        """
        let full = ScreenIndexPreferences.loadLegacyPreferences(from: Data(legacyFull.utf8))
        check("screenPrefs: legacy 完整格式字段保真",
              full?.panelScale == 2.0 && full?.panelMargin == 10
              && full?.isEnabled == false && full?.fontSize == 64 && full?.yabaiPath == nil)
        check("screenPrefs: legacy 非法 JSON → nil",
              ScreenIndexPreferences.loadLegacyPreferences(from: Data("not-json".utf8)) == nil)
        check("screenPrefs: legacy 缺必填字段 → nil",
              ScreenIndexPreferences.loadLegacyPreferences(from: Data(#"{"isEnabled":true}"#.utf8)) == nil)

        // enforce 守卫安全侧：已 per-screen → 原样返回（迁移分支带 save 落库副作用，不在此测）。
        let already = ScreenIndexPreferences.default
        let enforced = ScreenIndexPreferences.enforcePerScreenSpaceIndexingIfNeeded(already)
        check("screenPrefs: 已 per-screen → 原样返回",
              enforced.isEnabled == already.isEnabled && enforced.position == already.position
              && enforced.usePerScreenSpaceIndexing == true)
    }

    do {
        // YabaiSpaceInfo.is-visible 漂移防御（与 YabaiWindowInfo 同族知识，Space 查询路径消费）。
        func decodeSpace(_ json: String) -> YabaiSpaceInfo? {
            try? JSONDecoder().decode(YabaiSpaceInfo.self, from: Data(json.utf8))
        }
        check("spaceInfo: is-visible Bool true",
              decodeSpace(#"{"index":2,"display":1,"is-visible":true}"#)?.isVisible == true)
        check("spaceInfo: is-visible Int 1/0 双形态",
              decodeSpace(#"{"is-visible":1}"#)?.isVisible == true
              && decodeSpace(#"{"is-visible":0}"#)?.isVisible == false)
        check("spaceInfo: 字段缺失 → nil 不炸",
              decodeSpace("{}")?.isVisible == nil && decodeSpace("{}")?.index == nil)
        check("spaceInfo: 垃圾类型 → nil",
              decodeSpace(#"{"is-visible":"yes"}"#)?.isVisible == nil)
        let di = try? JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(#"{"index":1,"frame":{"x":0,"y":0,"w":100,"h":50}}"#.utf8))
        check("displayInfo: index + frame 解析",
              di?.index == 1 && di?.frame?.w == 100 && di?.frame?.h == 50)
    }

    // MARK: 会话绑定决策 + yabai 环境探针（真实实现——B29：镜像转直测 + 零覆盖注入式模块）

    do {
        // decideSessionBindingStep 三分支：有绑定先验证；自愈只救"无绑定"（Standalone 镜像的存在理由消解）。
        check("bindStep: 有绑定 → verifyExisting（label 在场也不改道）",
              HookEventHandler.decideSessionBindingStep(hasBinding: true, machineLabel: "lab-1") == .verifyExisting)
        check("bindStep: 无绑定 + label 非空 → attemptSelfHeal",
              HookEventHandler.decideSessionBindingStep(hasBinding: false, machineLabel: "lab-1") == .attemptSelfHeal)
        check("bindStep: 无绑定 + label 空串 → giveUp",
              HookEventHandler.decideSessionBindingStep(hasBinding: false, machineLabel: "") == .giveUp)
        check("bindStep: 无绑定 + label nil → giveUp",
              HookEventHandler.decideSessionBindingStep(hasBinding: false, machineLabel: nil) == .giveUp)
        check("bindStep: 边界——纯空白 label 非空 → attemptSelfHeal（实现语义：isEmpty 判定）",
              HookEventHandler.decideSessionBindingStep(hasBinding: false, machineLabel: "  ") == .attemptSelfHeal)
    }

    do {
        // YabaiEnvironmentProbe：判定逻辑全注入（生产 ShellRunner，测试假 runner），三层探测与
        // float 布局保守策略（v7 --space 静默失效事故）锁分支。
        func profile(_ layouts: [YabaiSpaceLayout], binary: Bool = true, daemon: Bool = true) -> YabaiEnvironmentProfile {
            YabaiEnvironmentProfile(
                binaryPresent: binary, binaryPath: binary ? "/yabai" : nil,
                daemonResponsive: daemon, versionString: daemon ? "yabai-v7.1.18" : nil,
                spaces: layouts
            )
        }
        let floatOnly = [YabaiSpaceLayout(index: 1, display: 1, layout: "float")]
        let bspOnly = [YabaiSpaceLayout(index: 1, display: 1, layout: "bsp")]
        let mixed = [floatOnly[0], YabaiSpaceLayout(index: 2, display: 1, layout: "bsp")]
        check("probeProfile: usable = L1+L2 双过（缺一即 false）",
              profile(floatOnly).usableAsEnhancer
              && !profile(floatOnly, daemon: false).usableAsEnhancer
              && !profile(floatOnly, binary: false).usableAsEnhancer)
        check("probeProfile: isAllFloat 空 → false；全 float → true；混 bsp → false",
              !profile([]).isAllFloatLayout && profile(floatOnly).isAllFloatLayout
              && !profile(mixed).isAllFloatLayout)
        check("probeProfile: hasBSPSpace 见 bsp 即 true（空 → false）",
              profile(mixed).hasBSPSpace && profile(bspOnly).hasBSPSpace
              && !profile(floatOnly).hasBSPSpace && !profile([]).hasBSPSpace)
        check("probeProfile: spaceMoveTrusted 保守策略——任一 float 即不信任 + 空 spaces 不信任",
              profile(bspOnly).spaceMoveTrusted
              && !profile(mixed).spaceMoveTrusted && !profile(floatOnly).spaceMoveTrusted
              && !profile([]).spaceMoveTrusted
              && !profile(bspOnly, daemon: false).spaceMoveTrusted)

        // parseSpaces：宽松语义（部分信息优于失败），index/display 缺一丢条目，type 缺 → unknown。
        let spacesJSON = """
        [{"index":1,"display":1,"type":"float"},{"index":2,"display":1,"type":"bsp"},
         {"display":1,"type":"bsp"},{"index":3,"type":"float"},{"index":4,"display":2}]
        """
        let parsed = YabaiEnvironmentProbe.parseSpaces(spacesJSON)
        check("probeParse: 有效条目解析 + 缺 index/display 丢弃",
              parsed.count == 3 && parsed[0].layout == "float" && parsed[1].layout == "bsp"
              && parsed[2].index == 4 && parsed[2].display == 2 && parsed[2].layout == "unknown")
        check("probeParse: type 缺失 → unknown",
              YabaiEnvironmentProbe.parseSpaces(#"[{"index":9,"display":1}]"#).first?.layout == "unknown")
        check("probeParse: 非法 JSON / 空输入 → 空数组不炸",
              YabaiEnvironmentProbe.parseSpaces("not-json").isEmpty
              && YabaiEnvironmentProbe.parseSpaces("").isEmpty)

        // locateBinary：注入 fileExists——首个存在者胜出；全缺 → nil。
        check("probeL1: 候选按序首个存在者",
              YabaiEnvironmentProbe.locateBinary(fileExists: { $0 == "/usr/local/bin/yabai" })
              == "/usr/local/bin/yabai")
        check("probeL1: 全部不存在 → nil",
              YabaiEnvironmentProbe.locateBinary(fileExists: { _ in false }) == nil)

        // probe 三层编排：L1 挡 → L2 挡（fork 失败与非零等价）→ 全通过（版本 trim + spaces 解析）。
        check("probe编排: L1 失败 → 全 false profile",
              YabaiEnvironmentProbe.probe(
                runner: { _, _ in (0, "[]") },
                fileExists: { _ in false }
              ).binaryPresent == false)
        check("probe编排: L2 非零退出 → binary 在场 daemon 失败 spaces 空",
              { let p = YabaiEnvironmentProbe.probe(
                    runner: { _, _ in (1, "") },
                    fileExists: { _ in true })
                return p.binaryPresent && !p.daemonResponsive && p.spaces.isEmpty }())
        check("probe编排: L2 fork 失败（nil）与非零等价",
              { let p = YabaiEnvironmentProbe.probe(
                    runner: { _, _ in nil },
                    fileExists: { _ in true })
                return !p.daemonResponsive && !p.usableAsEnhancer }())
        check("probe编排: 全通过 → 版本 trim + spaces 解析 + 增强可用",
              { let p = YabaiEnvironmentProbe.probe(
                    runner: { path, args in
                        args == ["--version"] ? (0, "  yabai-v7.1.18\n") : (0, #"[{"index":1,"display":1,"type":"bsp"}]"#)
                    },
                    fileExists: { _ in true })
                return p.usableAsEnhancer && p.versionString == "yabai-v7.1.18"
                    && p.spaces.first?.layout == "bsp" && p.spaceMoveTrusted }())
    }

    // MARK: TitleEditor 脚本决策表（真实实现——AppleScript 模板/verdict/诊断纯决策，Batch 29）

    do {
        // A. 模板决策表四分支（+ 不支持跳过）。
        let termTTY = TitleEditorService.makeTitleScript(bundleID: "com.apple.Terminal", title: "t1", targetTTY: "ttys001")!
        check("titleScript A1: Terminal 定向 tty 寻址 + 双哨兵",
              termTTY.contains(#"if tty of t = "ttys001""#) && termTTY.contains(#"return "matched""#) && termTTY.contains(#"return "not_found""#))
        let termFront = TitleEditorService.makeTitleScript(bundleID: "com.apple.Terminal", title: "t2", targetTTY: nil)!
        check("titleScript A2: Terminal 回退 front window（无 repeat）",
              termFront.contains("selected tab of front window") && !termFront.contains("repeat"))
        let itermTTY = TitleEditorService.makeTitleScript(bundleID: "com.googlecode.iterm2", title: "t3", targetTTY: "ttys002")!
        check("titleScript A3: iTerm2 定向 session tty + 双哨兵",
              itermTTY.contains(#"if tty of s = "ttys002""#) && itermTTY.contains("set name of s to") && itermTTY.contains(#"return "not_found""#))
        let itermFront = TitleEditorService.makeTitleScript(bundleID: "com.googlecode.iterm2", title: "t4", targetTTY: nil)!
        check("titleScript A4: iTerm2 回退 current session",
              itermFront.contains("set name of current session of current window") && !itermFront.contains("repeat"))
        check("titleScript A5: 不支持 bundleID → nil",
              TitleEditorService.makeTitleScript(bundleID: "com.apple.Safari", title: "x", targetTTY: "ttys001") == nil)

        // B. 寻址铁律 + 转义（回归史：window id 与 CGWindowNumber 不同源，禁用）。
        let tricky = #"my \proj "x""#
        let all4 = [
            TitleEditorService.makeTitleScript(bundleID: "com.apple.Terminal", title: tricky, targetTTY: "ttys001")!,
            TitleEditorService.makeTitleScript(bundleID: "com.apple.Terminal", title: tricky, targetTTY: nil)!,
            TitleEditorService.makeTitleScript(bundleID: "com.googlecode.iterm2", title: tricky, targetTTY: "ttys001")!,
            TitleEditorService.makeTitleScript(bundleID: "com.googlecode.iterm2", title: tricky, targetTTY: nil)!,
        ]
        check("titleScript B1: 四分支模板全部不含 window id 寻址（寻址铁律）",
              all4.allSatisfy { !$0.contains("window id") })
        check("titleScript B2: 引号在模板内已转义",
              all4.allSatisfy { $0.contains(#"my \\proj \"x\""#) })
        check("titleScript B3: 转义函数反斜杠优先（防二次转义）",
              TitleEditorService.escapingAppleScriptString("a\\b") == "a\\\\b")

        // C. verdict 哨兵判定。
        check("titleScript C: 只有 matched 算命中",
              TitleEditorService.isMatchedVerdict("matched")
              && !TitleEditorService.isMatchedVerdict("not_found")
              && !TitleEditorService.isMatchedVerdict(nil))

        // D. Terminal 诊断回读模板。
        let diagTTY = TitleEditorService.makeTerminalDiagnosticScript(targetTTY: "ttys003")
        check("titleScript D1: 诊断定向 tty + target_gone 哨兵",
              diagTTY.contains(#"if tty of t = "ttys003""#) && diagTTY.contains(#"return "target_gone""#))
        let diagFront = TitleEditorService.makeTerminalDiagnosticScript(targetTTY: nil)
        check("titleScript D2: 诊断回退 front window（无 repeat）",
              diagFront.contains("front window") && !diagFront.contains("repeat"))
    }

    // MARK: 偏好解码去重助手 + 语音模式映射（真实实现——B30：load 四源重复块提纯后锁行为）

    do {
        let currentJSON = """
        {"isEnabled":true,"position":"topRight","fontSize":48,"opacity":0.8,
         "textColor":{"red":1,"green":1,"blue":1,"opacity":1},
         "backgroundColor":{"red":0,"green":0,"blue":0,"opacity":0.6},
         "panelScale":1.0,"panelMargin":20,"yabaiPath":null,
         "usePerScreenSpaceIndexing":true}
        """
        let current = ScreenIndexPreferences.decodeWithLegacyFallback(
            Data(currentJSON.utf8), source: "test", savesLegacyUpgrade: false)
        check("screenPrefsHelper: 当前格式直通（enforce 无迁移不落库）",
              current?.isEnabled == true && current?.position == .topRight
              && current?.usePerScreenSpaceIndexing == true)
        let legacyJSON = """
        {"isEnabled":false,"position":"bottomCenter","fontSize":24,"opacity":0.5,
         "textColor":{"red":1,"green":1,"blue":1,"opacity":1},
         "backgroundColor":{"red":0,"green":0,"blue":0,"opacity":0.5}}
        """
        let migrated = ScreenIndexPreferences.decodeWithLegacyFallback(
            Data(legacyJSON.utf8), source: "test", savesLegacyUpgrade: false)
        check("screenPrefsHelper: legacy 回落迁移（不回写升级）",
              migrated?.position == .bottomCenter && migrated?.panelScale == 1.0
              && migrated?.panelMargin == 20 && migrated?.usePerScreenSpaceIndexing == true)
        check("screenPrefsHelper: 双格式皆非 → nil",
              ScreenIndexPreferences.decodeWithLegacyFallback(
                Data("junk".utf8), source: "test", savesLegacyUpgrade: false) == nil)

        // VoiceAnnouncementMode：4 形态 rawValue 回环 + 展示映射互异（设置 Picker 事实源）。
        check("voiceMode: 4 case + rawValue 双向回环",
              VoiceAnnouncementMode.allCases.count == 4
              && VoiceAnnouncementMode.allCases.allSatisfy { VoiceAnnouncementMode(rawValue: $0.rawValue) == $0 })
        let voiceNames = VoiceAnnouncementMode.allCases.map(\.displayName)
        check("voiceMode: displayName 互异非空",
              voiceNames.allSatisfy { !$0.isEmpty } && Set(voiceNames).count == 4)
    }

    // MARK: Doctor 取证纯逻辑（真实实现——B31：镜像转直测，退出审计语义锁进真身）

    do {
        // parseJournalLine：三种事件行 + 容错（install 行无 pid 占位 -1、未知 kind/junk → nil）。
        let launch = Doctor.parseJournalLine(#"{"kind":"launch","pid":123,"at":"T1","exe":"/app/VF","ax":true}"#)
        check("doctor: launch 行解析 pid/at/exe/ax",
              launch?.kind == "launch" && launch?.pid == 123 && launch?.at == "T1"
              && launch?.exe == "/app/VF" && launch?.ax == true)
        let exit = Doctor.parseJournalLine(#"{"kind":"exit","pid":9,"at":"T2","reason":"signal","name":"SIGTRAP"}"#)
        check("doctor: exit 行 name → signalName",
              exit?.signalName == "SIGTRAP" && exit?.reason == "signal")
        check("doctor: install 行无 pid → 占位 -1",
              Doctor.parseJournalLine(#"{"kind":"install","at":"T3","reason":"rebuild"}"#)?.pid == -1)
        check("doctor: 未知 kind / 非法 JSON → nil",
              Doctor.parseJournalLine(#"{"kind":"other"}"#) == nil
              && Doctor.parseJournalLine("not-json") == nil)

        // accessibilityFlips：相邻 launch 间 ax 翻转检测（2026-09-06 TCC 毒化实证语义）。
        func l(_ pid: Int32, _ at: String, _ ax: Bool?) -> Doctor.JournalEvent {
            Doctor.JournalEvent(kind: "launch", pid: pid, at: at, reason: nil, signalName: nil, exe: nil, ax: ax)
        }
        let flipDown = Doctor.accessibilityFlips(events: [l(1, "A", true), l(2, "B", false)])
        check("doctor: true→false 翻转捕获（授权失效）",
              flipDown.count == 1 && flipDown[0].contains("true→false") && flipDown[0].contains("pid=2"))
        check("doctor: false→true 翻转捕获（重新授权）",
              Doctor.accessibilityFlips(events: [l(1, "A", false), l(2, "B", true)])
              .first?.contains("false→true") == true)
        check("doctor: 同值/nil 轴不误报（nil 轴跳过不阻断链）",
              Doctor.accessibilityFlips(events: [l(1, "A", true), l(2, "B", true)]).isEmpty
              && Doctor.accessibilityFlips(events: [l(1, "A", true), l(2, "B", nil), l(3, "C", false)])
              .count == 1)

        // unmatchedLaunches：launch 无配对 exit = 外部击杀实证（SIGKILL/断电）。
        func e(_ pid: Int32, _ at: String) -> Doctor.JournalEvent {
            Doctor.JournalEvent(kind: "exit", pid: pid, at: at, reason: "x", signalName: nil, exe: nil, ax: nil)
        }
        let unmatched = Doctor.unmatchedLaunches(events: [
            l(1, "A", nil), e(1, "B"), l(2, "C", nil), l(3, "D", nil), e(9, "E"), l(4, "F", nil)
        ])
        check("doctor: 配对抵消 + 无配对按 at 排序",
              unmatched.map(\.pid) == [2, 3, 4])

        // runtimeAXFlipLine：count<=0 不占版面；direction/lastAt 缺失容错。
        check("doctor: 翻转摘要 count<=0 → nil",
              Doctor.runtimeAXFlipLine(count: 0, direction: "x", lastAt: 1) == nil
              && Doctor.runtimeAXFlipLine(count: -1, direction: nil, lastAt: 0) == nil)
        check("doctor: 翻转摘要格式 + 缺失容错 ?",
              Doctor.runtimeAXFlipLine(count: 3, direction: "true→false", lastAt: 0)?
              .contains("3 次") == true
              && Doctor.runtimeAXFlipLine(count: 2, direction: nil, lastAt: 0)?.contains("@ ?") == true)
    }

    // MARK: Toggle restore 决策树（真实实现——decideRestore 六分支穷举，Batch 30）

    do {
        let mainScreen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        func rec(orig: CGRect, target: CGRect, id: UInt32 = 42) -> ToggleRecord {
            ToggleRecord(windowID: id, pid: 100, bundleIdentifier: nil, appName: "T",
                         origFrame: orig, sourceSpace: 2, sourceDisplay: 0, sourceYabaiDisp: 2,
                         sourceDispSpace: 1, targetFrame: target, targetDisplay: 1,
                         toggledAt: Date(), sessionID: nil)
        }
        // A. 六分支穷举（守护顺序：nil 焦点 → 副屏短路 → 无 record → 无主屏 → corrupted → restore）。
        check("toggleDecision A1: 焦点未知 → noFocusedWindow（最优先，其余输入无关）",
              WindowManager.decideRestore(focusedOnMain: nil, recordByWindowID: nil, mainScreenFrame: nil) == .noFocusedWindow)
        check("toggleDecision A2: 焦点在副屏 → moveToMain（record/屏幕输入短路不读）",
              WindowManager.decideRestore(focusedOnMain: false, recordByWindowID: nil, mainScreenFrame: nil) == .moveToMain
              && WindowManager.decideRestore(focusedOnMain: false,
                                             recordByWindowID: rec(orig: .zero, target: .zero),
                                             mainScreenFrame: mainScreen) == .moveToMain)
        check("toggleDecision A3: 主屏焦点但无 record → noRecord",
              WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: nil, mainScreenFrame: mainScreen) == .noRecord)
        check("toggleDecision A4: 有 record 但主屏 frame 未知 → noMainScreen",
              WindowManager.decideRestore(focusedOnMain: true,
                                          recordByWindowID: rec(orig: .zero, target: .zero),
                                          mainScreenFrame: nil) == .noMainScreen)
        check("toggleDecision A5: orig 中心在主屏内（corrupted record）→ corruptedClearWindowID(42)",
              WindowManager.decideRestore(focusedOnMain: true,
                                          recordByWindowID: rec(orig: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                                target: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                                          mainScreenFrame: mainScreen)
              == .corruptedClearWindowID(42))
        check("toggleDecision A6: orig 中心在主屏外 + target 在主屏内 → restore",
              WindowManager.decideRestore(focusedOnMain: true,
                                          recordByWindowID: rec(orig: CGRect(x: -1000, y: 100, width: 200, height: 200),
                                                                target: CGRect(x: 100, y: 100, width: 800, height: 600)),
                                          mainScreenFrame: mainScreen)
              == .restore)
        // B. route 映射真身侧回归（Batch 5 的 (decision, onMainScreen) 失真组合覆盖）。
        check("toggleDecision B1: restore → restore 路由（忽略归属输入）",
              WindowManager.route(for: .restore, onMainScreen: nil) == .restore
              && WindowManager.route(for: .restore, onMainScreen: true) == .restore)
        check("toggleDecision B2: moveToMain 在主屏 → stuck / 未知归属 → move_to_main（日志失真修复回归）",
              WindowManager.route(for: .moveToMain, onMainScreen: true) == .moveSecondaryStuck
              && WindowManager.route(for: .moveToMain, onMainScreen: nil) == .moveToMain
              && WindowManager.route(for: .noRecord, onMainScreen: false) == .moveToMain)
    }

    // MARK: 依赖注入编排层直测（真实实现——B32：SessionWindowRegistry store 注入 + CodexHookPreferences 路径注入）

    do {
        // CodexHookPreferences：home/path/scriptPath 全注入——整链直测零真身 IO（原 ~151 行 0% 覆盖）。
        let home = "/tmp/vibefocus-b32-home-\(getpid())"
        let cfgPath = CodexHookPreferences.codexConfigPath(home: home)
        check("codex: 路径拼接 home 注入",
              cfgPath == home + "/.codex/hooks.json"
              && CodexHookPreferences.codexConfigDir(home: home) == home + "/.codex")
        check("codex isInstalled: 文件缺失/非法 JSON → false",
              CodexHookPreferences.isHookInstalled(at: cfgPath) == false)
        let script = ClaudeHookPreferences.helperScriptPath
        func entry(_ command: String) -> [[String: Any]] {
            [["matcher": "*", "hooks": [["type": "command", "command": command]]]]
        }
        func writeJSON(_ obj: [String: Any], to path: String) {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try? JSONSerialization.data(withJSONObject: obj)
            try? data?.write(to: URL(fileURLWithPath: path))
        }
        writeJSON(["Stop": entry(script)], to: cfgPath)
        check("codex isInstalled: 嵌套 command 含脚本路径 → true",
              CodexHookPreferences.isHookInstalled(at: cfgPath) == true)
        writeJSON(["Stop": entry("/usr/bin/other-hook")], to: cfgPath)
        check("codex isInstalled: 非 VibeFocus 条目 → false",
              CodexHookPreferences.isHookInstalled(at: cfgPath) == false)

        // cleanVibeFocusHooks：精准移除匹配条目、保留他方条目、清空事件键回收。
        let targetURL = "http://127.0.0.1:8765/hook"
        var mixed: [String: Any] = [
            "Stop": entry(script) + entry("/usr/bin/user-own"),
            "PreToolUse": entry("/usr/bin/foreign"),
            "SessionEnd": [["matcher": "*", "hooks": [["type": "command", "url": targetURL]]]],
        ]
        CodexHookPreferences.cleanVibeFocusHooks(from: &mixed, scriptPath: script, targetURL: targetURL)
        let stopEntries = mixed["Stop"] as? [[String: Any]]
        let preEntries = mixed["PreToolUse"] as? [[String: Any]]
        check("codex clean: 匹配条目移除 + 他方条目保留 + url 形态旧条目同清（唯一判据统一）",
              stopEntries?.count == 1 && preEntries?.count == 1
              && mixed["SessionEnd"] == nil && mixed.count == 2)
        var onlyOurs: [String: Any] = ["SessionStart": entry(script)]
        CodexHookPreferences.cleanVibeFocusHooks(from: &onlyOurs, scriptPath: script, targetURL: targetURL)
        check("codex clean: 清空后事件键回收", onlyOurs.isEmpty)

        // mergedHooks：保他方 + 换旧我方 + 开关裁剪（SessionEnd/UserPromptSubmit）。
        let ourHooks: [String: Any] = [
            "SessionStart": entry(script), "Stop": entry(script),
            "SessionEnd": entry(script), "UserPromptSubmit": entry(script),
        ]
        let merged = CodexHookPreferences.mergedHooks(
            existing: ["Stop": entry("/old/stale.sh"), "Notification": entry("/usr/bin/n")],
            ourHooks: ourHooks,
            triggerOnSessionEnd: false,
            autoRestoreOnPromptSubmit: true,
            scriptPath: script,
            targetURL: targetURL)
        let mergedStop = merged["Stop"] as? [[String: Any]]
        check("codex merged: 他方保留 + 陈旧我方替换 + SessionEnd 裁剪 + UserPromptSubmit 保留",
              mergedStop?.count == 1
              && (mergedStop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == script
              && merged["Notification"] != nil
              && merged["SessionEnd"] == nil && merged["UserPromptSubmit"] != nil)

        try? FileManager.default.removeItem(atPath: home)
    }

    do {
        // SessionWindowRegistry：store 注入——init 剪枝/bind 拒绝/状态操作持久化整链直测，
        // 无需 VIBEFOCUS_REGISTRY_E2E 环境门控（原编排层 0% 覆盖的根因即不可注入）。
        func mkState(_ wid: UInt32, session: String?, pid: Int32 = 99999) -> WindowState {
            WindowState(
                windowID: wid, pid: pid, tty: nil,
                axWindowNumber: nil, appName: "TestTerminal", bundleIdentifier: nil, title: nil,
                termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                envWindowID: nil, sessionID: session, cwd: nil, model: nil,
                isCompleted: false, createdAt: Date(), updatedAt: Date()
            )
        }
        let dbPath = "/tmp/vibefocus-b32-\(getpid()).db"
        let store = WindowStateStore(dbPath: dbPath)

        // init 剪枝：非终端 PID 的腐坏绑定加载即清（内存 + DB 双清）。
        store.saveWindowState(mkState(9301, session: "b32-corrupt"))
        let reg1 = SessionWindowRegistry(store: store)
        check("di registry: init 剪枝非终端 PID（内存+DB 双清）",
              reg1.windowStates.isEmpty && store.findWindowState(windowID: 9301) == nil)

        // bind 拒绝分支：非终端 PID 不建绑定。
        reg1.bind(
            sessionID: "b32-rej",
            windowIdentity: WindowIdentity(windowID: 9302, pid: 99999, bundleIdentifier: nil,
                                           appName: "TestTerminal", windowNumber: nil, title: "t"))
        check("di registry: bind 非终端 PID → 拒绝无绑定",
              reg1.windowStates.isEmpty && reg1.binding(for: "b32-rej") == nil)

        // 状态操作 × 注入 store：内存变更同步落库（原 B24 语义经 DI 通道无门控复验）。
        let reg2 = SessionWindowRegistry(store: store)
        reg2.windowStates[9303] = mkState(9303, session: "b32-done")
        reg2.sessionAliasWindowID["b32-done"] = 9303
        reg2.markCompleted(sessionID: "b32-done")
        check("di registry: markCompleted 置位落库 + 清别名",
              reg2.windowStates[9303]?.isCompleted == true
              && store.findWindowState(windowID: 9303)?.isCompleted == true
              && reg2.sessionAliasWindowID["b32-done"] == nil)

        reg2.reactivate(sessionID: "b32-done")
        check("di registry: reactivate 复位落库",
              reg2.windowStates[9303]?.isCompleted == false
              && store.findWindowState(windowID: 9303)?.isCompleted == false)

        reg2.remapWindowID(oldWindowID: 9303, newWindowID: 9304)
        check("di registry: remap 内存+DB 双迁移",
              reg2.windowStates[9303] == nil && reg2.windowStates[9304]?.sessionID == "b32-done"
              && store.findWindowState(windowID: 9303) == nil
              && store.findWindowState(windowID: 9304)?.sessionID == "b32-done")

        reg2.clearAllBindings()
        check("di registry: clearAll 内存+DB 双清",
              reg2.windowStates.isEmpty && store.findWindowState(windowID: 9304) == nil)

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: 零命中纯函数清扫（真实实现——保存守卫/窗口过滤/jsonEscape，Batch 31）

    do {
        // A. shouldRejectSave：orig 中心在主屏内即拒绝保存（防主屏窗重复 toggle 落 corrupt record）。
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        check("pureSweep A1: 主屏未知 → 不拒绝（保守放行）",
              !ToggleEngine.shouldRejectSave(origFrame: main, mainScreenFrame: nil))
        check("pureSweep A2: orig 中心在主屏内 → 拒绝",
              ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 100, y: 100, width: 200, height: 200), mainScreenFrame: main))
        check("pureSweep A3: orig 中心在副屏 → 放行",
              !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: -500, y: 100, width: 200, height: 200), mainScreenFrame: main))

        // B. filterWindowsByPID：layer==0 + PID 匹配（菜单栏/ Dock 层与外进程滤除，元数据透传保序）。
        func entry(_ id: UInt32, pid: Int32, layer: Int = 0, name: String? = nil) -> CGWindowEntry {
            var d: [String: Any] = [kCGWindowNumber as String: id,
                                    kCGWindowOwnerPID as String: pid,
                                    kCGWindowLayer as String: layer]
            if let name { d["kCGWindowName"] = name }
            return CGWindowEntry(from: d)!
        }
        let filtered = WindowManager.filterWindowsByPID(
            entries: [entry(1, pid: 100, name: "term"),
                      entry(2, pid: 100, layer: 25),
                      entry(3, pid: 200, name: "other"),
                      entry(4, pid: 100, name: "term2")],
            targetPID: 100, appName: "Terminal", bundleID: "com.apple.Terminal")
        check("pureSweep B1: layer!=0 与外 PID 滤除，命中映射 WindowIdentity（元数据透传）",
              filtered.map(\.windowID) == [1, 4]
              && filtered.allSatisfy { $0.pid == 100 && $0.appName == "Terminal" && $0.bundleIdentifier == "com.apple.Terminal" }
              && filtered[0].title == "term" && filtered[1].title == "term2")
        check("pureSweep B2: 无命中 → 空数组",
              WindowManager.filterWindowsByPID(entries: [entry(9, pid: 200)], targetPID: 100, appName: nil, bundleID: nil).isEmpty)

        // C. ExitJournal.jsonEscape：五类转义 + 控制符 \u + 直通（崩溃/退出审计行安全）。
        check("pureSweep C1: 引号与反斜杠转义",
              ExitJournal.jsonEscape(#"a"b\c"#) == #"a\"b\\c"#)
        check("pureSweep C2: \n\r\t 控制符转义",
              ExitJournal.jsonEscape("a\nb\rc\td") == #"a\nb\rc\td"#)
        check("pureSweep C3: <0x20 控制符转四位十六进制转义",
              ExitJournal.jsonEscape("\u{01}") == #"\u0001"#)
        check("pureSweep C4: 中文直通 + 空串恒等",
              ExitJournal.jsonEscape("中文✓") == "中文✓" && ExitJournal.jsonEscape("") == "")
    }

    // MARK: Minimap live 切换反馈映射（真实实现——结局→文案，Batch 32 用户报告修复）
    do {
        check("spaceSwitch: noDrift → 已是当前工作区（含工作区标注）",
              GridSpaceSwitchFeedback.message(for: .noDrift, label: "2-1").contains("已是当前工作区")
              && GridSpaceSwitchFeedback.message(for: .noDrift, label: "2-1").contains("2-1"))
        check("spaceSwitch: refocused → 已切换到 2-1",
              GridSpaceSwitchFeedback.message(for: .refocused(postSpace: 4), label: "2-1") == "已切换到 2-1")
        check("spaceSwitch: failed → 如实说明（含工作区标注与 SA 事实，不静默）",
              GridSpaceSwitchFeedback.message(for: .failed(postSpace: 4), label: "2-1").contains("无法切换到 2-1")
              && GridSpaceSwitchFeedback.message(for: .failed(postSpace: 4), label: "2-1").contains("SA"))
        check("spaceSwitch: 三态文案互异",
              Set([
                  GridSpaceSwitchFeedback.message(for: .noDrift, label: "2-1"),
                  GridSpaceSwitchFeedback.message(for: .refocused(postSpace: 1), label: "2-1"),
                  GridSpaceSwitchFeedback.message(for: .failed(postSpace: 1), label: "2-1"),
              ]).count == 3)
    }

    // MARK: Claude 偏好路径注入 + SessionStart 路由提纯（真实实现——B33：沿用 B32 注入模式）

    do {
        // SessionStart 前置分流（isRemote 由 machineLabel 派生 → 可达 4 态）。
        func ctx(tty: String? = nil, machine: String? = nil) -> TerminalContext {
            TerminalContext(termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                            weztermPane: nil, tty: tty, ppid: nil,
                            claudeProjectDir: nil, windowID: nil, machineLabel: machine)
        }
        check("ssRoute: nil ctx → noContext",
              HookEventHandler.decideSessionStartRoute(terminalCtx: nil) == .noContext)
        check("ssRoute: 无用 ctx → noContext",
              HookEventHandler.decideSessionStartRoute(terminalCtx: ctx()) == .noContext)
        check("ssRoute: 本地（tty 有用）→ local",
              HookEventHandler.decideSessionStartRoute(terminalCtx: ctx(tty: "/dev/ttys001"))
              == .local(ctx(tty: "/dev/ttys001")))
        check("ssRoute: remote+label → remote 通道携带 ctx 与 label",
              HookEventHandler.decideSessionStartRoute(terminalCtx: ctx(tty: "/dev/ttys001", machine: "srv-1"))
              == .remote(ctx(tty: "/dev/ttys001", machine: "srv-1"), label: "srv-1"))

        // ClaudeHookPreferences：home 注入 + 安装→卸载回环（临时 settings，零真身 IO）。
        let home = "/tmp/vibefocus-b33-home-\(getpid())"
        let settingsPath = ClaudeHookPreferences.claudeSettingsPath(home: home)
        check("claude: 路径拼接 home 注入",
              settingsPath == home + "/.claude/settings.json"
              && ClaudeHookPreferences.claudeSettingsDir(home: home) == home + "/.claude")
        check("claude isInstalled: 缺文件 → false",
              ClaudeHookPreferences.isHookInstalled(at: settingsPath) == false)

        let scriptPath = ClaudeHookPreferences.helperScriptPath
        let targetURL = ClaudeHookPreferences.endpointURLString()
        let generated = ClaudeHookPreferences.generateHooksDict()
        let hooks = HookSettingsComposition.composeDesiredHooks(
            existing: [:], generated: generated, targetURL: targetURL, scriptPath: scriptPath)

        func writeSettings(_ obj: [String: Any]) {
            try? FileManager.default.createDirectory(
                atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
        writeSettings(["hooks": hooks, "model": "claude-opus"])
        check("claude isInstalled: 真实 compose 产物 → true",
              ClaudeHookPreferences.isHookInstalled(at: settingsPath) == true)

        var withForeign = hooks
        withForeign["Notification"] = [["hooks": [["type": "command", "command": "/usr/bin/user-own"]]]]
        writeSettings(["hooks": withForeign, "model": "claude-opus"])
        let (ok, _) = ClaudeHookPreferences.uninstallHookFromClaudeSettings(
            at: settingsPath, removesHelpers: false)
        let after = (try? JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: settingsPath)))) as? [String: Any]
        let afterHooks = after?["hooks"] as? [String: Any]
        check("claude uninstall: 成功 + VibeFocus 清除 + 他方 hook 与无关键保留",
              ok == true
              && ClaudeHookPreferences.isHookInstalled(at: settingsPath) == false
              && afterHooks?["Notification"] != nil && after?["model"] as? String == "claude-opus")
        check("claude uninstall: 缺文件 → false 拒绝",
              ClaudeHookPreferences.uninstallHookFromClaudeSettings(
                at: home + "/.claude/none.json", removesHelpers: false).0 == false)

        try? FileManager.default.removeItem(atPath: home)
    }

    // MARK: SettingsUI 拆分前置（真实实现——B34：34 @State 枢纽的决策逻辑提纯为可测纯类型）

    do {
        // 提示音规则操作：原困在 SoundManager 单例，现落在 SoundPreferences 纯结构直测。
        var prefs = SoundPreferences.default
        check("soundRules: 初始无规则", prefs.projectRules.isEmpty)
        prefs.addProjectRule()
        prefs.addProjectRule()
        check("soundRules: add 默认空名 + Complete 音效",
              prefs.projectRules.count == 2
              && prefs.projectRules[0].projectName == ""
              && prefs.projectRules[0].soundType == .builtinComplete)
        prefs.setProjectRuleName(at: 0, "vibe-labs")
        prefs.setProjectRuleSound(at: 0, .builtinDing)
        check("soundRules: 改名改音效生效",
              prefs.projectRules[0].projectName == "vibe-labs"
              && prefs.projectRules[0].soundType == .builtinDing)
        prefs.setProjectRuleName(at: 9, "越界")
        prefs.setProjectRuleSound(at: -1, .none)
        prefs.removeProjectRule(at: 7)
        check("soundRules: 越界索引三连静默忽略",
              prefs.projectRules.count == 2 && prefs.projectRules[1].projectName == ""
              && prefs.projectRules[1].soundType == .builtinComplete)
        prefs.removeProjectRule(at: 0)
        check("soundRules: remove 命中且余序保持",
              prefs.projectRules.count == 1 && prefs.projectRules[0].soundType == .builtinComplete)

        // 提示音表单钳制：节流非负 + 免打扰小时 0...23。
        prefs.updateMinPlayInterval(-5)
        check("soundClamp: 负节流防御归零", prefs.minPlayIntervalSeconds == 0)
        prefs.updateMinPlayInterval(7)
        check("soundClamp: 正常节流透传", prefs.minPlayIntervalSeconds == 7)
        prefs.updateQuietHours(enabled: true, startHour: -1, endHour: 24)
        check("soundClamp: 免打扰小时钳到 0...23",
              prefs.quietHoursEnabled == true && prefs.quietStartHour == 0 && prefs.quietEndHour == 23)
        prefs.updateQuietHours(enabled: false, startHour: 22, endHour: 8)
        check("soundClamp: 正常时段透传 + 开关独立",
              prefs.quietHoursEnabled == false && prefs.quietStartHour == 22 && prefs.quietEndHour == 8)

        // 端口表单校验（原内联在 ClaudeHookSection Binding 中）。
        check("portForm: 0 恢复默认",
              ClaudeHookPreferences.clampedUserPort(0) == ClaudeHookPreferences.defaultPort)
        check("portForm: 低于 1024 钳到 1024",
              ClaudeHookPreferences.clampedUserPort(-5) == 1024
              && ClaudeHookPreferences.clampedUserPort(80) == 1024)
        check("portForm: 超上钳到 65535 + 合法透传",
              ClaudeHookPreferences.clampedUserPort(70000) == 65535
              && ClaudeHookPreferences.clampedUserPort(8080) == 8080)
        check("portForm: 自定义默认值生效",
              ClaudeHookPreferences.clampedUserPort(0, defaultValue: 9000) == 9000)
    }
    }
}
