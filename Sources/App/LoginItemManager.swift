import Foundation
import ServiceManagement

/// Manages macOS login item (auto-start on login) registration and status.
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusTitle: String = "未知"
    @Published private(set) var statusDetail: String = "尚未检测"
    @Published private(set) var requiresApproval: Bool = false
    @Published private(set) var lastErrorMessage: String? = nil

    private var didCleanupStaleItems = false

    private init() {
        // P0 红线（docs/quality-plan-2026-09.md）：单例 init→dispatch_once 链上禁止
        // 同步外部 IPC。refresh() 内含 SMAppService XPC 同步查询与（已后台化的）
        // AppleScript 清理——在 once 链上执行曾与主队列重入任务互撞致 SIGTRAP
        // （2026-09-06 75472 等秒死案，堆栈实证）。延迟到主队列异步执行：once 链
        // 立即结束，@Published 回填语义不变（MainActor 上仍串行、UI 照常刷新）。
        Task { self.refresh() }
    }

    func refresh() {
        log("LoginItemManager.refresh() entered", level: .debug)
        let status = SMAppService.mainApp.status
        log("LoginItemManager.refresh() SMAppService status", level: .debug, fields: ["rawStatus": String(describing: status)])
        let presentation = Self.loginItemPresentation(for: status)
        isEnabled = presentation.isEnabled
        requiresApproval = presentation.requiresApproval
        statusTitle = presentation.title
        statusDetail = presentation.detail

        // 清理指向 .build/ 目录的旧裸二进制 login items（只执行一次）
        if !didCleanupStaleItems {
            cleanupStaleLoginItems()
            didCleanupStaleItems = true
        }
    }

    /// SMAppService 登录项状态 → UI 展示四元组（纯函数，refresh 状态机回填语义）。
    static func loginItemPresentation(
        for status: SMAppService.Status
    ) -> (isEnabled: Bool, requiresApproval: Bool, title: String, detail: String) {
        switch status {
        case .enabled:
            return (true, false, "已启用", "登录后会自动启动。")
        case .notRegistered:
            return (false, false, "未启用", "不会在登录后自动启动。")
        case .requiresApproval:
            return (false, true, "待确认", "需要在系统设置中确认。")
        case .notFound:
            return (false, false, "不可用", "未能识别为登录项。请使用 ./run.sh 安装为 .app bundle。")
        @unknown default:
            return (false, false, "未知", "系统返回未知状态。")
        }
    }

    /// 清理指向 .build/ 目录的旧裸二进制 login items 和 missing value 条目。
    /// 这些是之前直接运行裸二进制时注册的，无法正常工作。
    private func cleanupStaleLoginItems() {
        // P-INST-81: 旧 login item 清理耗时（NSAppleScript executeAndReturnError 执行 System Events 脚本，遍历 login items + 删除；启动一次性，didCleanupStaleItems 守卫只跑一次；AppleScript IPC 可阻塞主线程）。
        #if PERF_INSTRUMENT
        let cslStart = Date()
        defer {
            log("[LoginItemManager] cleanupStaleLoginItems finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: cslStart))
            ])
        }
        #endif
        let script = Self.staleLoginItemsCleanupScript()
        guard let appleScript = NSAppleScript(source: script) else { return }
        // 2026-09-06：NSAppleScript 移出主线程。execute 会在主线程泵嵌套
        // RunLoop（WNEInternal），期间派发队列上排队的 MainActor 任务被重入执行，
        // 若其再次触碰正在 dispatch_once 中的 LoginItemManager.shared →
        // _dispatch_once_wait 同线程重入 → dispatch 层 SIGTRAP 击杀（当日 75424/
        // 84552/83091/41369 等「启动后秒死」案件的根因，crash 观测堆栈实证）。
        // 清理为纯后台副作用，放全局队列执行，与主线程彻底解耦。
        final class ScriptBox: @unchecked Sendable {
            let script: NSAppleScript
            init(_ script: NSAppleScript) { self.script = script }
        }
        let box = ScriptBox(appleScript)
        DispatchQueue.global(qos: .utility).async {
            var asyncError: NSDictionary?
            let result = box.script.executeAndReturnError(&asyncError)
            if let asyncError {
                log(
                    "[LoginItemManager] stale login item cleanup failed",
                    level: .warn,
                    fields: ["error": asyncError.description]
                )
                return
            }
            let cleaned = result.stringValue ?? ""
            if cleaned != "0" && !cleaned.isEmpty {
                log(
                    "[LoginItemManager] cleaned up stale login items",
                    fields: ["count": cleaned]
                )
            }
        }
    }

    /// 陈旧 login item 清理脚本（纯函数，B264 提取）：System Events 遍历登录项，
    /// 删除「无路径且名字含 VibeFocus/vibe-focus」或「路径含 .build/ 且名字匹配」的条目，
    /// 返回删除计数文本。测试锁定清理语义。
    static func staleLoginItemsCleanupScript() -> String {
        return """
        tell application "System Events"
            set theItems to every login item
            set toDelete to {}
            repeat with anItem in theItems
                set itemPath to path of anItem
                if itemPath is missing value then
                    set itemName to name of anItem
                    if itemName contains "VibeFocus" or itemName contains "vibe-focus" then
                        set end of toDelete to anItem
                    end if
                else if itemPath contains ".build/" and (itemPath contains "VibeFocus" or itemPath contains "vibe-focus") then
                    set end of toDelete to anItem
                end if
            end repeat
            set deletedCount to count of toDelete
            repeat with anItem in toDelete
                delete anItem
            end repeat
            return deletedCount as text
        end tell
        """
    }

    func setEnabled(_ enabled: Bool) {
        // P-INST-63: setEnabled 耗时（SMAppService register/unregister 系统调用 + refresh；设置面板调用，register 可能弹系统对话框阻塞）。
        #if PERF_INSTRUMENT
        let setEnabledStart = Date()
        defer {
            log("[LoginItemManager] setEnabled finished", level: .debug, fields: [
                "enabled": String(enabled),
                "durationMs": String(elapsedMilliseconds(since: setEnabledStart))
            ])
        }
        #endif
        log("LoginItemManager.setEnabled() entered", level: .debug, fields: ["enabled": String(enabled)])
        do {
            if enabled {
                log("LoginItemManager.setEnabled() registering login item", level: .debug)
                try SMAppService.mainApp.register()
            } else {
                log("LoginItemManager.setEnabled() unregistering login item", level: .debug)
                try SMAppService.mainApp.unregister()
            }
            lastErrorMessage = nil
        } catch {
            log("LoginItemManager.setEnabled() error", level: .debug, fields: ["error": error.localizedDescription])
            lastErrorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        log("LoginItemManager.openLoginItemsSettings() opening system settings", level: .debug)
        SMAppService.openSystemSettingsLoginItems()
    }
}
