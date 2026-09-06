import AppKit
import SwiftUI

// MARK: - 网格编排页通用控件（2026-09-07 从 TerminalGridSection 拆分）
// GridSnapshotThumbnail：快照行 mini 格位图；CompactStepper/StepIconButton：行×列紧凑步进器。

/// 快照行的 mini 格位缩略图（rows×cols 格线示意）
struct GridSnapshotThumbnail: View {
    let rows: Int
    let cols: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(VibeColors.accent.opacity(0.50), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: 30, height: 22)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VibeColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
    }
}


/// 紧凑数值步进器：− 数值 ＋（系统 Stepper 在紧凑布局下只剩裸箭头、数值不可见）
struct CompactStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(symbol: "minus", enabled: value > range.lowerBound) { onChange(value - 1) }
            Text("\(value)")
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 26)
            stepButton(symbol: "plus", enabled: value < range.upperBound) { onChange(value + 1) }
        }
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                .fill(VibeColors.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.control, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
    }

    private func stepButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        StepIconButton(symbol: symbol, enabled: enabled, action: action)
    }
}

/// 步进器单键：悬停着色 + 按压回弹（独立视图持有 hover 状态，避免整条重绘）
private struct StepIconButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    enabled
                        ? Color.primary.opacity(isHovered ? 0.85 : 0.5)
                        : Color.primary.opacity(0.16)
                )
                .frame(width: 26, height: 26)
                .background(
                    Rectangle()
                        .fill(Color.primary.opacity(enabled && isHovered ? 0.05 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}
