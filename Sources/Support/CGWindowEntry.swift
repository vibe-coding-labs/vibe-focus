import CoreGraphics
import Foundation

/// Represents a single entry from the CGWindowListCopyWindowInfo API.
struct CGWindowEntry {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect?
    let name: String?
    let isOnScreen: Bool

    init?(from dict: [String: Any]) {
        guard let windowID = dict[kCGWindowNumber as String] as? UInt32,
              let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t else {
            return nil
        }
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = dict[kCGWindowOwnerName as String] as? String
        self.layer = dict[kCGWindowLayer as String] as? Int ?? 0
        self.name = dict["kCGWindowName"] as? String ?? dict["name"] as? String
        self.isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? true

        if let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] {
            self.bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
        } else {
            self.bounds = nil
        }
    }
}

func cgWindowListAll() -> [CGWindowEntry] {
    // P-INST-45: CGWindowList 全量读耗时（非阻塞 ~5ms 正常；slow-op ≥30ms warn 抓阻塞或循环滥用 O(N²)，memory feedback_window_lookup_perf）。
    #if PERF_INSTRUMENT
    let cgListStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: cgListStart)
        if durMs >= 30 {
            log("[CGWindowList] cgWindowListAll slow", level: .warn, fields: ["durationMs": String(durMs)])
        }
    }
    #endif
    guard let rawList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return rawList.compactMap { CGWindowEntry(from: $0) }
}

/// 单窗口 CGWindowList 查询（非阻塞 ~2ms），返回指定 windowID 的 frame（global quartz 坐标，
/// 与 AX kAXFrameAttribute 同坐标系，可直接比较）。比 cgWindowListAll() 全量扫更轻量
/// （只查一个窗口），用于 apply readback / postMoveCheck 等热路径。
/// memory feedback_toggle_ctxms_cgwindowlist：热路径读 frame 禁 AX frame(of:)（副屏阻塞 1.9s），
/// 必须用 CGWindowList。CGWindowListCopyWindowInfo 即使窗口在副屏独立 Space 也非阻塞
/// （WindowServer 快照，diag 实测 cgWindowListAll() 含副屏 windowID frame ~5ms）。
///
/// B228 修复：`kCGWindowListOptionIncludingWindow` 单独使用是 SDK 文档外的未定义行为
/// （CGWindow.h 要求它与 OnScreenAboveWindow/BelowWindow 配对；2026-09-19 本机实测
/// 单独使用恒返回空列表）→ 本函数此前恒 nil：移动收敛读通道每轮判「全偏差」（收敛
/// 只能靠轮询预算耗尽=移动慢），气泡唤起锚点 guard 失败直接 beep 退出。修=配对查询
/// （返回「目标窗+其下方在屏窗」）后按 windowID 精确过滤；目标不在屏（他屏/隐藏
/// Space/最小化）时走全量快照兜底（离屏窗 frame 也在列）。
func cgWindowBounds(for windowID: UInt32) -> CGRect? {
    // P-INST-45: CGWindowList 单窗口读耗时（非阻塞 ~2ms 正常；slow-op ≥30ms warn，apply readback/postMoveCheck 热路径）。
    #if PERF_INSTRUMENT
    let cgBoundsStart = Date()
    defer {
        let durMs = elapsedMilliseconds(since: cgBoundsStart)
        if durMs >= 30 {
            log("[CGWindowList] cgWindowBounds slow", level: .warn, fields: ["windowID": String(windowID), "durationMs": String(durMs)])
        }
    }
    #endif
    if let rawList = CGWindowListCopyWindowInfo([.optionIncludingWindow, .optionOnScreenBelowWindow], windowID) as? [[String: Any]] {
        for dict in rawList {
            if let entry = CGWindowEntry(from: dict), entry.windowID == windowID {
                return entry.bounds
            }
        }
    }
    // 目标不在「在屏」集合（他屏/隐藏 Space/最小化）：全量快照兜底（按 ID 精确匹配）
    return cgWindowListAll().first { $0.windowID == windowID }?.bounds
}
