import Foundation

/// 应用身份常量（B55/B58 单一事实源）。
///
/// canonical bundle id 必须与 run.sh 写入 Info.plist 的值一致（脚本侧契约由
/// Tests/Standalone/BundleIdentityContractTests.swift 锁定）。退役 id
/// `com.vibefocus.app` 是「误启旧副本回到无修复行为」陷阱的来源，禁止回潮。
enum AppIdentity {
    static let bundleID = "com.openai.vibe-focus"
}
