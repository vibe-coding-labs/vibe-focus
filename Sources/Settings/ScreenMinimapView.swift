import SwiftUI

// MARK: - 屏幕布局缩略图（可视化编排目标选择）
/// 把整机屏幕按真实物理布局画成一张 mini map：每块屏一个圆角矩形（名称/分辨率/
/// displayID/主屏标），屏底缘内嵌 Space 胶囊；点击屏幕 = 编排到该屏当前工作区，
/// 点击某个 Space 胶囊 = 编排到该屏该工作区；选中目标屏内实时叠加 rows×cols
/// 网格预览——所见即所得。
/// 视觉语言：中性灰阶为底，accent 只做选中/当前两处点缀；格线画内部细实线
/// （逐格 strokeBorder 会在相邻边叠加变粗，dash 显糙）。

struct ScreenMinimapView: View {

    let screens: [ScreenLayoutMapper.InputScreen]
    let selected: GridTargetCode?
    let gridPreviewRows: Int
    let gridPreviewCols: Int
    /// 容器高度（编排页主视觉传更大值）
    var height: CGFloat = 216
    let onSelect: (GridTargetCode) -> Void

    @State private var hoveredDisplayID: UInt32?

    private enum Metrics {
        static let screenCornerRadius: CGFloat = 10
        static let spaceCornerRadius: CGFloat = 3.5
        static let gridLineThickness: CGFloat = 0.75
    }

