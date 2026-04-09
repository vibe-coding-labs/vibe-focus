import Foundation

enum LaunchPhase: String, CaseIterable {
    case initializing = "初始化中"
    case checkingSingleInstance = "检查单实例"
    case checkingInstallation = "检查安装位置"
    case loadingConfiguration = "加载配置"
    case checkingPermissions = "检查权限"
    case settingUpHotkeys = "设置热键"
    case settingUpMenuBar = "设置菜单栏"
    case startingServices = "启动服务"
    case completed = "启动完成"
    case failed = "启动失败"

    var progress: Double {
        switch self {
        case .initializing: return 0.0
        case .checkingSingleInstance: return 0.1
        case .checkingInstallation: return 0.2
        case .loadingConfiguration: return 0.3
        case .checkingPermissions: return 0.5
        case .settingUpHotkeys: return 0.7
        case .settingUpMenuBar: return 0.8
        case .startingServices: return 0.9
        case .completed: return 1.0
        case .failed: return 1.0
        }
    }
}

struct LaunchPhaseResult {
    let phase: LaunchPhase
    let success: Bool
    let message: String?
    let error: LaunchError?
    let duration: TimeInterval
}

enum LaunchError: Error {
    case anotherInstanceRunning
    case invalidInstallationLocation
    case accessibilityPermissionDenied
    case hotkeyRegistrationFailed
    case serviceStartupFailed

    var localizedDescription: String {
        switch self {
        case .anotherInstanceRunning:
            return "检测到另一个 VibeFocus 实例正在运行"
        case .invalidInstallationLocation:
            return "应用安装位置不正确"
        case .accessibilityPermissionDenied:
            return "需要辅助功能权限才能控制窗口"
        case .hotkeyRegistrationFailed:
            return "热键注册失败"
        case .serviceStartupFailed:
            return "服务启动失败"
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .anotherInstanceRunning:
            return "请退出其他实例后重试，或切换到已运行的实例"
        case .invalidInstallationLocation:
            return "请将应用移动到 ~/Applications/ 或 /Applications/ 目录"
        case .accessibilityPermissionDenied:
            return "请在系统设置中授予 VibeFocus 辅助功能权限"
        case .hotkeyRegistrationFailed:
            return "请检查快捷键是否与其他应用冲突"
        case .serviceStartupFailed:
            return "请重启应用或检查系统日志"
        }
    }
}
