import Foundation

// SA 恢复状态机（2026-09-03 全场景自适应重构；2026-09-08 B52 从 SpaceController+Recovery.swift
// 按域拆出）：结局分类 + 退避策略（纯函数，Runner 直测锁定）+ 持久化读写 + 用户可见状态收敛。
// 恢复动作编排（静默/提权）见 SpaceController+Recovery.swift；提权执行半区见
// SpaceController+SARecoveryAdmin.swift。

@MainActor
extension SpaceController {

    /// SA 恢复结局分类（纯函数，Runner 分支穷尽锁定）。
    enum SARecoveryVerdict: String, Equatable {
        /// load-sa 成功（SA 已注入 WindowServer）
        case succeeded
        /// SIP 阻止（错误信息含 "System Integrity Protection"）——该机器上永久不可加载，
        /// 自动恢复永不重试，设置面板常驻原因与启用指引
        case blockedBySIP
        /// 用户在授权框点取消/关闭——7 天退避后允许再次询问
        case userDeclined
        /// 其他瞬时失败（yabai 缺失/系统更新后布局变化等）——24 小时退避自愈
        case failedOther
    }

    /// 恢复结局裁决（纯函数）。success=true 一律 succeeded；失败按错误文本分类：
    /// yabai 的 SIP 拒载错误与 osascript 的用户取消（-128）有稳定可辨文本。
    static func recoveryVerdict(success: Bool, outputOrError: String) -> SARecoveryVerdict {
        if success { return .succeeded }
        if outputOrError.contains("System Integrity Protection") { return .blockedBySIP }
        if outputOrError.lowercased().contains("user canceled") { return .userDeclined }
        return .failedOther
    }

    /// 自动恢复再尝试策略（纯函数，hoursSince = 距上次该结局的小时数）：
    /// - blockedBySIP：永不自动重试（SIP 限制不随时间变化，重试=重复打扰）；
    /// - userDeclined：7×24 小时（用户明确说不，给足冷静期）；
    /// - failedOther：24 小时（瞬时失败自愈，覆盖系统更新后失效场景）；
    /// - succeeded：无需恢复。
    static func autoRecoveryAllowed(verdict: SARecoveryVerdict, hoursSince: TimeInterval) -> Bool {
        switch verdict {
        case .blockedBySIP: return false
        case .succeeded: return false
        case .userDeclined: return hoursSince >= 7 * 24
        case .failedOther: return hoursSince >= 24
        }
    }

    private static let saVerdictKey = "saRecoveryVerdict"
    private static let saVerdictAtKey = "saRecoveryVerdictAt"
    private static let legacyFailedAtKey = "scriptingAdditionRecoveryFailedAt"

    /// 读持久化恢复状态（含旧版单一失败时间戳的迁移：视为 failedOther）。
    /// B52 拆分后由恢复编排（+Recovery.swift）跨文件调用，故为 internal。
    func loadRecoveryState() -> (verdict: SARecoveryVerdict?, hoursSince: TimeInterval) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let raw = defaults.string(forKey: Self.saVerdictKey),
           let verdict = SARecoveryVerdict(rawValue: raw) {
            let at = defaults.double(forKey: Self.saVerdictAtKey)
            guard at > 0 else { return (verdict, TimeInterval.greatestFiniteMagnitude) }
            return (verdict, max(0, now - at))
        }
        // 旧版迁移：legacy 失败时间戳 → failedOther（24h 语义与旧行为一致）
        let legacy = defaults.double(forKey: Self.legacyFailedAtKey)
        if legacy > 0 {
            defaults.removeObject(forKey: Self.legacyFailedAtKey)
            return (.failedOther, max(0, now - legacy))
        }
        return (nil, 0)
    }

    /// 持久化恢复结局并按场景更新用户可见状态（主队列调用）。
    /// 防降级：blockedBySIP 是系统属性判定（SIP 不随时间变化），不被更弱的
    /// failedOther 覆盖——否则 silent 弱失败会把永久静默洗回 24h 弹框窗口
    /// （2026-09-04"永久授权"诉求的关键保障）。
    /// B52 拆分后由恢复编排与 admin 半区跨文件调用，故为 internal。
    func recordRecoveryState(_ verdict: SARecoveryVerdict, op: String, output: String) {
        let defaults = UserDefaults.standard
        if verdict == .failedOther,
           defaults.string(forKey: Self.saVerdictKey) == SARecoveryVerdict.blockedBySIP.rawValue {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.saVerdictAtKey)
            return
        }
        defaults.set(verdict.rawValue, forKey: Self.saVerdictKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.saVerdictAtKey)
        defaults.removeObject(forKey: Self.legacyFailedAtKey)
        switch verdict {
        case .succeeded:
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log("[SpaceController] scripting-addition recovered", fields: [
                "op": op, "verdict": verdict.rawValue,
                "output": truncateForLog(output, limit: 120)
            ])
        case .blockedBySIP:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "scripting-addition 被系统 SIP 阻止（需要关闭 Filesystem Protections 与 Debugging Restrictions 两项后才能加载）。自动恢复已停止打扰；跨工作区恢复走降级通道，不影响基本功能。若需要 15ms 直切：进恢复模式执行 csrutil enable --without debug --without fs 后，回到本页点「加载」。"
            log("[SpaceController] scripting-addition recovery blocked by SIP (auto retry disabled)", level: .error, fields: [
                "op": op, "detail": truncateForLog(output, limit: 220)
            ])
        case .userDeclined:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "已取消 scripting-addition 授权（7 天内不会再次询问）。跨工作区恢复走降级通道；需要时点击「加载」按钮重新授权。"
            log("[SpaceController] scripting-addition recovery declined by user (7d backoff)", level: .warn, fields: ["op": op])
        case .failedOther:
            scriptingAdditionRecoverySucceeded = false
            lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击\"加载\"按钮手动触发。"
            log("[SpaceController] scripting-addition recovery failed (24h backoff)", level: .error, fields: [
                "op": op, "detail": truncateForLog(output, limit: 220)
            ])
        }
    }
}
