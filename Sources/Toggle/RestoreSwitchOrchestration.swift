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
    func refocusWindowOnSpace(_ spaceIndex: Int, excludingWindowID: UInt32?, operationID: String?) -> Bool
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
    func moveWindowToFrameViaYabai(windowID: UInt32, frame: CGRect, op: String, stage: String) -> Bool
    func displayContext(for frame: CGRect) -> (yabaiIndex: Int?, displayID: UInt32?)
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
            // 被恢复窗口尚未移动、必不在源 space 上，无需 exclude
            switched = channels.refocusWindowOnSpace(sourceSpace, excludingWindowID: nil, operationID: operationID)
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
    static func refocusPerspective(
        channels: any RestoreSpaceChanneling,
        preMoveSpace: Int,
        excludingWindowID excluded: UInt32,
        operationID: String
    ) -> PerspectiveRefocusOutcome {
        guard let postMoveSpace = channels.currentSpaceIndex(), postMoveSpace != preMoveSpace else {
            return .noDrift
        }
        var refocused = channels.focusSpace(.yabaiIndex(preMoveSpace), operationID: operationID)
        if !refocused {
            refocused = channels.refocusWindowOnSpace(preMoveSpace, excludingWindowID: excluded, operationID: operationID)
        }
        if refocused {
            channels.clearQueryCache()
            return .refocused(postSpace: postMoveSpace)
        }
        return .failed(postSpace: postMoveSpace)
    }
}
