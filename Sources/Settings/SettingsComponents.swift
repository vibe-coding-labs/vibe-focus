// SettingsComponents.swift
// VibeFocus — 设置页核心展示组件
// 快捷键/滑块交互组件已移至 SettingsComponents+Shortcuts.swift
// 导航与品牌图标已移至 SettingsComponents+Navigation.swift
// 色彩/圆角/横幅等 token 见 DesignSystem.swift

import AppKit
import SwiftUI
import Foundation

// MARK: - Settings Card

/// Reusable card container with rounded corners for settings sections.
/// icon 传入 SF Symbol 名即渲染标题左侧的 tinted 徽章（各区块的视觉锚点）。
struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    var icon: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    if let icon {
                        SectionIconChip(icon: icon)
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(VibeColors.ink)
                }
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(20)
        .vibeCardStyle()
    }
}

// MARK: - Code Block View

/// Monospaced code block view for displaying terminal commands and scripts.
struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CapsuleTag(text: language)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }

            Spacer(minLength: 8)

            Button(action: copyToClipboard) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCopied ? VibeColors.success : Color.secondary.opacity(isHovered ? 0.9 : 0.55))
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: VibeRadius.chip, style: .continuous)
                            .fill(Color.primary.opacity(isHovered ? 0.06 : 0.035))
                    )
            }
            .buttonStyle(.plain)
            .help("复制命令")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.chip + 2, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.chip + 2, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func copyToClipboard() {
        // P-INST-239: 复制安装命令到剪贴板耗时（NSPasteboard.clearContents + setString 剪贴板 IPC；设置 UI 复制按钮触发，withAnimation/asyncAfter UI 反馈不计入；slow-op ≥5ms warn）。
        #if PERF_INSTRUMENT
        let ctcStart = Date()
        #endif
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #if PERF_INSTRUMENT
        let durMs = elapsedMilliseconds(since: ctcStart)
        if durMs >= 5 { log("[SettingsComponents] copyToClipboard slow", level: .warn, fields: ["durationMs": String(durMs)]) }
        #endif
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - Status Pill

/// Colored status indicator pill for showing connection or feature state.
struct SettingsStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.55), radius: 2.5)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.trailing, 5)
        }
        .padding(.leading, 10)
        .padding(.vertical, 5.5)
        .background(
            Capsule().fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
        .foregroundStyle(tint)
    }
}

// MARK: - Sidebar Info Card

/// Information card displayed in the settings sidebar.
struct SidebarInfoCard: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Settings Row

/// Single row in a settings section with label and accessory view.
struct SettingsRow<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory
        }
    }
}
