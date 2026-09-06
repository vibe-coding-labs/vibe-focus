import AppKit
import Foundation

// MARK: - Toggle 焦点窗口解析层
// toggle 的第一步：识别「当前要操作哪个窗口」。三分支 fallback（CGWindowList → yabai → AX）
// 的存在原因与各分支代价见 resolveFocusedWindowForToggle 的场景注释——这是 toggle 热路径
// 历史上最大的耗时来源（副屏 AX 调用被 WindowServer 阻塞 1.5s+），也是多次性能回归的发生地。
// 分支选择策略已拆到 ToggleFocusBranching 纯内核（P6 步骤 1）——本文件只保留 lazy 探测
// 顺序（按阻塞代价递增）与计时/日志副作用。

@MainActor
extension WindowManager {

    /// 三分支解析的结果打包：要操作的窗口身份与命中分支信息。
    ///
    /// ## 场景
    /// - `resolveFocusedWindowForToggle` 的返回值；windowID 供 restore 决策与冷却期使用，
    ///   identity/AX 供 `moveToMainScreen(knownIdentity:knownWindowAX:)` 复用（省重复 AX），
    ///   windowFrame/onMainScreen 是 toggle 路由与 knownOrigFrame 的**类型化数据源**
    ///   （2026-09-01 前 toggle 从 toggleContext 日志字典读字符串再正则解析回来——日志
    ///   格式成了函数契约，已废除；日志字典只承担日志职责）。
    struct ToggleWindowResolution {
        let windowID: UInt32?
        /// 仅 AX 分支携带（CGWindowList/yabai 分支延迟 AX：move_to_main 先走 yabai space move）
        let windowAX: AXUIElement?
        let identity: WindowIdentity?
        /// 焦点窗口 frame（Quartz 坐标）；仅在解析成功且读到 bounds 时非 nil
        let windowFrame: CGRect?
        /// 焦点窗口是否在主屏（CoordinateKit.isOnMainScreen 语义）；主屏不可用时为 nil
        let onMainScreen: Bool?
        /// 命中分支："cgwindowlist" / "yabai" / "ax"（探测失败保持默认 "ax"）
        let source: String
        /// 命中分支净耗时（ms），用于日志归因三分支谁是 ctx 瓶颈
        let branchMs: Int
    }

