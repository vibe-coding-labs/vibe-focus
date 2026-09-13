import Foundation

// MARK: - 编排页屏幕布局刷新策略（纯决策）
/// LIVE minimap 有三个刷新来源，共用此契约：
/// 1. 信号（.vibefocusSpaceStateMayHaveChanged 防抖）——VibeFocus 内部改动/yabai
///    signal 链（SIGUSR1）即时刷新，主通道；
/// 2. 心跳（每 autoRefreshIntervalSeconds 一拍，cache-aware 走默认缓存路径）——
///    不经过 VibeFocus 的外部改动（命令行 yabai、其它会话、signal 注册失效/挂起
///    闸门吞广播的缝隙）不广播任何信号，靠周期心跳兜住「LIVE」语义
///    （2026-09-13 用户要求：每个屏的最新工作区随时在变）；
/// 3. 手动（面板头部刷新按钮）——用户显式刷新，强制绕过查询缓存。
/// 心跳唯一纪律：设置窗不可见时静默跳过。设置窗 isReleasedWhenClosed=false，
/// 关窗后 SwiftUI 视图仍挂在 contentViewController 上、订阅不拆——没有可见性
/// 门控，心跳会退化成永不停歇的后台 yabai fork（B179 主线程停顿教训）。
enum MinimapRefreshPolicy {

    /// 心跳周期（秒）。querySpaces 缓存 TTL=2s：周期 > TTL 保证窗口可见时每拍
    /// 都取到新状态；周期内若信号链刚刷过，心跳命中缓存不重复 fork。
    static let autoRefreshIntervalSeconds: TimeInterval = 3

    /// 心跳拍是否允许执行刷新（唯一入参 = 设置窗是否 on-screen 可见，
    /// 取 NSWindow.occlusionState.contains(.visible)：最小化/完全遮挡/不在当前
    /// Space 均为 false）。
    static func shouldHeartbeatRefresh(windowVisible: Bool) -> Bool {
        windowVisible
    }
}
