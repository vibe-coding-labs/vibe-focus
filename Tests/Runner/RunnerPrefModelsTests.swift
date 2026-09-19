import AppKit
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerPrefModelsTests.swift — B214 偏好模型覆盖补强
// 靶（基线）：InputBubblePreferences 40% / ScreenIndexPreferences 53% /
// SoundPreferencesModels 88% / HookWindowModels 83%。
// UserDefaults 域纪律：Runner 是无 bundle id 的 CLI，standard defaults 落在测试进程
// 私有域，不触生产 plist；块前后快照/还原 12 个键，防止污染同进程其它测试的前提假设。
// ScreenIndexPreferences 只测无副作用分支：任何会触发 .save()（SQLite+CFPreferences
// 三源写生产库）的迁移路径一律不碰，留待注入缝批次。

extension RunnerHarness {
    /// InputBubblePreferences 全部私有键字面量（与源文件逐一对应；键名即用户 defaults 契约）
    private static let bubblePrefKeys = [
        "inputBubbleEnabled", "inputBubbleWidth", "inputBubbleHeight",
        "inputBubbleSubmitOnEnter", "inputBubbleAutoShowOnFocus", "inputBubbleDefaultPrefix",
        "inputBubbleHotKeyConfiguration", "inputBubbleAutoShowOnMoveToMain",
        "inputBubbleAutoRestoreOnSubmit", "inputBubbleAutoHide", "inputBubbleUserFrame",
        "inputBubbleHistoryLimit",
    ]