    var body: some View {
        GeometryReader { geo in
            let layout = ScreenLayoutMapper.map(screens: screens, viewSize: geo.size)
            // 内容整体在容器内居中（真实布局 union 常偏一侧）
            let centeringX = (geo.size.width - layout.contentRect.width) / 2 - layout.contentRect.minX
            let centeringY = (geo.size.height - layout.contentRect.height) / 2 - layout.contentRect.minY

            ZStack(alignment: .topLeading) {
                DotGridPattern()

                ForEach(layout.screens, id: \.displayID) { screen in
                    screenView(screen)
                        .offset(x: screen.frame.minX, y: screen.frame.minY)
                }
                ForEach(layout.screens, id: \.displayID) { screen in
                    let showStrip = screen.frame.height >= ScreenLayoutMapper.minScreenHeightForStrip
                    ForEach(showStrip ? screen.spaces : [], id: \.yabaiIndex) { space in
                        spaceCapsule(screen, space)
                            .offset(x: space.frame.minX, y: space.frame.minY)
                    }
                }
            }
            .offset(x: centeringX, y: centeringY)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(height: height)
    }

    // MARK: 单块屏

    private func isSelectedScreen(_ screen: ScreenLayoutMapper.MappedScreen) -> Bool {
        selected?.explicitDisplayID == screen.displayID
    }

    private func screenView(_ screen: ScreenLayoutMapper.MappedScreen) -> some View {
        let selectedScreen = isSelectedScreen(screen)
        let hovered = hoveredDisplayID == screen.displayID

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Metrics.screenCornerRadius, style: .continuous)
                .fill(
                    selectedScreen ? VibeColors.accent.opacity(0.055)
                    : VibeColors.card.opacity(hovered ? 1 : 0.85)
                )

            RoundedRectangle(cornerRadius: Metrics.screenCornerRadius, style: .continuous)
                .strokeBorder(
                    selectedScreen ? VibeColors.accent.opacity(0.85)
                    : Color.primary.opacity(hovered ? 0.34 : 0.15),
                    lineWidth: selectedScreen ? 1.5 : 1
                )

            if !smallScreen(screen) {
                screenLabels(screen, selected: selectedScreen)
            }

            if selectedScreen, gridPreviewRows >= 1, gridPreviewCols >= 1 {
                gridPreviewLines(size: screen.frame.size)
            }
        }
        .shadow(
            color: selectedScreen ? VibeColors.accent.opacity(0.20)
                : hovered ? Color.black.opacity(0.10) : Color.black.opacity(0.05),
            radius: selectedScreen ? 8 : (hovered ? 5 : 3),
            y: 2
        )
        .frame(width: screen.frame.width, height: screen.frame.height)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.screenCornerRadius))
        .onHover { hovering in
            if hovering {
                hoveredDisplayID = screen.displayID
            } else if hoveredDisplayID == screen.displayID {
                hoveredDisplayID = nil
            }
        }
        .onTapGesture { onSelect(.display(displayID: screen.displayID)) }
        .animation(.easeOut(duration: 0.15), value: hoveredDisplayID)
        .animation(.easeOut(duration: 0.15), value: selectedScreen)
        .help(screenTapHelp(screen))
        .accessibilityLabel(screenTapHelp(screen))
        .accessibilityAddTraits(selectedScreen ? .isSelected : [])
    }

    private func smallScreen(_ screen: ScreenLayoutMapper.MappedScreen) -> Bool {
        screen.frame.width < 96 || screen.frame.height < 64
    }

    /// 两行标签：名称（+主标）一行、等宽元数据一行——同 HStack 挤一行必然截断
    private func screenLabels(_ screen: ScreenLayoutMapper.MappedScreen, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(screen.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(selected ? 0.88 : 0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if screen.isMain {
                    Text("主")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(VibeColors.accent))
                }
            }
            Text(labelLine(screen))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(9)
    }

    private func labelLine(_ screen: ScreenLayoutMapper.MappedScreen) -> String {
        var parts: [String] = []
        if let input = screens.first(where: { $0.displayID == screen.displayID }) {
            parts.append("\(Int(input.cocoaFrame.width))×\(Int(input.cocoaFrame.height))")
        }
        parts.append("#\(screen.displayID)")
        if let visible = screen.visibleSpaceIndex {
            parts.append("S\(visible)")
        }
        return parts.joined(separator: "  ")
    }

    // MARK: 网格预览（选中目标屏内叠加 rows×cols 内部格线）

    /// 只画内部格线（rows-1 横 + cols-1 竖）：细实线、低透明度，不与选中描边重叠
    private func gridPreviewLines(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if gridPreviewRows > 1 {
                ForEach(1..<gridPreviewRows, id: \.self) { row in
                    let y = size.height * CGFloat(row) / CGFloat(gridPreviewRows)
                    Rectangle()
                        .fill(VibeColors.accent.opacity(0.30))
                        .frame(width: size.width, height: Metrics.gridLineThickness)
                        .offset(x: 0, y: y - Metrics.gridLineThickness / 2)
                }
            }
            if gridPreviewCols > 1 {
                ForEach(1..<gridPreviewCols, id: \.self) { col in
                    let x = size.width * CGFloat(col) / CGFloat(gridPreviewCols)
                    Rectangle()
                        .fill(VibeColors.accent.opacity(0.30))
                        .frame(width: Metrics.gridLineThickness, height: size.height)
                        .offset(x: x - Metrics.gridLineThickness / 2, y: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Space 胶囊

    private func spaceCapsule(_ screen: ScreenLayoutMapper.MappedScreen, _ space: ScreenLayoutMapper.MappedSpace) -> some View {
        let isTargetSpace = selected == .displaySpace(displayID: screen.displayID, spaceIndex: space.yabaiIndex)
        return RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius + 0.5, style: .continuous)
            .fill(
                isTargetSpace ? VibeColors.accent.opacity(0.16)
                : space.isVisible ? VibeColors.accent.opacity(0.18)
                : Color.primary.opacity(0.055)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius + 0.5, style: .continuous)
                    .strokeBorder(
                        isTargetSpace ? VibeColors.accent : Color.clear,
                        lineWidth: 1.2
                    )
            )
            .frame(width: space.frame.width, height: space.frame.height)
            .overlay(
                Text("\(space.yabaiIndex)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        isTargetSpace ? VibeColors.accent
                        : space.isVisible ? Color.primary.opacity(0.72)
                        : Color.secondary.opacity(0.7)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius + 0.5))
            .onTapGesture { onSelect(.displaySpace(displayID: screen.displayID, spaceIndex: space.yabaiIndex)) }
            .help("Space \(space.yabaiIndex)\(space.isVisible ? "（当前）" : "")——编排到此工作区")
            .accessibilityLabel("屏幕 \(screen.name) Space \(space.yabaiIndex)")
            .accessibilityAddTraits(isTargetSpace ? .isSelected : [])
    }

    private func screenTapHelp(_ screen: ScreenLayoutMapper.MappedScreen) -> String {
        if let visible = screen.visibleSpaceIndex {
            return "编排到「\(screen.name)」当前工作区 Space \(visible)"
        }
        return "编排到「\(screen.name)」"
    }
}