    /// 解析 toggle 的目标窗口：CGWindowList → yabai → AX 三级 fallback。
    ///
    /// ## 场景
    /// - 仅 `toggle(operationID:triggerSource:)` 入口调用（每 toggle 一次，主线程同步）；
    /// - 探测字段（probe/branch 耗时、候选数、窗口元信息）全部写入 `toggleContext`，
    ///   由调用方统一落日志。
    ///
    /// ## 三分支选择逻辑与代价（为什么这么绕）
    /// 1. **CGWindowList（~5ms，非阻塞）**：仅当 frontmostApp 的可见窗口（layer==0 &&
    ///    isOnScreen）**恰好 1 个**时可信——单窗口 app 的唯一可见窗口即焦点。
    /// 2. **yabai queryFocusedWindow（副屏 ~648ms）**：多窗口 app 必须走它，因为
    ///    CGWindowList 的 z-order ≠ AX focus（P0.3 教训：iTerm2 layer==0 first 181 ≠
    ///    AX focused 170）。pid 与 frontmostApp 不一致时视为 yabai/系统焦点不同步，回退 AX。
    /// 3. **AX（副屏 ~1.5s，最慢）**：yabai 不可用/query 失败/pid 不一致的兜底；
    ///    frame/title 仍走 CGWindowList（热路径禁 AX frame(of:) 的铁律）。
    ///
    /// ## 竞态/回归风险（必读）
    /// - **焦点身份不可缓存**：曾试 P3.4 缓存 lastFocusedWindowID 把 ctx 502→25ms，但用户
    ///   切到同 app 另一窗口后缓存仍命中 → 永远操作旧窗口（"只能切换固定窗口"回归），已回退。
    ///   焦点必须每次实时查询。
    /// - 副屏窗口的 AX 调用被 WindowServer 阻塞 1.5s+（toggle-00000320），因此分支顺序
    ///   按阻塞代价递增排列，禁止把 AX 分支提前。
    ///
    /// - Parameters:
    ///   - frontApp: `NSWorkspace.shared.frontmostApplication`（可为 nil：无前台 app 时
    ///     跳过三分支，仅填默认收尾字段——与拆分前行为一致）。
    ///   - cachedMainScreen: toggle 入口缓存的主屏（同步执行期间屏幕配置不变）。
    ///   - toggleContext: toggle 日志字典（inout 填充探测字段）。
    /// - Returns: 解析结果；三分支全部失败时 windowID/identity 为 nil（调用方按
    ///   "onMainScreen==true → stuck / 否则 identity missing" 路径处理）。
    func resolveFocusedWindowForToggle(
        frontApp: NSRunningApplication?,
        cachedMainScreen: NSScreen?,
        toggleContext: inout [String: String]
    ) -> ToggleWindowResolution {
        let axStart = Date()
        var focusedWindowSource = "ax"
        // P-INST-1: 命中分支净探测耗时（cglist/yabai/ax 三选一），用于定位 ctx 635ms 来自哪个分支。
        var focusedBranchMs: Int = 0
        var resolvedWindowID: UInt32?
        var resolvedWindowAX: AXUIElement?
        var resolvedIdentity: WindowIdentity?
        var resolvedFrame: CGRect?
        var resolvedOnMain: Bool?

        // 命中分支归一化收尾：typed 字段 + 日志字典同步填充。
        // 主屏归属判定走 CoordinateKit.isOnMainScreen(_:mainScreenFrame:)（全仓唯一实现），
        // 主屏来源仍是调用方缓存的 cachedMainScreen（toggle 同步执行期间屏幕配置不变）。
        func adopt(frame: CGRect?, windowID: UInt32, ax: AXUIElement?, identity: WindowIdentity, source: String, branchMs: Int, titleForLog: String) {
            focusedWindowSource = source
            focusedBranchMs = branchMs
            resolvedWindowID = windowID
            resolvedWindowAX = ax
            resolvedIdentity = identity
            if let frame {
                resolvedFrame = frame
                resolvedOnMain = cachedMainScreen.map { CoordinateKit.isOnMainScreen(frame, mainScreenFrame: $0.frame) }
            }
            toggleContext["windowID"] = String(windowID)
            if let frame { toggleContext["windowFrame"] = String(describing: frame) }
            if let onMain = resolvedOnMain { toggleContext["onMainScreen"] = String(onMain) }
            toggleContext["windowTitle"] = truncateForLog(titleForLog, limit: 60)
        }

        if let frontApp {
            let frontPID = frontApp.processIdentifier
            // P3.3: 优先 CGWindowList（非阻塞 ~5ms）拿焦点窗口 windowID/frame/title。
            // 可靠性：candidates（ownerPID==frontPID, layer==0, isOnScreen）恰好 1 个 = 单窗口
            // app 唯一可见窗口 = 焦点；多窗口（>1）无法从 z-order 定 AX focus，fallback yabai。
            // P-INST-1: cgwindowlist 快照探测计时 + 候选数。量化 P3.3 命中率
            // （count==1 = 单窗口命中快速路径；count>1 = 多窗口必须 fallback yabai；count==0 = 异常）。
            let cgListProbeStart = Date()
            let cgSnapshot = cgWindowListAll()
            let candidates = ToggleFocusBranching.cgListFocusCandidates(snapshot: cgSnapshot, ownerPID: frontPID)
            let cgListProbeMs = elapsedMilliseconds(since: cgListProbeStart)
            toggleContext["cgListProbeMs"] = String(cgListProbeMs)
            toggleContext["candidatesCount"] = String(candidates.count)
            if let entry = ToggleFocusBranching.singleWindowFastPath(candidates) {
                resolvedIdentity = WindowIdentity(
                    windowID: entry.windowID,
                    pid: frontPID,
                    bundleIdentifier: frontApp.bundleIdentifier,
                    appName: frontApp.localizedName,
                    windowNumber: Int(entry.windowID),
                    title: entry.name
                )
                if let identity = resolvedIdentity {
                    adopt(frame: entry.bounds, windowID: entry.windowID, ax: nil, identity: identity, source: "cgwindowlist", branchMs: cgListProbeMs, titleForLog: entry.name ?? "")
                }
            } else {
                // P-INST-1: yabai 分支探测计时（queryFocusedWindow fork，副屏 ~635ms 是 ctx 主因）。
                let yabaiProbeStart = Date()
                let focusedInfo = spaceController.queryFocusedWindow()
                let yabaiProbeMs = elapsedMilliseconds(since: yabaiProbeStart)
                toggleContext["yabaiProbeMs"] = String(yabaiProbeMs)
                if let yabaiHit = ToggleFocusBranching.yabaiFocusCandidate(focusedInfo, frontPID: frontPID) {
                    // yabai fallback（多窗口 / CGWindowList 候选≠1）：副屏慢 648ms，但可靠拿系统焦点窗口。
                    let winID = yabaiHit.winID
                    let bounds = yabaiHit.info.frame?.cgRect ?? .zero
                    resolvedIdentity = WindowIdentity(
                        windowID: winID,
                        pid: frontPID,
                        bundleIdentifier: frontApp.bundleIdentifier,
                        appName: frontApp.localizedName,
                        windowNumber: Int(winID),
                        title: yabaiHit.info.title ?? yabaiHit.info.app
                    )
                    if let identity = resolvedIdentity {
                        adopt(frame: bounds, windowID: winID, ax: nil, identity: identity, source: "yabai", branchMs: yabaiProbeMs, titleForLog: yabaiHit.info.title ?? yabaiHit.info.app ?? "")
                    }
                } else {
                    // P-INST-1: AX 分支探测计时（focusedWindow + windowHandle，副屏阻塞 ~1.5s）。
                    let axProbeStart = Date()
                    let focusedWin = focusedWindow(for: frontPID)
                    let winID = focusedWin.flatMap { windowHandle(for: $0) }
                    let axProbeMs = elapsedMilliseconds(since: axProbeStart)
                    toggleContext["axProbeMs"] = String(axProbeMs)
                    if let focusedWin = focusedWin, let winID = winID {
                        // AX fallback：yabai 不可用 / query 失败 / pid 不一致时保持原逻辑（副屏阻塞 1.5s）。
                        // 热路径读 frame 禁 AX frame(of:)，故 frame/title 仍走 CGWindowList（按已知 windowID 查，非 AX）。
                        toggleContext["windowID"] = String(winID)
                        let cgList = cgWindowListAll()
                        if let entry = ToggleFocusBranching.axIdentityEntry(cgList: cgList, winID: winID) {
                            resolvedIdentity = WindowIdentity(
                                windowID: winID,
                                pid: frontApp.processIdentifier,
                                bundleIdentifier: frontApp.bundleIdentifier,
                                appName: frontApp.localizedName,
                                windowNumber: Int(winID),
                                title: entry.name
                            )
                            if let identity = resolvedIdentity {
                                adopt(frame: entry.bounds, windowID: winID, ax: focusedWin, identity: identity, source: "ax", branchMs: axProbeMs, titleForLog: entry.name ?? "")
                            }
                        } else {
                            // CGWindowList 无此窗口（罕见）：仅记 windowID/AX，frame/onMain 不设
                            focusedWindowSource = "ax"
                            focusedBranchMs = axProbeMs
                            resolvedWindowID = winID
                            resolvedWindowAX = focusedWin
                        }
                    }
                }
            }
        }
        let focusedWindowAxMs = elapsedMilliseconds(since: axStart)
        toggleContext["focusedWindowSource"] = focusedWindowSource
        toggleContext["focusedWindowAxMs"] = String(focusedWindowAxMs)
        // P-INST-1: 命中分支净耗时（仅命中分支有值）。与 focusedWindowAxMs（三分支总耗时）对照，
        // 可精确定位 ctx 主导耗时来自 cglist（~5ms）/yabai（~635ms）/ax（~1.5s）哪个分支。
        toggleContext["focusedBranchMs"] = String(focusedBranchMs)
        toggleContext["winIDAxMs"] = "0"  // windowHandle 合并进 axStart 计时（紧随 focusedWindow）
        toggleContext["titleAxMs"] = "0"   // title 改 CGWindowList

        return ToggleWindowResolution(
            windowID: resolvedWindowID,
            windowAX: resolvedWindowAX,
            identity: resolvedIdentity,
            windowFrame: resolvedFrame,
            onMainScreen: resolvedOnMain,
            source: focusedWindowSource,
            branchMs: focusedBranchMs
        )
    }
}