    func runPrefModelsCoverageTests() {
        let d = UserDefaults.standard
        // 快照/还原（B84 家法）：不依赖 Runner 持久域的先行状态，也不留给后续测试脏值
        var snapshot: [String: Any] = [:]
        for key in Self.bubblePrefKeys {
            if let value = d.object(forKey: key) { snapshot[key] = value }
        }
        defer {
            for key in Self.bubblePrefKeys {
                if let value = snapshot[key] { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
        }

        // A. 未设置回落默认（object==nil 分支；先全键清空）
        do {
            Self.bubblePrefKeys.forEach { d.removeObject(forKey: $0) }
            check("bubblePref A1: isEnabled 未设置=true",
                  InputBubblePreferences.isEnabled == true)
            check("bubblePref A2: submitOnEnter 未设置=false（B161 Enter 换行默认）",
                  InputBubblePreferences.submitOnEnter == false)
            check("bubblePref A3: autoShowOnFocus/autoShowOnMoveToMain/autoRestoreOnSubmit 未设置=true",
                  InputBubblePreferences.autoShowOnFocus
                  && InputBubblePreferences.autoShowOnMoveToMain
                  && InputBubblePreferences.autoRestoreOnSubmit)
            check("bubblePref A4: autoHide 未设置=false（绑定跟随模式默认）",
                  InputBubblePreferences.autoHide == false)
            check("bubblePref A5: defaultPrefix 未设置=空串",
                  InputBubblePreferences.defaultPrefix.isEmpty)
            check("bubblePref A6: hotKey 未设置=默认 ⌃X",
                  InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
            check("bubblePref A7: userPlacedOrigin 未设置=nil（从未拖过）",
                  InputBubblePreferences.userPlacedOrigin == nil)
        }

        // B. 布尔读写往返（true/false 两态落库）
        do {
            InputBubblePreferences.isEnabled = false
            InputBubblePreferences.submitOnEnter = true
            InputBubblePreferences.autoShowOnFocus = false
            InputBubblePreferences.autoShowOnMoveToMain = false
            InputBubblePreferences.autoRestoreOnSubmit = false
            InputBubblePreferences.autoHide = true
            check("bubblePref B1: 六个布尔开关写入后读回一致",
                  InputBubblePreferences.isEnabled == false
                  && InputBubblePreferences.submitOnEnter == true
                  && InputBubblePreferences.autoShowOnFocus == false
                  && InputBubblePreferences.autoShowOnMoveToMain == false
                  && InputBubblePreferences.autoRestoreOnSubmit == false
                  && InputBubblePreferences.autoHide == true)
        }

        // C. 尺寸读写 + 变更广播（真变才发，同值收敛；B84 NoteProbe 家法观察）
        do {
            final class NoteProbe: NSObject {
                var count = 0
                @objc func hit(_ note: Notification) { count += 1 }
            }
            let probe = NoteProbe()
            NotificationCenter.default.addObserver(
                probe, selector: #selector(NoteProbe.hit(_:)),
                name: InputBubblePreferences.sizeDidChangeNotification, object: nil)
            defer { NotificationCenter.default.removeObserver(probe) }

            InputBubblePreferences.bubbleWidth = 500
            check("bubblePref C1: 宽度写入读回（变更广播 1 次）",
                  InputBubblePreferences.bubbleWidth == 500 && probe.count == 1)
            InputBubblePreferences.bubbleWidth = 500
            check("bubblePref C2: 同值写入不广播", probe.count == 1)
            InputBubblePreferences.bubbleHeight = 200
            check("bubblePref C3: 高度写入读回 + 广播",
                  InputBubblePreferences.bubbleHeight == 200 && probe.count == 2)
            InputBubblePreferences.bubbleWidth = 9999
            check("bubblePref C4: 越界写入经 clamp 归一（9999→720）",
                  InputBubblePreferences.bubbleWidth == 720)
        }

        // D. defaultPrefix 原样保留（尾随空格是语义一部分）+ hotKey JSON 往返与坏数据兜底
        do {
            InputBubblePreferences.defaultPrefix = "/goal "
            check("bubblePref D1: defaultPrefix 尾随空格原样保留",
                  InputBubblePreferences.defaultPrefix == "/goal ")

            let custom = HotKeyConfiguration(keyCode: 7, modifiers: 0)
            InputBubblePreferences.hotKey = custom
            check("bubblePref D2: hotKey JSON 编码往返",
                  InputBubblePreferences.hotKey == custom)
            d.set(Data("junk".utf8), forKey: "inputBubbleHotKeyConfiguration")
            check("bubblePref D3: 坏 JSON 回落 defaultConfig（手写 defaults 不致崩）",
                  InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
            d.removeObject(forKey: "inputBubbleHotKeyConfiguration")
            check("bubblePref D4: 键缺失回落 defaultConfig",
                  InputBubblePreferences.hotKey == InputBubbleHotKeyPlan.defaultConfig)
        }

        // E. userPlacedOrigin 拖拽记忆：写入/读回/清除三态
        do {
            InputBubblePreferences.userPlacedOrigin = CGPoint(x: 100, y: 200)
            check("bubblePref E1: 拖拽位置写入读回",
                  InputBubblePreferences.userPlacedOrigin == CGPoint(x: 100, y: 200))
            InputBubblePreferences.userPlacedOrigin = nil
            check("bubblePref E2: 置 nil 清除记忆",
                  InputBubblePreferences.userPlacedOrigin == nil)
        }

        // F. ScreenIndexPreferences 纯域：位置枚举 + Codable 往返 + 无副作用解码
        do {
            let all = IndexPosition.allCases
            check("screenPref F1: 6 个位置 displayName/icon 非空且 rawValue 往返",
                  all.count == 6
                  && all.allSatisfy { !$0.displayName.isEmpty && !$0.icon.isEmpty
                      && IndexPosition(rawValue: $0.rawValue) == $0 })

            let data = try? JSONEncoder().encode(ScreenIndexPreferences.default)
            let decoded = data.flatMap { try? JSONDecoder().decode(ScreenIndexPreferences.self, from: $0) }
            check("screenPref F2: default Codable 往返字段保真",
                  decoded?.isEnabled == true
                  && decoded?.position == .topRight
                  && decoded?.fontSize == 48
                  && decoded?.usePerScreenSpaceIndexing == true
                  && decoded?.textColor.red == ScreenIndexPreferences.default.textColor.red
                  && decoded?.backgroundColor.opacity
                      == ScreenIndexPreferences.default.backgroundColor.opacity)

            // decodeWithLegacyFallback：当前格式 + savesLegacyUpgrade=false（防落库副作用）
            let prefs = data.flatMap {
                ScreenIndexPreferences.decodeWithLegacyFallback($0, source: "runner-test",
                                                                savesLegacyUpgrade: false)
            }
            check("screenPref F3: 单源解码当前格式成功且 enforce 放行（已 per-screen 无需迁移）",
                  prefs?.usePerScreenSpaceIndexing == true)
            check("screenPref F4: 坏数据解码 → nil（catch 分支，绝不 throw）",
                  ScreenIndexPreferences.decodeWithLegacyFallback(Data("junk".utf8),
                                                                  source: "runner-test",
                                                                  savesLegacyUpgrade: false) == nil)

            let color = CodableColor(Color(red: 0.1, green: 0.2, blue: 0.3, opacity: 0.4))
            let ui = color.swiftUIColor
            _ = ui
            check("screenPref F5: swiftUIColor 构造（rgba 分量保持）",
                  abs(color.red - 0.1) < 0.01 && abs(color.green - 0.2) < 0.01
                  && abs(color.blue - 0.3) < 0.01 && abs(color.opacity - 0.4) < 0.01)
        }

        // G. 完成音效偏好模型：枚举语义 + 自定义文件状态机 + 端口钳制
        do {
            let all = CompletionSoundType.allCases
            check("soundPref G1: 7 种音效 displayName 非空互异",
                  all.count == 7 && all.allSatisfy { !$0.displayName.isEmpty }
                  && Set(all.map(\.displayName)).count == 7)
            check("soundPref G2: isBuiltin 恰好 4 个内建",
                  Set(all.filter(\.isBuiltin)) == [.builtinDing, .builtinPing, .builtinComplete, .builtinAreYouOk])
            check("soundPref G3: rawValue 往返", all.allSatisfy { CompletionSoundType(rawValue: $0.rawValue) == $0 })

            check("soundPref G4: CustomSoundStatus uiDescription 三态文案",
                  CustomSoundStatus.notSet.uiDescription == "未选择文件"
                  && CustomSoundStatus.valid.uiDescription == "已选择"
                  && CustomSoundStatus.missing.uiDescription.contains("文件不存在"))

            let marker = NSTemporaryDirectory() + "ut100-sound-\(UUID().uuidString)"
            FileManager.default.createFile(atPath: marker, contents: Data())
            check("soundPref G5: evaluate 四态（nil/空串/存在/缺失）",
                  CustomSoundStatus.evaluate(path: nil) == .notSet
                  && CustomSoundStatus.evaluate(path: "") == .notSet
                  && CustomSoundStatus.evaluate(path: marker) == .valid
                  && CustomSoundStatus.evaluate(path: "/nonexistent/ut100/nope.wav") == .missing)
            try? FileManager.default.removeItem(atPath: marker)

            check("soundPref G6: clampedUserPort（0=default/低钳 1024/正常透传/高钳 65535）",
                  SoundPreferences.clampedUserPort(0, defaultValue: 9000) == 9000
                  && SoundPreferences.clampedUserPort(-1, defaultValue: 9000) == 1024
                  && SoundPreferences.clampedUserPort(80, defaultValue: 9000) == 1024
                  && SoundPreferences.clampedUserPort(8080, defaultValue: 9000) == 8080
                  && SoundPreferences.clampedUserPort(70_000, defaultValue: 9000) == 65_535)
        }

        // H. WindowIdentity(from: WindowState) 字段映射（含 axWindowNumber→windowNumber 改名）
        do {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var state = WindowState(
                windowID: 77, pid: 4242, tty: "/dev/ttys9", axWindowNumber: 9,
                appName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", title: "repo — zsh",
                termSessionID: nil, itermSessionID: nil, sessionID: "sess-h",
                bindingType: .local, isCompleted: false, createdAt: now,
                updatedAt: now.addingTimeInterval(-60)
            )
            let identity = WindowIdentity(from: state)
            check("hookModel H1: 七字段逐一映射",
                  identity.windowID == 77 && identity.pid == 4242
                  && identity.bundleIdentifier == "com.googlecode.iterm2"
                  && identity.appName == "iTerm2" && identity.windowNumber == 9
                  && identity.title == "repo — zsh" && identity.capturedAt == state.createdAt)
            state.axWindowNumber = nil
            check("hookModel H2: axWindowNumber 缺失透传 nil",
                  WindowIdentity(from: state).windowNumber == nil)
        }
    }
}
