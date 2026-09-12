import AppKit
import Foundation

@MainActor
extension SpaceController {

    func focusSpace(_ space: SpaceIdentifier, operationID: String? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let spaceIndex = space.yabaiIndex else {
            log("[SpaceController] focusSpace: unsupported space identifier", level: .warn, fields: ["op": op])
            return false
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return false
        }
        guard canControlSpaces else {
            markOperationError("Cannot focus another space because cross-space control is unavailable", operationID: op)
            return false
        }

        let variants = [["-m", "space", "--focus", "\(spaceIndex)"]]
        let result = runYabaiVariants(variants: variants, operation: "focusSpace(\(spaceIndex))", operationID: op)
        if result.success {
            return true
        }

        markOperationError(from: result.failure, fallback: "Failed to focus space \(spaceIndex)", operationID: op)
        return false
    }

    /// 聚焦指定 space 上的任意可管理窗口，把键盘焦点/用户视角带回该 space 所在 display。
    ///
    /// ## 场景（2026-09-01 视角守卫重构）
    /// - restore 把窗口 frame 直写回源屏后，macOS 会把键盘焦点/视角跟随到目标 display
    ///   （实测 preSpace=1 → postSpace=5），用户被拖离原屏。
    /// - 原 CGEvent 方向键法（ctrl+←×N）在 separate-Spaces 下**无法跨 display**（方向键只在
    ///   焦点 display 的 space 序列内切换），切回必失败。
    /// - yabai `space --focus` 依赖 scripting-addition（SA 失效时报
    ///   "error with the scripting-addition"），也不可用。
    /// - 可靠路径：窗口级 focus（AX/CG 通道，不依赖 SA），实测聚焦目标 space 任一窗口即把
    ///   焦点与视角一并带回。
    /// - Returns: 是否成功聚焦了目标 space 上的窗口。
    /// 按 space 过滤的窗口查询（守卫降级候选来源）。
    /// 场景（2026-09-04 守卫轻查询计划）：全量 `query --windows` 在 50+ 窗口下
    /// JSON 枚举 ~100-250ms 且波动大，是守卫降级链最大单项；按目标 space 过滤后
    /// 列表只剩个位数窗口（实测 31ms vs 98ms），信息对候选选择完全等价。
    /// B167：负载下 yabai fork 偶发 1-2s 边缘超时（2026-09-12 胶囊切换实测
    /// durationMs=1020 贴线）——失败/超时重试一次再放弃，削掉偶发误失败。
    func queryWindowsOnSpace(_ spaceIndex: Int, operationID: String?) -> [YabaiWindowInfo]? {
        func queryOnce() -> [YabaiWindowInfo]? {
            guard let result = runYabai(arguments: ["-m", "query", "--windows", "--space", "\(spaceIndex)"], operation: "queryWindowsOnSpace(\(spaceIndex))", operationID: operationID ?? "none"),
                  result.exitCode == 0 else {
                return nil
            }
            return decodeArray(YabaiWindowInfo.self, from: result.stdout)
        }
        if let first = queryOnce() {
            return first
        }
        log("[SpaceController] queryWindowsOnSpace: first query failed/timeout, retrying once", level: .debug, fields: [
            "op": operationID ?? "none", "spaceIndex": String(spaceIndex)
        ])
        return queryOnce()
    }

