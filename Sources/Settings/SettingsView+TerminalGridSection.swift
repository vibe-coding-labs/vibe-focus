import AppKit
import Combine
import SwiftUI

// MARK: - 编排页（终端网格 · Claude 会话编排）
// 独立标签页：屏幕布局 minimap 为主视觉，参数/偏好/快照各归其卡。
// 2026-09-07 拆分：参数/会话卡 → +TerminalGridActions，快照卡 → +TerminalGridSnapshots，
// 通用控件 → GridSnapshotWidgets.swift。目标摘要文案提纯为 GridTargetCode.summaryText。
extension SettingsView {

    @ViewBuilder
    var terminalGridSection: some View {
        Group {
        gridMinimapPanel

        terminalSessionCard

        // 已保存布局
        if !gridSnapshots.isEmpty {
            savedLayoutsCard
        }
        }
        .onAppear {
            refreshGridMinimap()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // 接拔显示器 / 分辨率变化后重建缩略图
            refreshGridMinimap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vibefocusSpaceStateMayHaveChanged)
            // 防抖合并信号连发（SIGUSR1/插拔/toggle 汇聚点已自带去重闸，这里再并突发）
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)) { _ in
            // 根治编排区「快照与现实脱节」家族（双高亮/S 标注滞后/编号漂移）：
            // 任何来源的 space 变化（快捷键/胶囊点击/外部 yabai 命令/其它会话）经
            // overlay 信号链广播到此，编排页可见即自动重建快照，绕缓存取稳态值——
            // 不再依赖离散的手工刷新点，UI 自愈（2026-09-10 用户要求根治）。
            refreshGridMinimap(ignoreCache: true)
        }
    }

    /// 主视觉：真实屏幕布局 minimap（点阵画布）
    var gridMinimapPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                SectionIconChip(icon: "display")

                Text("屏幕布局")
                    .font(.system(size: 13.5, weight: .semibold))

                HStack(spacing: 4) {
                    Circle()
                        .fill(VibeColors.success)
                        .frame(width: 5, height: 5)
                        .shadow(color: VibeColors.success.opacity(0.6), radius: 2.5)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                }
                .foregroundStyle(VibeColors.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(VibeColors.success.opacity(0.10)))
                .overlay(Capsule().strokeBorder(VibeColors.success.opacity(0.20), lineWidth: 1))

                Text("点屏幕选目标屏 · 点胶囊切换该屏工作区并设为编排目标")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if let selectedSummary = gridTargetSummary {
                    Text(selectedSummary)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(VibeColors.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(VibeColors.accent.opacity(0.09)))
                        .overlay(Capsule().strokeBorder(VibeColors.accent.opacity(0.22), lineWidth: 1))
                }
            }

            ScreenMinimapView(
                screens: gridMinimapScreens,
                selected: GridTargetCode.parse(gridTargetCode),
                gridPreviewRows: gridRows,
                gridPreviewCols: gridCols,
                height: 320,
                onSelect: { target in
                    gridTargetCode = target.code
                    TerminalGridPreferences.target = target.code
                    // 胶囊点击 = 同时 live 切换该屏到该工作区（2026-09-07 用户报告
                    // 「点了没反应」）。复用 restore 视角链（SA 直切→聚焦带动降级），
                    // 结局如实反馈——空工作区无 SA 切不动，不许静默。
                    if case .displaySpace(let displayID, let spaceIndex) = target {
                        // 反馈文案与胶囊同语言：「屏号-位次」；快照缺失回退全局号
                        let label: String
                        if let screen = gridMinimapScreens.first(where: { $0.displayID == displayID }),
                           let position = ScreenLayoutMapper.positionInDisplay(of: spaceIndex, inAscendingIndexes: screen.spaces.map(\.yabaiIndex)) {
                            label = ScreenLayoutMapper.userVisibleSpaceLabel(
                                displayIndex: screen.yabaiDisplayIndex, positionInDisplay: position, yabaiIndex: spaceIndex)
                        } else {
                            label = "Space \(spaceIndex)"
                        }
                        let result = SpaceController.shared.switchToSpace(
                            spaceIndex,
                            operationID: "minimap-space-\(spaceIndex)-\(Int(Date().timeIntervalSince1970 * 1000))"
                        )
                        let outcome = result.outcome
                        // B173：文案按目标状态分流（missing=布局漂移、unknown=查询失败），
                        // 不再与「空工作区无窗口」共用一句误导文案。
                        gridSpaceSwitchMessage = GridSpaceSwitchFeedback.message(for: outcome, label: label, state: result.state)
                        // live 切换成功后必须重建 minimap 快照：isVisible 高亮与 S 标注
                        // 都来自快照，不刷新的话旧工作区仍亮「当前」、新目标只有描边——
                        // 两处同时高亮（2026-09-10 用户报告）。refocused 路径 yabai 状态
                        // 落定可能略滞后于视角链返回，延迟再补刷一次兜底。
                        switch outcome {
                        case .noDrift:
                            refreshGridMinimap(ignoreCache: true)
                        case .refocused:
                            refreshGridMinimap(ignoreCache: true)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                refreshGridMinimap(ignoreCache: true)
                            }
                        case .failed:
                            break  // 切换未发生，快照仍与真实状态一致
                        }
                    }
                }
            )
            .padding(.top, 12)

            if let switchMessage = gridSpaceSwitchMessage {
                Text(switchMessage)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            if GridTargetCode.parse(gridTargetCode)?.explicitDisplayID.map({ displayID in
                !gridMinimapScreens.contains { $0.displayID == displayID }
            }) == true {
                InfoBanner(style: .warning, text: "当前编排目标的显示器已断开（\(gridTargetCode)）。") {
                    Button("重置为主屏") {
                        gridTargetCode = GridTargetCode.main.code
                        TerminalGridPreferences.target = gridTargetCode
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 12)
            }

            // 网格参数区内嵌本面板（原独立「网格」卡，2026-09-10 用户反馈合并）：
            // minimap 选中屏上的预览格线就是下面行列参数的实时投影，一体呈现。
            Divider()
                .padding(.top, 14)

            gridParamsSection
                .padding(.top, 12)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                .fill(Color.primary.opacity(0.032))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                .strokeBorder(VibeColors.hairline, lineWidth: 1)
        )
    }

    /// 当前编排目标的摘要胶囊文案（标注语言=「屏号-位次」，2026-09-09 用户裁定——
    /// 与 minimap 胶囊/S 标注/overlay 角标同一语言；查不到快照时回退
    /// #CGDisplayID / Space 全局索引老格式）
    var gridTargetSummary: String? {
        guard let target = GridTargetCode.parse(gridTargetCode) else { return nil }
        func yabaiLabel(_ displayID: UInt32) -> String {
            if let y = gridMinimapScreens.first(where: { $0.displayID == displayID })?.yabaiDisplayIndex {
                return "屏\(y)"
            }
            return "#\(displayID)"
        }
        // 目标工作区的用户可见标注：「屏号-位次」；快照缺失时回退全局索引
        func spaceLabel(_ displayID: UInt32, _ globalIndex: Int) -> String {
            guard let screen = gridMinimapScreens.first(where: { $0.displayID == displayID }),
                  let position = ScreenLayoutMapper.positionInDisplay(
                    of: globalIndex, inAscendingIndexes: screen.spaces.map(\.yabaiIndex)) else {
                return "Space \(globalIndex)"
            }
            return ScreenLayoutMapper.userVisibleSpaceLabel(
                displayIndex: screen.yabaiDisplayIndex, positionInDisplay: position, yabaiIndex: globalIndex)
        }
        switch target {
        case .main:
            return "→ 主屏"
        case .focused:
            return "→ 焦点屏"
        case .display(let displayID):
            return "→ \(yabaiLabel(displayID)) 当前 Space"
        case .displaySpace(let displayID, let spaceIndex):
            return "→ \(yabaiLabel(displayID)) · \(spaceLabel(displayID, spaceIndex))"
        }
    }

    /// minimap 数据构建：真实屏幕快照（Cocoa frame）+ yabai 空间快照。
    /// yabai 不可用时 Space 带为空，minimap 退化为纯屏幕选择，功能不缺失。
    /// ignoreCache=true 供胶囊 live 切换后的即时重建用——默认缓存会吐出切换前的
    /// 可见位，高亮就停在旧工作区上（2026-09-10 用户报告）。
    func refreshGridMinimap(ignoreCache: Bool = false) {
        // B178 常开埋点：编排页 live 重建（yabai fork 同步在主线程），广播触发频率高
        // （SIGUSR1/插拔/toggle 汇聚 + 400ms 防抖），设置页卡顿归因靠它。
        PerfMonitor.shared.beginSection("minimap.refresh", fields: ["ignoreCache": String(ignoreCache)])
        defer { PerfMonitor.shared.endSection() }
        let spacesByYabaiDisplay: [Int: [ScreenLayoutMapper.InputSpace]] = Dictionary(grouping: (SpaceController.shared.querySpaces(ignoreCache: ignoreCache) ?? []).compactMap { info -> (display: Int, space: ScreenLayoutMapper.InputSpace)? in
            guard let index = info.index, let display = info.display else { return nil }
            return (display, ScreenLayoutMapper.InputSpace(yabaiIndex: index, isVisible: info.isVisible ?? false))
        }, by: { $0.display }).mapValues { $0.map { $0.space }.sorted { $0.yabaiIndex < $1.yabaiIndex } }

        // 屏标签/胶囊挂接统一走精确解析器（几何匹配 + 1s 缓存，Batch 33/34）。
        let screens = NSScreen.screens
        gridMinimapScreens = screens.map { screen in
            let displayID = CoordinateKit.cgDisplayID(for: screen) ?? 0
            let yabaiIndex = SpaceController.shared.exactYabaiDisplayIndex(for: screen)
            return ScreenLayoutMapper.InputScreen(
                displayID: displayID,
                name: screen.localizedName,
                cocoaFrame: screen.frame,
                isMain: displayID == CGMainDisplayID(),
                spaces: yabaiIndex.flatMap { spacesByYabaiDisplay[$0] } ?? [],
                yabaiDisplayIndex: yabaiIndex
            )
        }
    }
}
