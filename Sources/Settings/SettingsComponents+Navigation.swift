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
                            .fill(VibeColors.accent)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
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

/// 分段式标签栏：凹槽底 + 滑动选中块（matchedGeometryEffect），
/// 选中态 = 亮面浮起小块，观感对齐 macOS 原生分段控件。
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    @Namespace private var thumbNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.control + 2, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.control + 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6.5)
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.52))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "tab-thumb", in: thumbNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(tab.rawValue)
    }
}
