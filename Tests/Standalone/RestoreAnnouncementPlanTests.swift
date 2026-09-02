// Tests/Standalone/RestoreAnnouncementPlanTests.swift
// Verification: restore 结局播报计划（结局→文案/成败通道的纯决策，分支穷尽）
// Mirrors: Sources/App/VoiceAnnouncementManager+RestoreOutcome.swift
//          RestoreAnnouncementPlan / ToggleEngine.RestoreOutcome.restoreAnnouncementPlan
// Run: swift Tests/Standalone/RestoreAnnouncementPlanTests.swift
//
// 背景（2026-09-02 P1-1）：restore 失败历史上一片静默（日志全是 success 的体感 bug 根源）。
// 本表锁定播报计划与 AuditLogger 结局字段的一一对应——改文案或改映射必须同时看本表与
// Sources/Toggle/ToggleEngine+Restore.swift 的审计事件字段。

import Foundation

// MARK: - Mirrors (与源码同步维护)

/// 镜像 ToggleEngine.RestoreOutcome（结局语义见 RestoreRefocusCandidateTests）。
enum RestoreOutcomeMirror {
    case restored(spaceExact: Bool?)
    case aborted(reason: String)
    case moveFailedRetryable
    case moveFailedPermanent
}

enum MirrorRestoreAnnouncementPlan: Equatable {
    case restoredExact
    case restoredDegraded
    case failedRetryable
    case failedPermanent
    case silent

    static func decision(from outcome: RestoreOutcomeMirror) -> MirrorRestoreAnnouncementPlan {
        switch outcome {
        case .restored(let spaceExact):
            return spaceExact == false ? .restoredDegraded : .restoredExact
        case .moveFailedRetryable:
            return .failedRetryable
        case .moveFailedPermanent:
            return .failedPermanent
        case .aborted:
            return .silent
        }
    }

    var text: String? {
        switch self {
        case .restoredExact: return "窗口已恢复"
        case .restoredDegraded: return "窗口已恢复，但原工作区不可达，已落在可见工作区"
        case .failedRetryable: return "恢复失败，可重试"
        case .failedPermanent: return "原屏幕已断开，无法恢复"
        case .silent: return nil
        }
    }

    var isSuccessful: Bool {
        switch self {
        case .restoredExact, .restoredDegraded, .silent: return true
        case .failedRetryable, .failedPermanent: return false
        }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. 结局 → 计划映射（四分支 + spaceExact 子分支穷尽）

print("1. 结局 → 计划映射")

check("restored(spaceExact=true) → 精确恢复",
      MirrorRestoreAnnouncementPlan.decision(from: .restored(spaceExact: true)) == .restoredExact)

check("restored(spaceExact=nil) → 精确恢复（record 无 space 信息，从未尝试切回，不算退化）",
      MirrorRestoreAnnouncementPlan.decision(from: .restored(spaceExact: nil)) == .restoredExact)

check("restored(spaceExact=false) → 退化恢复（源 space 不可达，窗口落在可见工作区）",
      MirrorRestoreAnnouncementPlan.decision(from: .restored(spaceExact: false)) == .restoredDegraded)

check("moveFailedRetryable → 可重试失败",
      MirrorRestoreAnnouncementPlan.decision(from: .moveFailedRetryable) == .failedRetryable)

check("moveFailedPermanent → 永久失败",
      MirrorRestoreAnnouncementPlan.decision(from: .moveFailedPermanent) == .failedPermanent)

check("aborted → 静默（非恢复尝试结局，无审计事件）",
      MirrorRestoreAnnouncementPlan.decision(from: .aborted(reason: "no_toggle_record")) == .silent)

// MARK: 2. 文案 ↔ AuditLogger 结局字段一一对应（P1-1 验收表）

print("\n2. 文案 ↔ AuditLogger 字段对应表")

check("restoredExact ↔ restore_success spaceExact=true ——「窗口已恢复」",
      MirrorRestoreAnnouncementPlan.restoredExact.text == "窗口已恢复")
check("restoredDegraded ↔ restore_success spaceExact=false ——退化如实播报不静默",
      MirrorRestoreAnnouncementPlan.restoredDegraded.text == "窗口已恢复，但原工作区不可达，已落在可见工作区")
check("failedRetryable ↔ restore_move_failed recordKept=true ——「恢复失败，可重试」",
      MirrorRestoreAnnouncementPlan.failedRetryable.text == "恢复失败，可重试")
check("failedPermanent ↔ restore_move_failed recordKept=false ——「原屏幕已断开，无法恢复」",
      MirrorRestoreAnnouncementPlan.failedPermanent.text == "原屏幕已断开，无法恢复")
check("silent → 无文案（不发 TTS）",
      MirrorRestoreAnnouncementPlan.silent.text == nil)

// MARK: 3. NSSound 成败通道

print("\n3. NSSound 成败通道")

check("精确恢复 → 完成音效", MirrorRestoreAnnouncementPlan.restoredExact.isSuccessful)
check("退化恢复 → 完成音效（位置已恢复，属成功族）", MirrorRestoreAnnouncementPlan.restoredDegraded.isSuccessful)
check("可重试失败 → 失败音效（Basso）", !MirrorRestoreAnnouncementPlan.failedRetryable.isSuccessful)
check("永久失败 → 失败音效（Basso）", !MirrorRestoreAnnouncementPlan.failedPermanent.isSuccessful)

// MARK: 4. 文案非空不变量（TTS 空文本会被 speak 静默跳过，退化成无声播报）

print("\n4. 文案非空不变量")

for plan in [MirrorRestoreAnnouncementPlan.restoredExact, .restoredDegraded, .failedRetryable, .failedPermanent] {
    check("非静默计划文案非空", !(plan.text ?? "").isEmpty)
}

// MARK: - Summary

print("\nRestoreAnnouncementPlanTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
