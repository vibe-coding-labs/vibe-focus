// SettingsComponents+Navigation.swift
// VibeFocus — 设置页标签导航与品牌图标
// 从 SettingsComponents.swift 中提取

import AppKit
import SwiftUI

// MARK: - App Branding

func bundledAppIconImage() -> NSImage? {
    // P-INST-103: 应用图标加载耗时（Bundle.main.url(forResource:) stat 查找 + NSImage(contentsOf:) 读+解码 icns/png 图像文件；applyApplicationIcon P-INST-102 启动路径 + settings AppLogoBadge SwiftUI body 渲染调用；图像解码可阻塞）。
    #if PERF_INSTRUMENT
    let baiStart = Date()
    defer {
        log("[Settings] bundledAppIconImage finished", level: .debug, fields: [
            "durationMs": String(elapsedMilliseconds(since: baiStart))
        ])
    }
    #endif
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
    case orchestration = "编排"
    case claudeIntegration = "Claude 集成"
    case appearance = "外观与反馈"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .workspace: return "macwindow"
        case .orchestration: return "rectangle.split.2x2"
        case .claudeIntegration: return "link"
        case .appearance: return "paintbrush"
        }
    }
}

/// Single tab button used in the settings navigation.
struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected ? Color.accentColor.opacity(0.13)
                        : isHovered ? Color.primary.opacity(0.05)
                        : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.75 : 0.55))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
