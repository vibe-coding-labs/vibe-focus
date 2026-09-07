// SettingsUI+Helpers.swift
// VibeFocus — SettingsView 展示助手（版本/路径/Space 状态文案）
// 会话列表已移至 SettingsView+SessionLists.swift（B35）

import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Display Helpers

    var appVersionDisplay: String {
        // P-INST-106: 版本显示字符串构造耗时（Bundle.main.infoDictionary 字典查找 + 字符串拼接；设置 UI 渲染调用）。
        #if PERF_INSTRUMENT
        let avdStart = Date()
        defer {
            log("SettingsUI.appVersionDisplay finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: avdStart))
            ])
        }
        #endif
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (bundleVersion?.isEmpty == false) ? bundleVersion ?? AppVersion.current : AppVersion.current
        return "v\(version)"
    }

    var bundleIdentifier: String {
        // P-INST-107: bundleIdentifier 读取耗时（Bundle.main.bundleIdentifier；设置 UI 多处调用）。
        #if PERF_INSTRUMENT
        let biStart = Date()
        defer {
            log("SettingsUI.bundleIdentifier finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: biStart))
            ])
        }
        #endif
        return Bundle.main.bundleIdentifier ?? "com.openai.vibe-focus"
    }

    var currentAppPath: String {
        // P-INST-108: 当前 app 路径读取耗时（Bundle.main.bundleURL.path；设置 UI + 安装位置检测调用）。
        #if PERF_INSTRUMENT
        let capStart = Date()
        defer {
            log("SettingsUI.currentAppPath finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: capStart))
            ])
        }
        #endif
        return Bundle.main.bundleURL.path
    }

    var expectedAppPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/VibeFocus.app")
    }

    var otherInstallations: [String] {
        duplicateAppPaths.filter { $0 != currentAppPath }
    }

    var resetAccessCommand: String {
        "tccutil reset Accessibility \(bundleIdentifier)"
    }

    // MARK: - Space Status Helpers

    var spaceStatusTitle: String {
        switch spaceController.availability {
        case .available:
            return "可用"
        case .notInstalled:
            return "未安装"
        case .unavailable:
            return "不可用"
        case .unknown:
            return "未检测"
        }
    }

    var spaceStatusTint: Color {
        switch spaceController.availability {
        case .available:
            return VibeColors.success
        case .notInstalled, .unknown:
            return VibeColors.neutral
        case .unavailable:
            return VibeColors.warning
        }
    }

    var spaceStatusDetail: String {
        switch spaceController.availability {
        case .available:
            return "检测到 yabai，可启用跨工作区移动。"
        case .notInstalled:
            return "未检测到 yabai。安装后可启用跨工作区移动功能。"
        case .unavailable:
            return "yabai 已安装但未就绪（可能需要配置 SIP 或授予权限）。"
        case .unknown:
            return "尚未检测 yabai 状态。"
        }
    }
}
