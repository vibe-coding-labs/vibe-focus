import SwiftUI

// MARK: - 屏幕布局缩略图（可视化编排目标选择）
/// 把整机屏幕按真实物理布局画成一张 mini map：每块屏一个圆角矩形（名称/分辨率/
/// displayID/主屏标），屏下一排 Space 胶囊；点击屏幕 = 编排到该屏当前工作区，
/// 点击某个 Space 胶囊 = 编排到该屏该工作区；选中目标屏内实时叠加 rows×cols
/// 网格预览——所见即所得。

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
        static let screenCornerRadius: CGFloat = 8
        static let spaceCornerRadius: CGFloat = 4
    }

    var body: some View {
        GeometryReader { geo in
            let layout = ScreenLayoutMapper.map(screens: screens, viewSize: geo.size)
            ZStack(alignment: .topLeading) {
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
                .fill(selectedScreen ? Color.accentColor.opacity(0.10) : Color.primary.opacity(hovered ? 0.07 : 0.04))

            RoundedRectangle(cornerRadius: Metrics.screenCornerRadius, style: .continuous)
                .strokeBorder(
                    selectedScreen ? Color.accentColor : Color.primary.opacity(hovered ? 0.55 : 0.28),
                    lineWidth: selectedScreen ? 2 : 1
                )

            if smallScreen(screen) {
                // 缩略得太小的屏不放文字，靠 tooltip
                EmptyView()
            } else {
                screenLabels(screen)
            }

            if selectedScreen, gridPreviewRows >= 1, gridPreviewCols >= 1 {
                gridPreview(size: screen.frame.size)
            }
        }
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
        .help(screenTapHelp(screen))
        .accessibilityLabel(screenTapHelp(screen))
        .accessibilityAddTraits(selectedScreen ? .isSelected : [])
    }

    private func smallScreen(_ screen: ScreenLayoutMapper.MappedScreen) -> Bool {
        screen.frame.width < 96 || screen.frame.height < 64
    }

    private func screenLabels(_ screen: ScreenLayoutMapper.MappedScreen) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(screen.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if screen.isMain {
                Text("主")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
            }
            Spacer(minLength: 0)
            Text(labelLine(screen))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(7)
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
        return parts.joined(separator: " · ")
    }

    // MARK: 网格预览（选中目标屏内叠加 rows×cols）

    private func gridPreview(size: CGSize) -> some View {
        let cells = ScreenLayoutMapper.gridPreviewCells(
            screenFrame: CGRect(origin: .zero, size: size),
            rows: gridPreviewRows,
            cols: gridPreviewCols
        )
        return ZStack(alignment: .topLeading) {
            ForEach(cells.indices, id: \.self) { index in
                let cell = cells[index]
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Space 胶囊

    private func spaceCapsule(_ screen: ScreenLayoutMapper.MappedScreen, _ space: ScreenLayoutMapper.MappedSpace) -> some View {
        let isTargetSpace = selected == .displaySpace(displayID: screen.displayID, spaceIndex: space.yabaiIndex)
        return RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius, style: .continuous)
            .fill(
                isTargetSpace ? Color.accentColor.opacity(0.22)
                : space.isVisible ? Color.accentColor.opacity(0.14)
                : Color.primary.opacity(0.05)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius, style: .continuous)
                    .strokeBorder(
                        isTargetSpace ? Color.accentColor : Color.primary.opacity(0.22),
                        lineWidth: isTargetSpace ? 1.5 : 1
                    )
            )
            .frame(width: space.frame.width, height: space.frame.height)
            .overlay(
                Text("\(space.yabaiIndex)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(space.isVisible || isTargetSpace ? Color.primary : Color.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.spaceCornerRadius))
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
