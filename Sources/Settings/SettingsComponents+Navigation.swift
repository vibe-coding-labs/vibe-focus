// SettingsComponents+Navigation.swift
// VibeFocus — 设置页标签导航与品牌图标
// 从 SettingsComponents.swift 中提取

import AppKit
import SwiftUI

// MARK: - App Branding

func bundledAppIconImage() -> NSImage? {
    // P-INST-103: 应用图标加载耗时（Bundle.main.url(forResource:) stat 查找 + NSImage(contentsOf:) 读+解码 icns/png 图像文件；applyApplicationIcon P-INST-102 启动路径 + settings AppLogoBadge SwiftUI body 渲染调用；图像解码可阻塞）。
    let baiStart = Date()
    defer {
        log("[Settings] bundledAppIconImage finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: baiStart))
        ])
    }
    if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: icnsURL) {
        return image
    }
    if let pngURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
       let image = NSImage(contentsOf: pngURL) {
        return image
    }
    return nil
}

/// Small badge view displaying the app icon in the settings sidebar.
struct AppLogoBadge: View {
    var size: CGFloat = 84

    var body: some View {
        Group {
            if let image = bundledAppIconImage() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "rectangle.3.group.bubble.left.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

// MARK: - Tab Navigation

/// Tabs available in the settings window.
enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case workspace = "工作区"
    case claudeIntegration = "Claude 集成"
    case appearance = "外观与反馈"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .workspace: return "macwindow"
        case .claudeIntegration: return "link"
        case .appearance: return "paintbrush"
        }
    }
}

/// Single tab button used in the settings sidebar navigation.
struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
