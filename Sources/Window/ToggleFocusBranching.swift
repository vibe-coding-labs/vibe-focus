import Foundation

// MARK: - Toggle 三分支焦点决策纯内核（quality-plan P6 步骤 1，2026-09-07）
// 「分支选择策略」从 resolveFocusedWindowForToggle 的探测执行（计时/副作用/嵌套 if-else）
// 中拆出，独立为无状态纯函数：策略可被真实实现测试穷尽锁定（Runner 直测，无镜像漂移），
// 探测壳只保留「按阻塞代价递增的 lazy 探测顺序」（CGWindowList ~5ms → yabai ~648ms →
// AX ~1.5s；顺序红线与竞态史见 resolveFocusedWindowForToggle 注释，禁止把 AX 分支提前）。
// 行为零变更：各判定与拆分前 if-else 条件逐条对齐（含「count==1 但 bounds 缺失 → 落
// yabai」这类边界）。

enum ToggleFocusBranching {

    /// 分支 1 候选集：前台 app 自己的普通可见窗口（ownerPID 匹配 + layer==0 + isOnScreen），
    /// 保持 CGWindowList 快照的 z-order 顺序。
    static func cgListFocusCandidates(snapshot: [CGWindowEntry], ownerPID: pid_t) -> [CGWindowEntry] {
        snapshot.filter { $0.ownerPID == ownerPID && $0.layer == 0 && $0.isOnScreen }
    }

    /// 分支 1 快速路径判定：候选**恰好 1 个**且带 bounds → 该窗口即焦点（单窗口 app 的
    /// 唯一可见窗口）。0 个（窗口在别的 space/最小化）或 >1 个（z-order ≠ AX focus，
    /// P0.3 教训：iTerm2 layer==0 first 181 ≠ AX focused 170）都不算；
    /// count==1 但 bounds 缺失 → nil 落 yabai 分支（与拆分前行为一致）。
    static func singleWindowFastPath(_ candidates: [CGWindowEntry]) -> CGWindowEntry? {
        guard candidates.count == 1, let entry = candidates.first, entry.bounds != nil else { return nil }
        return entry
    }

    /// 分支 2 接受判定：yabai 报告的焦点窗口 id 存在、可精确转 UInt32、且 pid 与前台
    /// app 一致——不一致视为 yabai/系统焦点不同步（P0.3 教训），回退 AX 分支。
    /// 通过则返回 (winID, 原始报告)——壳内以非 Optional 局部绑定消费 frame/title。
    static func yabaiFocusCandidate(_ info: YabaiWindowInfo?, frontPID: pid_t) -> (winID: UInt32, info: YabaiWindowInfo)? {
        guard let info, let yabaiWinID = info.id,
              let winID = UInt32(exactly: yabaiWinID),
              info.pid == Int(frontPID) else { return nil }
        return (winID, info)
    }

    /// 分支 3 身份落位：AX 已认定焦点 winID，按 windowID 在**全量** CGWindowList 快照里
    /// 找元信息（frame/title）——不过滤 layer/onScreen：AX 认定的焦点不做二次裁剪；
    /// 查不到（罕见）由调用壳保持「仅记 windowID/AX、不设 frame/onMain」的降位行为。
    static func axIdentityEntry(cgList: [CGWindowEntry], winID: UInt32) -> CGWindowEntry? {
        cgList.first { $0.windowID == winID }
    }
}
