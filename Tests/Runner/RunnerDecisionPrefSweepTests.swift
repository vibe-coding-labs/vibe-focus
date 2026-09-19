import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDecisionPrefSweepTests.swift — B229 决策与偏好迁移扫尾
// 靶：RestoreAnnouncementPlan 纯映射族 / ScreenIndexPreferences legacy 迁移解码 /
// evaluateRestoreDecision 无 AX 授权守卫（Runner CLI 环境的确定性分支）。
// 纪律：legacy 迁移一律 savesLegacyUpgrade=false（防写生产三源库）。

/// ToggleRecordStore 假通道（决策守卫测试用， load/clear 记录调用）
final class FakeDecisionRecordStore: ToggleRecordStore, @unchecked Sendable {
    var record: ToggleRecord?
    private(set) var cleared: [UInt32] = []
    func load(windowID: UInt32) -> ToggleRecord? { record }
    func loadByPID(pid: Int32) -> ToggleRecord? { record }
    func clear(windowID: UInt32) { cleared.append(windowID) }
}

extension RunnerHarness {
    func runDecisionPrefSweepTests() {
        runRestoreAnnouncementPlanTests()
        runScreenIndexLegacyDecodeTests()
        runEvaluateRestoreGuardTests()
    }

    // MARK: - RestoreAnnouncementPlan：文案/音效通道/分流真值表

    private func runRestoreAnnouncementPlanTests() {
        // 五态文案：四态播报 + silent 不播报
        check("restorePlan A1: 五态文案映射（silent=nil）",
              RestoreAnnouncementPlan.restoredExact.text == "窗口已恢复"
              && RestoreAnnouncementPlan.restoredDegraded.text?.contains("原工作区不可达") == true
              && RestoreAnnouncementPlan.restoredDegraded.text?.contains("已落在可见工作区") == true
              && RestoreAnnouncementPlan.failedRetryable.text == "恢复失败，可重试"
              && RestoreAnnouncementPlan.failedPermanent.text == "原屏幕已断开，无法恢复"
              && RestoreAnnouncementPlan.silent.text == nil)
        check("restorePlan A2: 音效通道（成功三态/失败两态）",
              RestoreAnnouncementPlan.restoredExact.isSuccessful
              && RestoreAnnouncementPlan.restoredDegraded.isSuccessful
              && RestoreAnnouncementPlan.silent.isSuccessful
              && !RestoreAnnouncementPlan.failedRetryable.isSuccessful
              && !RestoreAnnouncementPlan.failedPermanent.isSuccessful)

        // B176 分流真值表：完成音仅在「允许且计划成功」时播；失败音只看 allowed
        let plans: [(RestoreAnnouncementPlan, Bool)] = [
            (.restoredExact, true), (.restoredDegraded, true), (.silent, true),
            (.failedRetryable, false), (.failedPermanent, false),
        ]
        var truthTableOK = true
        for (plan, expectedChannel) in plans {
            let withAllowed = RestoreAnnouncementPlan.shouldPlaySuccessSound(plan: plan, allowed: true)
            let withoutAllowed = RestoreAnnouncementPlan.shouldPlaySuccessSound(plan: plan, allowed: false)
            if withAllowed != expectedChannel || withoutAllowed { truthTableOK = false }
        }
        check("restorePlan A3: shouldPlaySuccessSound 真值表（allowed∧成功计划）", truthTableOK)
    }

    // MARK: - ScreenIndexPreferences：legacy 旧格式迁移解码（不落库）

    private func runScreenIndexLegacyDecodeTests() {
        // 旧格式：缺 panelScale/panelMargin/usePerScreenSpaceIndexing/yabaiPath
        let legacyJSON = """
        {"isEnabled":false,"position":"bottomLeft","fontSize":36,"opacity":0.5,
         "textColor":{"red":1,"green":1,"blue":1,"opacity":1},
         "backgroundColor":{"red":0,"green":0,"blue":0,"opacity":0.6}}
        """
        let migrated = ScreenIndexPreferences.decodeWithLegacyFallback(
            Data(legacyJSON.utf8), source: "ut100-legacy", savesLegacyUpgrade: false)
        check("screenLegacy B1: legacy 迁移成功且缺省字段补默认（scale=1 margin=20）",
              migrated?.isEnabled == false
              && migrated?.position == .bottomLeft
              && migrated?.fontSize == 36
              && migrated?.panelScale == 1.0
              && migrated?.panelMargin == 20
              && migrated?.yabaiPath == nil)
        // 迁移强制开启 per-screen（enforce 语义，true 值不改写即无 save 副作用）
        check("screenLegacy B2: 迁移结果强制 per-screen 索引（无落库副作用）",
              migrated?.usePerScreenSpaceIndexing == true)
        check("screenLegacy B3: 连 legacy 都不是的垃圾 → nil",
              ScreenIndexPreferences.decodeWithLegacyFallback(
                Data("junk".utf8), source: "ut100-legacy", savesLegacyUpgrade: false) == nil)
    }

    // MARK: - evaluateRestoreDecision：无 AX 授权守卫（Runner CLI 确定性分支）

    private func runEvaluateRestoreGuardTests() {
        let wm = WindowManager.shared
        let fakeStore = FakeDecisionRecordStore()
        let decision = wm.evaluateRestoreDecision(windowID: 0xBEEF, store: fakeStore)
        if !wm.hasAccessibilityPermission() {
            // Runner CLI 未授权 AX：守卫先行，无论 windowID 与库存器为何
            check("decision C1: 无 AX 授权 → noFocusedWindow 短路（不触 store）",
                  decision == .noFocusedWindow && fakeStore.cleared.isEmpty)
        } else {
            // 授权环境（如真机 E2E 通道）：幻影窗不在主屏 → moveToMain，同样是合法结局
            check("decision C2: AX 已授权环境 → 幻影窗解析为 moveToMain",
                  decision == .moveToMain)
        }
        // 决策枚举与路由映射再锁一遍（与 ToggleDecisionTests 互补的入口级一致性）
        check("decision C3: route 映射入口级一致（restore 直通/非主屏 move/主屏 stuck）",
              WindowManager.route(for: .restore, onMainScreen: nil) == .restore
              && WindowManager.route(for: .moveToMain, onMainScreen: false) == .moveToMain
              && WindowManager.route(for: .moveToMain, onMainScreen: true) == .moveSecondaryStuck)
    }
}
