import ApplicationServices
import Foundation

// MARK: - Restore 双层切回编排（可注入通道抽象）
//
// 2026-09-02 引入：restore 的两处双层切回（4-pre 源屏预切回、视角守卫）此前直接调
// SpaceController.shared，I/O 无法单测。此处把通道依赖 protocol 化，编排收敛为纯
// 决策函数——生产传入 SpaceController.shared（extension 一行 conform），测试注入
// 记录调用序列的假通道（Tests/Runner）分支穷尽锁定。
//
// 2026-09-02 续：接缝覆盖 restore() 主体剩余 I/O 依赖——record 存取、AX 探测、
// frame 直写、屏归属判定、审计事件——ToggleEngine.performRestore 七依赖全注入，
// 测试无需真实 yabai/AX/SQLite 即可穷尽结局裁决全部分支。

/// restore 双层切回编排的 space 通道抽象。
/// 生产实现 = SpaceController；测试注入假通道记录调用序列。
@MainActor
protocol RestoreSpaceChanneling: AnyObject {
    /// SA 直切通道可用性（运行时判据，SA 状态随环境/重启漂移，禁止硬编码假设）
    var canControlSpaces: Bool { get }
    /// 直切：yabai space --focus（依赖 SA；不依赖目标 space 上有窗口）
    func focusSpace(_ space: SpaceIdentifier, operationID: String?) -> Bool
    /// 聚焦带动：聚焦目标 space 上可管理窗口带动视角（不依赖 SA）
    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID: UInt32?, operationID: String?, prefetchedWindows: [YabaiWindowInfo]?) -> Bool
    /// 当前 focused space（yabai 全局索引）
    func currentSpaceIndex() -> Int?
    /// space 切换后清查询缓存（窗口位置可能已变）
    func clearQueryCache()
    /// 窗口信息查询（最小化快检 + float 决策共用一次 fork）
    func queryWindow(windowID: UInt32, ignoreCache: Bool) -> YabaiWindowInfo?
    /// 指定 display 当前可见 space（4-pre 预切回决策 + 切回「等到位」轮询目标态）
    func visibleSpaceIndex(forDisplayIndex: Int?, spaces: [YabaiSpaceInfo]?, ignoreCache: Bool) -> SpaceIdentifier?
    /// float 脱管（--toggle float）；返回结局供调用方决定是否等重摆
    func setWindowFloat(_ windowID: UInt32, operationID: String?, knownWindowInfo: YabaiWindowInfo?) -> SpaceController.FloatToggleOutcome
    /// 按 space 过滤的窗口查询（守卫降级候选来源，轻查询计划）
    func queryWindowsOnSpace(_ spaceIndex: Int, operationID: String?) -> [YabaiWindowInfo]?
}

extension SpaceController: RestoreSpaceChanneling {}

/// restore 主体的 toggle record 存取抽象（load/clear）。
/// 生产实现 = ToggleEngine（自身即 ToggleRecordStore）；测试注入内存假存储。
@MainActor
protocol RestoreRecordStoring: AnyObject {
    func load(windowID: UInt32) -> ToggleRecord?
    func clear(windowID: UInt32)
}

extension ToggleEngine: RestoreRecordStoring {}

/// restore 主体的窗口操作抽象（AX 存在性探测、frame 直写、屏归属判定）。
/// 生产实现 = WindowManager；测试注入假实现分支穷尽结局裁决。
@MainActor
protocol RestoreWindowOperating: AnyObject {
    func findWindowByPID(_ pid: pid_t, windowID: UInt32?) -> AXUIElement?
    func moveWindowToFrameViaYabai(windowID: UInt32, frame: CGRect, op: String, stage: String, sourceVisibleFrame: CGRect?) -> Bool
    func displayContext(for frame: CGRect) -> (yabaiIndex: Int?, displayID: UInt32?)
    /// frame 收敛容差（FloatSettle 重摆等待的稳定判据与移动收敛共用同一容差）
    var frameTolerance: CGFloat { get }
}

