import AppKit
import Carbon
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHotKeyApplySeamTests.swift
// 靶：HotKeyManager 快捷键录用编排（HotKeyApplyEnvironment 注入）——
// 主键改键四态（未变化/校验失败/注册失败回滚/成功落库通知）、
// 摆位键表内重复/与主键撞车/成功绑定、气泡键与主键/摆位键撞车/成功设置。
// 零 Carbon 全局注册、零 UserDefaults 写、零提示音。

final class HotKeyApplySeamState: @unchecked Sendable {
    var validationMessage: String?
    var registerShouldFail = false
    var registerCalls = 0
    var savedHotKeys: [HotKeyConfiguration] = []
    var savedLayoutTables = 0
    var bubbleKeys: [HotKeyConfiguration] = []
    var layoutEnabled = false
    var beeps = 0
    var audits: [String] = []
    var notices: [Notification.Name] = []
}

extension RunnerHarness {
    func runHotKeyApplySeamTests() {
        let manager = HotKeyManager.shared
        let state = HotKeyApplySeamState()
        let originalHotKey = manager.currentHotKey

        func reset() {
            state.validationMessage = nil
            state.registerShouldFail = false
            state.registerCalls = 0
            state.savedHotKeys = []
            state.savedLayoutTables = 0
            state.bubbleKeys = []
            state.layoutEnabled = false
            state.beeps = 0
            state.audits = []
            state.notices = []
        }
        func makeEnv() -> HotKeyApplyEnvironment {
            HotKeyApplyEnvironment(
                validationError: { _ in state.validationMessage },
                registerHotKey: {
                    state.registerCalls += 1
                    manager.shortcutStatusIsError = state.registerShouldFail
                },
                saveHotKey: { state.savedHotKeys.append($0) },
                saveLayoutTable: { state.savedLayoutTables += 1 },
                setBubbleHotKey: { state.bubbleKeys.append($0) },
                layoutActionsEnabled: { state.layoutEnabled },
                beep: { state.beeps += 1 },
                record: { state.audits.append($0) },
                notify: { state.notices.append($0) }
            )
        }
        // 与当前主键不同的候选组合（⌃B）
        let candidate = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey))

        // A. 与当前键相同 → 未变化
        reset()
        manager.applyShortcut(originalHotKey, environment: makeEnv())
        check("hotkeyApply A1: 组合键未变化 → 提示且零注册",
              manager.shortcutStatusMessage.hasPrefix("快捷键未变化")
              && state.registerCalls == 0 && state.savedHotKeys.isEmpty)
        check("hotkeyApply A2: 未变化落审计 no_change",
              state.audits.contains { $0.hasPrefix("hotkey_apply_no_change") })

        // B. 校验失败 → 报错 + 提示音
        reset()
        state.validationMessage = "快捷键冲突：与退出应用冲突"
        manager.applyShortcut(candidate, environment: makeEnv())
        check("hotkeyApply B1: 校验失败 → 状态带原因且不改主键",
              manager.shortcutStatusMessage == "快捷键冲突：与退出应用冲突"
              && manager.shortcutStatusIsError && manager.currentHotKey == originalHotKey)
        check("hotkeyApply B2: 校验失败提示音一次、零落库",
              state.beeps == 1 && state.savedHotKeys.isEmpty)

        // C. 注册失败 → 回滚到旧键
        reset()
        state.registerShouldFail = true
        manager.applyShortcut(candidate, environment: makeEnv())
        check("hotkeyApply C1: 注册失败 → 主键回滚",
              manager.currentHotKey == originalHotKey && state.registerCalls == 2)
        check("hotkeyApply C2: 回滚提示 + 两轮审计 + 提示音",
              manager.shortcutStatusMessage.hasPrefix("快捷键已恢复为")
              && state.audits.contains { $0.hasPrefix("hotkey_apply_rollback") }
              && state.beeps == 1 && state.savedHotKeys.isEmpty)

        // D. 成功 → 应用 + 落库 + 通知
        reset()
        manager.applyShortcut(candidate, environment: makeEnv())
        check("hotkeyApply D1: 成功 → 主键生效且落库",
              manager.currentHotKey == candidate && state.savedHotKeys == [candidate])
        check("hotkeyApply D2: 成功发通知并清错误位",
              state.notices == [.hotKeyConfigurationDidChange]
              && manager.shortcutStatusMessage.hasPrefix("快捷键已更新")
              && !manager.shortcutStatusIsError)

        // 还原主键（走注入通道，避免落库/真实注册）
        reset()
        manager.applyShortcut(originalHotKey, environment: makeEnv())
        check("hotkeyApply D3: 还原主键成功", manager.currentHotKey == originalHotKey)

        // ===== 摆位键 =====
        let table = manager.layoutTable
        let firstAction = LayoutAction.allCases[0]
        let secondAction = LayoutAction.allCases[1]
        let originalFirst = table.hotKey(for: firstAction)
        let originalSecond = table.hotKey(for: secondAction)

        // E. 表内重复绑定（首个断言组：校验通过后命中 duplicate 分支）
        reset()
        guard let firstKey = originalFirst else {
            check("hotkeyApply E0: 摆位默认表缺省，跳过", true)
            return
        }
        let duplicate = manager.applyLayoutShortcut(firstKey, for: secondAction, environment: makeEnv())
        check("hotkeyApply E1: 表内重复 → 报已绑定动作",
              duplicate?.contains("已绑定为") == true && state.registerCalls == 0)

        // F. 与主开关键撞车
        reset()
        let collision = manager.applyLayoutShortcut(originalHotKey, for: secondAction, environment: makeEnv())
        check("hotkeyApply F1: 与主键撞车 → 拒绝",
              collision?.contains("与主开关快捷键") == true)

        // G. 成功绑定 → 落表 + 注册 + 通知
        reset()
        let bound = manager.applyLayoutShortcut(candidate, for: secondAction, environment: makeEnv())
        check("hotkeyApply G1: 摆位键绑定成功",
              bound == nil && manager.layoutTable.hotKey(for: secondAction) == candidate
              && state.savedLayoutTables == 1 && state.registerCalls == 1)
        check("hotkeyApply G2: 摆位键变更发通知",
              state.notices == [.layoutHotKeyTableDidChange])

        // 还原摆位表
        reset()
        if let originalSecond {
            _ = manager.applyLayoutShortcut(originalSecond, for: secondAction, environment: makeEnv())
        }

        // ===== 气泡键 =====
        // H. 与主键撞车
        reset()
        let bubbleCollision = manager.applyBubbleShortcut(originalHotKey, environment: makeEnv())
        check("hotkeyApply H1: 气泡键与主键冲突 → 拒绝",
              bubbleCollision?.contains("与主开关快捷键") == true && state.bubbleKeys.isEmpty)

        // I. 摆位键占用（摆位总开关开时）
        reset()
        state.layoutEnabled = true
        let occupied = manager.applyBubbleShortcut(firstKey, environment: makeEnv())
        check("hotkeyApply I1: 摆位键占用 → 拒绝",
              occupied?.contains("已被摆位快捷键占用") == true && state.bubbleKeys.isEmpty)

        // J. 成功设置
        reset()
        let bubbleOK = manager.applyBubbleShortcut(candidate, environment: makeEnv())
        check("hotkeyApply J1: 气泡键设置成功 → 落偏好 + 注册 + 通知",
              bubbleOK == nil && state.bubbleKeys == [candidate]
              && state.registerCalls == 1 && state.notices == [.inputBubbleHotKeyDidChange])
    }
}
