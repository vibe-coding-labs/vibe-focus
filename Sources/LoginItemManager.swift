import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusTitle: String = "未知"
    @Published private(set) var statusDetail: String = "尚未检测"
    @Published private(set) var requiresApproval: Bool = false
    @Published private(set) var lastErrorMessage: String? = nil

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            statusTitle = "已启用"
            statusDetail = "登录后会自动启动。"
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            statusTitle = "未启用"
            statusDetail = "不会在登录后自动启动。"
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            statusTitle = "待确认"
            statusDetail = "需要在系统设置中确认。"
        case .notFound:
            isEnabled = false
            requiresApproval = false
            statusTitle = "不可用"
            statusDetail = "未能识别为登录项。请使用 ./run.sh 安装为 .app bundle。"
        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusTitle = "未知"
            statusDetail = "系统返回未知状态。"
        }

        // 清理指向 .build/ 目录的旧裸二进制 login items
        cleanupStaleLoginItems()
    }

    /// 清理指向 .build/ 目录的旧裸二进制 login items 和 missing value 条目。
    /// 这些是之前直接运行裸二进制时注册的，无法正常工作。
    private func cleanupStaleLoginItems() {
        let script = """
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
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            log(
                "[LoginItemManager] stale login item cleanup failed",
                level: .warn,
                fields: ["error": error.description]
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

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
