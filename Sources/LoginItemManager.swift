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
            statusDetail = "未能识别为登录项。"
        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusTitle = "未知"
            statusDetail = "系统返回未知状态。"
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
