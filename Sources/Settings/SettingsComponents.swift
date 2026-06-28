// SettingsComponents.swift
// VibeFocus — 设置页核心展示组件
// 快捷键/滑块交互组件已移至 SettingsComponents+Shortcuts.swift
// 导航与品牌图标已移至 SettingsComponents+Navigation.swift

import AppKit
import SwiftUI
import Foundation

// MARK: - Settings Card

/// Reusable card container with rounded corners for settings sections.
struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Code Block View

/// Monospaced code block view for displaying terminal commands and scripts.
struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(isCopied ? "已复制" : "复制")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        )
    }

    private func copyToClipboard() {
        // P-INST-239: 复制安装命令到剪贴板耗时（NSPasteboard.clearContents + setString 剪贴板 IPC；设置 UI 复制按钮触发，withAnimation/asyncAfter UI 反馈不计入；slow-op ≥5ms warn）。
        let ctcStart = Date()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        let durMs = elapsedMilliseconds(since: ctcStart)
        if durMs >= 5 { log("[SettingsComponents] copyToClipboard slow", level: .warn, fields: ["durationMs": String(durMs)]) }
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
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.12))
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory
        }
    }
}
