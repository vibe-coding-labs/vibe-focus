// Tests/Runner/RunnerSARecoveryStateTests.swift
// B225 覆盖堆叠·SA 恢复状态机持久化域：SpaceController+SARecoveryState 的
// loadRecoveryState（新鲜/有效/legacy 迁移）与 recordRecoveryState（防降级守卫）。
// 偏好键走 Runner 自有 defaults 域（与生产 app 隔离），测试前存原始值 defer 还原。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runSARecoveryStateTests() {
        print("\n=== SARecoveryState (B225) ===")
        let sc = SpaceController.shared
        let verdictKey = "saRecoveryVerdict"
        let atKey = "saRecoveryVerdictAt"
        let legacyKey = "scriptingAdditionRecoveryFailedAt"
        let d = UserDefaults.standard
        let saved = (d.string(forKey: verdictKey), d.double(forKey: atKey), d.double(forKey: legacyKey))
        defer {
            if let v = saved.0 { d.set(v, forKey: verdictKey) } else { d.removeObject(forKey: verdictKey) }
            if saved.1 > 0 { d.set(saved.1, forKey: atKey) } else { d.removeObject(forKey: atKey) }
            if saved.2 > 0 { d.set(saved.2, forKey: legacyKey) } else { d.removeObject(forKey: legacyKey) }
        }

        // 1) 全空 → 无恢复状态
        for k in [verdictKey, atKey, legacyKey] { d.removeObject(forKey: k) }
        let fresh = sc.loadRecoveryState()
        check("saState: 全空 → nil 状态", fresh.verdict == nil && fresh.hoursSince == 0)

        // 2) 记录 failedOther → 读回 verdict 与小时数（刚发生 → ~0）
        sc.recordRecoveryState(.failedOther, op: "b225", output: "boom")
        let afterFail = sc.loadRecoveryState()
        check("saState: failedOther 记录可读回", afterFail.verdict == .failedOther)
        check("saState: 刚发生的小时数接近 0", afterFail.hoursSince < 1)

        // 3) 防降级：blockedBySIP 不被更弱的 failedOther 覆盖
        sc.recordRecoveryState(.blockedBySIP, op: "b225", output: "System Integrity Protection")
        sc.recordRecoveryState(.failedOther, op: "b225", output: "boom2")
        check("saState: SIP 判定不被 failedOther 降级",
              sc.loadRecoveryState().verdict == .blockedBySIP)

        // 4) userDeclined 走正常覆盖路径
        sc.recordRecoveryState(.userDeclined, op: "b225", output: "user canceled")
        check("saState: userDeclined 正常覆盖",
              sc.loadRecoveryState().verdict == .userDeclined)

        // 5) legacy 单一失败时间戳迁移 → failedOther 且 legacy 键清除
        d.removeObject(forKey: verdictKey)
        d.removeObject(forKey: atKey)
        d.set(Date().timeIntervalSince1970 - 3600, forKey: legacyKey)
        let migrated = sc.loadRecoveryState()
        check("saState: legacy 时间戳迁移为 failedOther", migrated.verdict == .failedOther)
        check("saState: legacy 小时数 ≥1", migrated.hoursSince >= 1 - 0.01)
        check("saState: legacy 键迁移后清除", d.double(forKey: legacyKey) == 0)

        // 6) verdict 键存在但 at 缺失 → 视为无限久远（永不再自动重试方向）
        d.set(SpaceController.SARecoveryVerdict.userDeclined.rawValue, forKey: verdictKey)
        d.removeObject(forKey: atKey)
        let noAt = sc.loadRecoveryState()
        check("saState: at 缺失 → 无限久远", noAt.hoursSince > 1_000_000)

        // 7) autoRecoveryAllowed 编排级核对（纯函数直测在他域，这里锁与 load 的配合）
        sc.recordRecoveryState(.failedOther, op: "b225", output: "boom3")
        check("saState: 24h 内 failedOther 不自动重试",
              SpaceController.autoRecoveryAllowed(verdict: sc.loadRecoveryState().verdict!, hoursSince: 1) == false)
    }
}
