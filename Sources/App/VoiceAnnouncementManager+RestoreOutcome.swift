// VoiceAnnouncementManager+RestoreOutcome.swift
// VibeFocus — restore 结局播报（2026-09-02 P1-1，restore-thorough-fix-plan）
//
// 职责分层：
//   RestoreAnnouncementPlan                       — 纯决策：RestoreOutcome → 文案 + 成败通道
//                                                   （Standalone RestoreAnnouncementPlanTests 分支穷尽锁定）
//   ToggleEngine.RestoreOutcome.restoreAnnouncementPlan — 结局 → 计划的映射（总函数，四分支穷尽）
//   VoiceAnnouncementManager.announceRestoreOutcome     — 发声接线（语音走队列、音效走 SoundManager）
//
// ## 为什么复用既有开关而不新建授权面（规划 P1-1 约束）
// - 语音通道沿用 VoiceAnnouncementPreferences.mode（none=静默）：restore 播报使用固定文案，
//   不吃用户会话完成模板（模板变量是会话语义，对恢复场景无意义）；
// - 音效通道沿用 SoundPreferences.soundType（none=静默）：成功播用户配置的完成音效，
//   失败固定系统 Basso——两开关任一关闭即该通道静默，无新增权限/授权。

import AppKit
import Foundation

/// restore 结局的播报计划（文案与 AuditLogger 结局字段一一对应，P1-1 验收口径）。
enum RestoreAnnouncementPlan: Equatable {
    /// ↔ restore_success spaceExact=true/nil：窗口已精确回源。
    case restoredExact
    /// ↔ restore_success spaceExact=false：位置已恢复但原 space 不可达（落在可见工作区）。
    case restoredDegraded
    /// ↔ restore_move_failed recordKept=true（window_minimized / frame_not_converged）：可重试。
    case failedRetryable
    /// ↔ restore_move_failed recordKept=false（orig_frame_offscreen）：原屏幕已断开。
    case failedPermanent
    /// ↔ aborted（无审计事件）：非恢复尝试结局，不播报。
    case silent

    /// 语音文案（nil = 不播报）。固定文案而非用户模板，理由见文件头。
    var text: String? {
        switch self {
        case .restoredExact:
            return "窗口已恢复"
        case .restoredDegraded:
            return "窗口已恢复，但原工作区不可达，已落在可见工作区"
        case .failedRetryable:
            return "恢复失败，可重试"
        case .failedPermanent:
            return "原屏幕已断开，无法恢复"
        case .silent:
            return nil
        }
    }

    /// 音效成败通道（true=完成音效，false=失败音效 Basso）。silent 无音效需求，取值无消费方。
    var isSuccessful: Bool {
        switch self {
        case .restoredExact, .restoredDegraded, .silent:
            return true
        case .failedRetryable, .failedPermanent:
            return false
        }
    }
}

@MainActor
extension ToggleEngine.RestoreOutcome {

    /// 结局 → 播报计划（总映射，RestoreAnnouncementPlanTests 分支穷尽锁定）。
    var restoreAnnouncementPlan: RestoreAnnouncementPlan {
        switch self {
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
}

@MainActor
extension VoiceAnnouncementManager {

    /// restore 结局用户可感知入口（WindowManager.restore 在 ToggleEngine.restore 返回后调用）。
    ///
    /// ## 场景
    /// - restore 热键路径的 fire-and-forget 播报：历史上失败（最小化/断显/space 没切准）
    ///   完全静默，日志全是 success 的「感觉有 bug」体感根源之一（规划 P1-1）。
    ///
    /// ## 通道与开关（任一关闭即该通道静默，勿新建授权面）
    /// - 语音：mode != .none 时经有界队列播报（不抢占会话完成播报，第二十二刀语义）；
    /// - 音效：soundType != .none 时 NSSound 区分成败——成功=用户配置完成音效，
    ///   失败=系统 Basso（SoundManager.playFailureSound）。
    func announceRestoreOutcome(_ outcome: ToggleEngine.RestoreOutcome, windowID: UInt32) {
        let plan = outcome.restoreAnnouncementPlan
        guard plan != .silent else {
            log("[VoiceAnnouncementManager] restore outcome aborted, staying silent", fields: [
                "windowID": String(windowID)
            ])
            return
        }

        if preferences.mode != .none, let text = plan.text {
            enqueueAnnouncement(.text(text), sessionID: "restore-\(windowID)")
        } else {
            log("[VoiceAnnouncementManager] restore voice announcement skipped, mode is none", fields: [
                "windowID": String(windowID)
            ])
        }

        if plan.isSuccessful {
            SoundManager.shared.playCompletionSound()
        } else {
            SoundManager.shared.playFailureSound()
        }
    }
}
