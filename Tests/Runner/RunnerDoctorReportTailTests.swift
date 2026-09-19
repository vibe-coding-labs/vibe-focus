import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDoctorReportTailTests.swift — B233：Doctor.report 注入式驱动
// （DoctorPaths 全路径注入 + 伪 journal + 运行期翻转默认值，驱动 runtimeLine 分支）
// + WindowMoveDecision.logDescription 九 case 全值映射（4 case 为 0 计数行）。全只读。

extension RunnerHarness {
    func runDoctorReportTailTests() {
        // ===== WindowMoveDecision.logDescription 九 case 全值映射 =====
        do {
            typealias D = HookEventHandler.WindowMoveDecision
            check("wmDecision: autoFocusDisabled", D.autoFocusDisabled.logDescription == "auto_focus_disabled")
            check("wmDecision: localBindingSkip", D.localBindingSkip.logDescription == "local_binding_skip")
            check("wmDecision: noBindingSkip", D.noBindingSkip.logDescription == "no_binding_skip")
            check("wmDecision: bindingVerificationFailed",
                  D.bindingVerificationFailed.logDescription == "binding_verification_failed")
            check("wmDecision: alreadyOnMainScreen",
                  D.alreadyOnMainScreen.logDescription == "already_on_main_screen")
            check("wmDecision: restoreCooldownActive",
                  D.restoreCooldownActive.logDescription == "restore_cooldown_active")
            check("wmDecision: staleBindingPIDMismatch",
                  D.staleBindingPIDMismatch.logDescription == "stale_binding_pid_mismatch")
            check("wmDecision: nonTerminalWindow",
                  D.nonTerminalWindow.logDescription == "non_terminal_window")
            check("wmDecision: proceedToMove(source=)",
                  D.proceedToMove(source: "cgwindowlist").logDescription == "proceed_to_move(source=cgwindowlist)")
        }

        // ===== Doctor.report 注入驱动（伪 journal 含 ax launch + 运行期翻转键） =====
        do {
            let dir = "/tmp/vibefocus-doctor-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let journal = dir + "/journal.jsonl"
            let line1 = #"{"kind":"launch","pid":123,"at":"2026-09-20T00:00:00Z","exe":"VibeFocus","ax":true}"#
            let line2 = #"{"kind":"exit","pid":123,"at":"2026-09-20T00:01:00Z","reason":"clean"}"#
            do {
                try (line1 + "\n" + line2 + "\n").write(toFile: journal, atomically: true, encoding: .utf8)
            } catch {
                check("docReport: journal 夹具写入失败", false)
            }

            let paths = DoctorPaths(
                journalPath: journal,
                logDir: dir,
                tmpFatalPath: dir + "/fatal.log",
                tmpSnapshotPath: dir + "/snapshot.log",
                keepaliveLogPath: dir + "/keepalive.log",
                diagnosticReportsDir: dir,
                appLogPath: dir + "/app.log"
            )

            // 运行期翻转键（存-还）→ runtimeLine 非 nil → report 走 append(runtimeLine) 分支
            let d = UserDefaults.standard
            let savedCount = d.object(forKey: "axTrustRuntimeFlipCount")
            let savedDir = d.string(forKey: "axTrustRuntimeFlipLastDirection")
            let savedAt = d.object(forKey: "axTrustRuntimeFlipLastAt")
            defer {
                if let savedCount { d.set(savedCount, forKey: "axTrustRuntimeFlipCount") }
                else { d.removeObject(forKey: "axTrustRuntimeFlipCount") }
                if let savedDir { d.set(savedDir, forKey: "axTrustRuntimeFlipLastDirection") }
                else { d.removeObject(forKey: "axTrustRuntimeFlipLastDirection") }
                if let savedAt { d.set(savedAt, forKey: "axTrustRuntimeFlipLastAt") }
                else { d.removeObject(forKey: "axTrustRuntimeFlipLastAt") }
            }
            d.set(2, forKey: "axTrustRuntimeFlipCount")
            d.set("false→true", forKey: "axTrustRuntimeFlipLastDirection")
            d.set(Date().timeIntervalSince1970, forKey: "axTrustRuntimeFlipLastAt")

            let report = Doctor.report(paths: paths, now: Date(timeIntervalSince1970: 1_800_000_000),
                                       sessionPanelLines: nil)
            check("docReport: 生命周期段解析 launch 行（含 ax 标记）",
                  report.contains("launch pid=123") && report.contains("ax=true"))
            check("docReport: 辅助功能段报已授权",
                  report.contains("[辅助功能授权] 当前：已授权"))
            check("docReport: 运行期翻转入行（runtimeLine 分支）",
                  report.contains("运行期翻转 2 次") && report.contains("false→true"))
            check("docReport: 安装副本盘点段在场",
                  report.contains("[安装副本盘点]"))
            check("docReport: 构建能力标记段在场",
                  report.contains("[构建能力标记]"))
        }
    }
}