    /// - Parameter prefetchedWindows: 调用方提前查好的目标 space 窗口列表（守卫候选
    ///   预取：restore 在 move 前发起查询，move 完成时候选已就绪，省一次串行 fork）；
    ///   nil 时现查（其他调用路径）。
    ///
    /// B167 落位验证：`window --focus` 对不可聚焦窗口（死壳 Terminal 残窗等）会
    /// **exit 0 但焦点/视角纹丝不动**（2026-09-12 实测：exit 0、全局焦点与可见
    /// space 均无变化）——旧实现只看 exitCode，把 no-op 当成功上报「已切换」，
    /// 用户视角里就是「切换失效」。现按偏好序逐候选聚焦，每个候选以「全局焦点
    /// 窗口 id == 候选」轮询验证真落位；全候选落位失败如实返回 false。
    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID excluded: UInt32? = nil, operationID: String? = nil, prefetchedWindows: [YabaiWindowInfo]? = nil) -> Bool {
        let op = operationID ?? "none"
        guard let windows = prefetchedWindows ?? queryWindowsOnSpace(spaceIndex, operationID: op) else {
            log("[SpaceController] refocusWindowOnSpace: window query failed", level: .warn, fields: [
                "op": op, "spaceIndex": String(spaceIndex)
            ])
            return false
        }

        let candidates = Self.selectRefocusCandidates(windows: windows, spaceIndex: spaceIndex, excludingWindowID: excluded)
        guard !candidates.isEmpty else {
            log("[SpaceController] refocusWindowOnSpace: no focusable window on target space", level: .debug, fields: [
                "op": op, "spaceIndex": String(spaceIndex)
            ])
            return false
        }

        for candidate in candidates {
            guard let candidateID = candidate.id.map({ UInt32($0) }) else { continue }
            let focusResult = runYabai(
                arguments: ["-m", "window", "\(candidateID)", "--focus"],
                operation: "refocusWindowOnSpace.focus(windowID=\(candidateID))",
                operationID: op
            )
            guard focusResult?.exitCode == 0 else {
                log("[SpaceController] refocusWindowOnSpace: focus command failed, trying next candidate", level: .debug, fields: [
                    "op": op, "spaceIndex": String(spaceIndex), "windowID": String(candidateID)
                ])
                continue
            }
            // B167：exit 0 ≠ 切换成功，必须轮询验证视角真落到目标 space。
            // 判据 = 目标屏可见 space（切换的真正目标）；候选 display 缺失时退回
            // 焦点窗口 id 比对。不用「焦点 id == 候选」做主判据：同 app 多窗时
            // app 会把焦点收敛到自己的活跃窗（≠聚焦候选），视角已切也误判失败。
            if switchDidLand(targetSpace: spaceIndex, displayIndex: candidate.display, expectedWindow: candidateID, operationID: op) {
                log("[SpaceController] refocusWindowOnSpace result", level: .debug, fields: [
                    "op": op, "spaceIndex": String(spaceIndex),
                    "focusedWindowID": String(candidateID),
                    "candidateMinimized": String(candidate.isMinimized),
                    "success": "true"
                ])
                return true
            }
            log("[SpaceController] refocusWindowOnSpace: focus did not land (unfocusable window no-op), trying next candidate", level: .debug, fields: [
                "op": op, "spaceIndex": String(spaceIndex), "windowID": String(candidateID)
            ])
        }
        log("[SpaceController] refocusWindowOnSpace: all candidates exhausted without focus landing", level: .warn, fields: [
            "op": op, "spaceIndex": String(spaceIndex), "candidates": String(candidates.count)
        ])
        return false
    }

    /// 切换落位轮询（B167）：等聚焦/切视角动画落定后读目标屏可见 space，
    /// == 目标 space 才算成功。displayIndex 未知时退回焦点窗口 id 比对。
    private func switchDidLand(targetSpace: Int, displayIndex: Int?, expectedWindow: UInt32, operationID: String) -> Bool {
        let deadline = Date().addingTimeInterval(Double(Self.refocusVerifyBudgetMs) / 1000.0)
        while true {
            if let displayIndex {
                if visibleSpaceIndex(forDisplayIndex: displayIndex, ignoreCache: true)?.yabaiIndex == targetSpace {
                    return true
                }
            } else if focusedWindowID(operationID: operationID) == expectedWindow {
                return true
            }
            if Date() >= deadline { return false }
            usleep(Self.refocusVerifyPollIntervalMs * 1000)
        }
    }

    /// 全局焦点窗口 id（`query --windows --window`；失败 nil）。
    func focusedWindowID(operationID: String) -> UInt32? {
        guard let result = runYabai(arguments: ["-m", "query", "--windows", "--window"], operation: "focusedWindowID", operationID: operationID),
              result.exitCode == 0,
              let focused = decodeArray(YabaiWindowInfo.self, from: result.stdout)?.first,
              let id = focused.id else { return nil }
        return UInt32(id)
    }

    /// 聚焦落位验证时序（B167）。
    static let refocusVerifyPollIntervalMs: useconds_t = 120
    static let refocusVerifyBudgetMs: Int = 700

    /// refocus 候选选择（纯函数，SpaceControllerRefocusTests 锁定）。
    ///
    /// 在目标 space 的可管理窗口中偏好**非最小化**窗口：聚焦最小化窗口会把它从 Dock
    /// 拉出（凭空扰动用户布局）或在部分 app 上直接失败；仅当目标 space 全部最小化时
    /// 才退回最小化候选（视角切换仍优先于布局扰动）。B167：返回**有序全量候选**——
    /// 调用方逐个聚焦并验证落位，头一个 no-op（死窗）自动换下一个。
    static func selectRefocusCandidates(
        windows: [YabaiWindowInfo],
        spaceIndex: Int,
        excludingWindowID excluded: UInt32?
    ) -> [YabaiWindowInfo] {
        let onSpace = windows.filter { w in
            guard w.space == spaceIndex,
                  w.isManageableByYabai,
                  w.id.map({ UInt32($0) }) != excluded else { return false }
            return true
        }
        return onSpace.filter { !$0.isMinimized } + onSpace.filter { $0.isMinimized }
    }

    /// 单数版兼容入口（= 有序候选首个；既有调用方/测试语义不变）。
    static func selectRefocusCandidate(
        windows: [YabaiWindowInfo],
        spaceIndex: Int,
        excludingWindowID excluded: UInt32?
    ) -> YabaiWindowInfo? {
        selectRefocusCandidates(windows: windows, spaceIndex: spaceIndex, excludingWindowID: excluded).first
    }

    /// Minimap 胶囊点击 live 切换（2026-09-07，用户报告「点胶囊切不过去」）：
    /// 复用 restore 视角链（RestoreSwitchOrchestration.switchCapsuleToSpace）——
    /// B164：先按「目标 space 在其所属屏是否已可见」判定（此前拿全局焦点 space 判漂移，
    /// 目标屏已显示目标 space、只要键盘焦点在另一块屏就被误判成需要切换，空工作区上
    /// 给出误导性失败）；真需切换时 SA 直切 → 聚焦带动降级。
    /// .failed 时调用方必须给用户明确反馈（空工作区切不动是平台事实，不许静默）。
    @discardableResult
    func switchToSpace(_ yabaiIndex: Int, operationID: String) -> RestoreSwitchOrchestration.PerspectiveRefocusOutcome {
        let spaces = querySpaces(ignoreCache: true)
        return RestoreSwitchOrchestration.switchCapsuleToSpace(
            channels: self,
            targetSpace: yabaiIndex,
            spaces: spaces,
            operationID: operationID
        )
    }
}