extension WindowManager: RestoreWindowOperating {}

/// restore 主体的审计事件抽象（结局事件的唯一出口）。
/// 生产实现 = AuditLogger；测试注入收集器断言结局字段与 record 处置一一对应。
@MainActor
protocol RestoreAuditing: AnyObject {
    func record(eventType: String, windowID: UInt32, pid: Int32?, sessionID: String?, details: [String: String])
}

extension AuditLogger: RestoreAuditing {}

/// restore 双层切回编排（纯决策，通道可注入；Tests/Runner 分支穷尽锁定）。
@MainActor
enum RestoreSwitchOrchestration {

    /// 源屏预切回（4-pre 核心）双层通道，按可靠性排序：
    ///   1) `canControlSpaces` 为真先 SA 直切 focusSpace（不依赖源 space 上有窗口，
    ///      源 space 已空时唯一能精确切回的通道）；
    ///   2) 直切失败/不可用降级聚焦带动 refocusWindowOnSpace（不依赖 SA）。
    /// - Returns: 是否切回成功（两层全失败 = false，调用方据此置 spaceExact）。
    static func switchSourceSpace(
        channels: any RestoreSpaceChanneling,
        sourceSpace: Int,
        operationID: String
    ) -> Bool {
        var switched = false
        if channels.canControlSpaces {
            switched = channels.focusSpace(.yabaiIndex(sourceSpace), operationID: operationID)
        }
        if !switched {
            // 被恢复窗口尚未移动、必不在源 space 上，无需 exclude；4-pre 无预取
            // （preMoveSpace 快照查询发生在 move 后才有意义）
            switched = channels.refocusWindowOnSpace(sourceSpace, excludingWindowID: nil, operationID: operationID, prefetchedWindows: nil)
        }
        return switched
    }

    /// 视角守卫切回结局。
    enum PerspectiveRefocusOutcome: Equatable {
        /// focused space 未被拖走（含查询失败）——无需切回。
        case noDrift
        /// 被拖走且已切回 preMoveSpace。postSpace = 拖走后短暂停留的 space。
        case refocused(postSpace: Int)
        /// 被拖走但两层通道全失败（视角留在别处，用户可感知退化）。
        case failed(postSpace: Int)
    }

    /// 视角守卫（成功与失败路径共用）双层通道：focused space 被 frame 直写/预切回
    /// 拖走时切回 preMoveSpace。切回顺序与 switchSourceSpace 相同（SA 直切优先，
    /// 失败降级聚焦带动；此处 exclude 被恢复窗口自身——它已在 preMoveSpace 上，
    /// 聚焦它会抵消守卫）。切回成功清查询缓存。
    /// SA 不可用（canControlSpaces=false，与 switchSourceSpace 对称的运行时预判）
    /// 时跳过直切直接降级——直切必失败，白付 focusSpace fork + availability 刷新 +
    /// SA 恢复判断链（实测 ~50ms）；SA 若已恢复，focusSpace 内部 availability 刷新
    /// 会自动翻正，预判最多让单次守卫少试一条必败通道，无正确性损失。
    ///
    /// ## 降级轻查询计划（2026-09-04，替代合并查询版）
    /// 埋点实测：yabai fork 次数不是瓶颈，`query --windows` **全量 JSON 枚举**
    /// （50+ 窗口 ~100-250ms 波动）才是守卫降级链最大单项。合并查询版（2 fork）
    /// 与旧三 fork 版实测持平即为此证。现改轻查询计划，fork 数不变（3）但每次
    /// 都是轻量：currentSpaceIndex（`--spaces --space` 单条）判漂移 →
    /// `query --windows --space N`（个位数窗口，实测 31ms vs 全量 98ms）选候选
    /// → focus。信息等价，数据量降一个量级，方差随 JSON 规模收窄。
    static func refocusPerspective(
        channels: any RestoreSpaceChanneling,
        preMoveSpace: Int,
        excludingWindowID excluded: UInt32,
        operationID: String,
        prefetchedWindows: [YabaiWindowInfo]? = nil
    ) -> PerspectiveRefocusOutcome {
        guard let postMoveSpace = channels.currentSpaceIndex(), postMoveSpace != preMoveSpace else {
            return .noDrift
        }
        var refocused = false
        if channels.canControlSpaces {
            refocused = channels.focusSpace(.yabaiIndex(preMoveSpace), operationID: operationID)
        }
        if !refocused {
            refocused = channels.refocusWindowOnSpace(preMoveSpace, excludingWindowID: excluded, operationID: operationID, prefetchedWindows: prefetchedWindows)
        }
        if refocused {
            channels.clearQueryCache()
            return .refocused(postSpace: postMoveSpace)
        }
        return .failed(postSpace: postMoveSpace)
    }

