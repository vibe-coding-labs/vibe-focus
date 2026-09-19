import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsViewSectionBodyTests.swift — 覆盖率批次 5（B229）：
// SettingsView 各 section 的 body 构建期求值直测（A/B/C 三组风险分级）。
//
// 分级依据（单例 init 副作用逐个审计，2026-09-19）：
// - A 组零单例：构建表达式只读 UserDefaults 偏好 → 直接求值；
// - B 组安全单例：soundManager/voiceAnnouncementManager 的 init 只 loadPreferences
//   （不预载音频、不启播放）→ 可求值；
// - C 组低风险：overlayManager（init 装信号 handler+注册 yabai 信号——Runner 进程
//   正常 exit 不受影响）+ spaceController（init 的 asyncAfter 重试与 60s health-check
//   Timer 在无运行 RunLoop 的同步测试进程里永不 fire，零 yabai fork）→ 可求值；
// - D 组留白：PermissionsSection（loginItemManager init 的 Task 触发 SMAppService
//   XPC+AppleScript）、SessionLists/ClaudeHookSection（sessionRegistry → WindowStateStore
//   .shared 打开生产 DB）、SettingsUI 主体 body（聚合全部 tab 会碰全组单例）。
// 危险调用（NSPasteboard/NSWorkspace/Process/install 系）均在按钮 action 闭包内，
// 构建期不执行——CodexSection 构建期仅 isHookInstalled() 读 ~/.codex/hooks.json（只读）。

extension RunnerHarness {
    func runSettingsViewSectionBodyTests() {
        let view = SettingsView()

        // MARK: A 组：零单例 section（构建期只读 UserDefaults）
        // 留白三件：①hotKeySection/layoutHotKeySection/inputBubbleSection——构建表达式
        // 直接读 @EnvironmentObject hotKeyManager，脱离渲染树求值必崩（SIGTRAP 实测）；
        // ②terminalGridSection/gridParamsSection——引用 gridMinimapHeartbeat
        // （autoconnect TimerPublisher 包装视图），body 求值触发
        // 「body() should not be called on SubscriptionView」fatal（实测）。
        print("[SECTION-PROBE] A6 terminalSessionCard")
        let _ = view.terminalSessionCard
        print("[SECTION-PROBE] A7 savedLayoutsCard")
        let _ = view.savedLayoutsCard
        print("[SECTION-PROBE] A8 codexSection")
        let _ = view.codexSection
        check("settingsSection: selectionDetailText 默认态非空文案",
              !view.selectionDetailText.isEmpty)

        // MARK: B 组：安全单例（init 只读偏好）
        print("[SECTION-PROBE] B1 soundSection")
        let _ = view.soundSection
        print("[SECTION-PROBE] B2 antiDisturbRows")
        let _ = view.antiDisturbRows
        print("[SECTION-PROBE] B3 projectRulesSection")
        let _ = view.projectRulesSection
        print("[SECTION-PROBE] B4 customAudioFileRows")
        let _ = view.customAudioFileRows
        print("[SECTION-PROBE] B5 voiceAnnouncementSection")
        let _ = view.voiceAnnouncementSection

        // MARK: C 组：overlay/space（死 timer + 信号 handler，同步进程内不 fire）
        print("[SECTION-PROBE] C1 overlaySection")
        let _ = view.overlaySection
        print("[SECTION-PROBE] C2 workspaceSection")
        let _ = view.workspaceSection
        print("[SECTION-PROBE] 全部 section 求值完成")
        check("settingsSection: 三组 section body 求值全程无异常", true)
    }
}
