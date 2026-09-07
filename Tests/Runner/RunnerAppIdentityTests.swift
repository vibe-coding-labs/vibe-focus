import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAppIdentityTests.swift — B58 自 B55 收敛：bundle id 单一事实源
// （AppIdentity.bundleID）直测。脚本侧契约由 BundleIdentityContractTests 锁定。

extension RunnerHarness {
    func runAppIdentityTests() {
        check("appIdentity: canonical bundle id 与 run.sh 装机值对齐",
              AppIdentity.bundleID == "com.openai.vibe-focus")
        check("appIdentity: 常量非空且非退役 id",
              !AppIdentity.bundleID.isEmpty
              && AppIdentity.bundleID != "com.vibefocus.app"
              && !AppIdentity.bundleID.hasPrefix("com.vibefocus.app."))
    }
}