    /// 胶囊目标状态（B173）：反馈文案按真实状态分流，杜绝查询失败时的编造。
    enum CapsuleTargetState: Equatable {
        /// 目标 space 在其所属屏可见（无需切换）
        case visible
        /// 目标 space 存在但不可见（需切换）
        case hidden
        /// 目标索引已不存在——工作区布局漂移（增删 space 后序号重排），快照过期
        case missing
        /// spaces 查询失败——无法确认目标状态（yabai 不可用/超时）
        case unknown
    }

    /// 胶囊 live 切换编排（B164 编排 / B173 状态分流）：先按「目标 space 在其所属屏
    /// 是否已可见」判成功；缺失/未知状态如实上报，不盲试不编造。
    ///
    /// ## 为什么不直接用 refocusPerspective 的全局焦点判漂移
    /// `currentSpaceIndex()` = 键盘焦点所在屏的 space——键盘焦点在屏 A、屏 B 已显示
    /// 目标 space 时，点击屏 B 的胶囊会被误判成「需要切换」，进而在空工作区上走双通道
    /// 全失败给出误导性拒绝（2026-09-12 用户实测：屏2 已显示 2-1，点 2-1 报
    /// 「该工作区没有可聚焦的窗口」）。目标 space 已在其所属屏可见 = 视角已在位，
    /// 无需任何切换动作，直接 noDrift 成功。
    ///
    /// ## B173 状态分流
    /// - `missing`（目标索引不在 spaces 列表）：工作区序号会随增删 space 重排
    ///   （2026-09-12 实测 [2..6]→[2..7]→[2..6]），过期快照的胶囊点了也不能盲试——
    ///   如实 .failed + missing，反馈引导刷新屏幕布局；
    /// - `unknown`（spaces 查询失败）：仍尝试视角链（查询失败≠切换必失败），但
    ///   状态上报 unknown——视角链自身的 currentSpaceIndex 查询同样失败时返回
    ///   .noDrift（旧语义=查询失败按无需切换），反馈层据此给「无法确认状态」而非
    ///   「已是当前工作区」（查询失败时「已是」是编造）。
    static func switchCapsuleToSpace(
        channels: any RestoreSpaceChanneling,
        targetSpace: Int,
        spaces: [YabaiSpaceInfo]?,
        operationID: String
    ) -> (outcome: PerspectiveRefocusOutcome, state: CapsuleTargetState) {
        guard let spaces else {
            return (refocusPerspective(
                channels: channels,
                preMoveSpace: targetSpace,
                excludingWindowID: 0,
                operationID: operationID
            ), .unknown)
        }
        guard let target = spaces.first(where: { $0.index == targetSpace }) else {
            return (.failed(postSpace: 0), .missing)
        }
        if target.isVisible == true {
            return (.noDrift, .visible)
        }
        return (refocusPerspective(
            channels: channels,
            preMoveSpace: targetSpace,
            excludingWindowID: 0,
            operationID: operationID
        ), .hidden)
    }
}

