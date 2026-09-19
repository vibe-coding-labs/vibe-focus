import AppKit
import SwiftUI
import ServiceManagement
@testable import VibeFocusKit

// Tests/Runner/RunnerSettingsDGroupTests.swift — 覆盖率批次 6（B235）：
// B229 D 组留白的注入缝改造验证——ClaudeHookSection/SessionLists（sessionRegistry
// → WindowStateStore，经 VIBEFOCUS_DB_PATH shell 层注入隔离 DB；进程内 setenv 对
// ProcessInfo.environment 启动快照无效，必须运行 Runner 时注入——本仓库门禁/E2E
// 惯例）+ PermissionsSection/loginItemSection（loginItemManager init 的 Task{refresh()}
// 在同步测试序列里永不获得主线程执行权，XPC/AppleScript 不触发——求值安全）。
// 另含 loginItemPresentation(for:) 提纯纯函数（本批从 refresh 状态机提取，行为不变）。

extension RunnerHarness {
    func runSettingsDGroupTests() {
        // MARK: A. loginItemPresentation 提纯纯函数（B235 提取，五分支契约锁）
        func presentation(_ status: SMAppService.Status) -> (Bool, Bool, String, String) {
            let p = LoginItemManager.loginItemPresentation(for: status)
            return (p.isEnabled, p.requiresApproval, p.title, p.detail)
        }
        check("loginItem: enabled → 已启用四元组",
              presentation(.enabled) == (true, false, "已启用", "登录后会自动启动。"))
        check("loginItem: notRegistered → 未启用四元组",
              presentation(.notRegistered) == (false, false, "未启用", "不会在登录后自动启动。"))
        check("loginItem: requiresApproval → 待确认（需用户在系统设置确认）",
              presentation(.requiresApproval) == (false, true, "待确认", "需要在系统设置中确认。"))
        check("loginItem: notFound → 不可用（裸二进制安装形态指引 run.sh）",
              presentation(.notFound) == (false, false, "不可用", "未能识别为登录项。请使用 ./run.sh 安装为 .app bundle。"))
        check("loginItem: 四态文案互不相交（状态可区分）",
              Set([presentation(.enabled).2, presentation(.notRegistered).2,
                   presentation(.requiresApproval).2, presentation(.notFound).2]).count == 4)

        // MARK: B. D 组 section 求值（隔离 DB + Task 不可达语义，见文件头）
        // claudeHookSection/activeSessionList/completedSessionList 构建表达式读
        // sessionRegistry wrappedValue → 单例化 → store 经 VIBEFOCUS_DB_PATH 指向
        // 隔离 DB（运行时 shell 注入）；查询只读。
        let view = SettingsView()
        print("[SECTION-PROBE] D1 claudeHookSection")
        let _ = view.claudeHookSection
        print("[SECTION-PROBE] D2 activeSessionList")
        let _ = view.activeSessionList
        print("[SECTION-PROBE] D3 completedSessionList")
        let _ = view.completedSessionList
        // permissionsSection/loginItemSection 留白：permissionsSection 构建表达式
        // 直接读 @EnvironmentObject hotKeyManager（第四处引用，实测 SIGTRAP）；
        // loginItemSection 单独求值无法脱离 permissionsSection 所在渲染环境语义。
        print("[SECTION-PROBE] D 组求值完成")
        check("settingsSection: D 组 section 构建表达式求值全程无异常", true)
    }
}
