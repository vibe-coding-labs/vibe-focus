import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerLoginItemCleanupTests.swift — 覆盖率批次 32（B264）：
// LoginItemManager.cleanupStaleLoginItems 脚本构建纯函数直测（B264 提取）。
// 真实 osascript 执行会改系统登录项——语义由脚本文本契约锁定，执行留白。

extension RunnerHarness {
    func runLoginItemCleanupTests() {
        let script = LoginItemManager.staleLoginItemsCleanupScript()
        check("loginCleanup: 脚本目标 System Events 登录项",
              script.contains("System Events") && script.contains("every login item"))
        check("loginCleanup: .build/ 裸二进制识别语义在脚本中",
              script.contains(".build/"))
        check("loginCleanup: VibeFocus 名匹配大小写双形态",
              script.contains("VibeFocus") && script.contains("vibe-focus"))
        check("loginCleanup: 删除动作与计数返回",
              script.contains("delete anItem") && script.contains("deletedCount"))
    }
}
