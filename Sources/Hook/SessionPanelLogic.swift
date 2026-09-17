// SessionPanelLogic.swift
// VibeFocus — live 会话面板快照纯函数（B202）
//
// 三路数据 join 成可渲染行：注册表绑定（哪个窗）× 活动追踪（哪个阶段）×
// yabai 窗口地理（哪个屏/space）。全部无 IO——IO 在调用方（设置页 2s 刷新
// Task / --diagnose 单次查询），本文件只做值变换，Runner 穷尽直测。
//
// 地理口径：yabai display 自身编号从 1 起，1 视为主屏（yabai 定义），
// 其余显示为「副屏 n」；space 直接透传 yabai 值。

import Foundation

/// 一个会话窗口的地理快照（由调用方从一次 `yabai query --windows` 聚合）。
struct SessionWindowGeo: Equatable {
    let space: Int?
    let display: Int?
}

/// 面板一行 = 一个会话的实时画像。
struct SessionLiveRow: Equatable {
    let sessionID: String
    let windowID: UInt32?
    let app: String?
    let project: String?
    let screenLabel: String?
    let space: Int?
    let status: SessionLiveStatus
    let lastActivityAt: Date?
    let isRemote: Bool
    let lastCode: String?
}

enum SessionPanelLogic {

    /// 状态派生唯一入口（纯函数，Runner 穷尽锁定）：最后一个事件说了算。
    static func deriveStatus(lastEvent: ClaudeHookEventType) -> SessionLiveStatus {
        switch lastEvent {
        case .userPromptSubmit: return .running
        case .notification, .permissionRequest: return .waiting
        case .stop: return .done
        case .sessionStart: return .bound
        case .sessionEnd: return .ended
        }
    }

    /// cwd 尾段做项目名（与播报 {project_name} 同口径，去首尾斜杠）。
    static func projectLabel(cwd: String?) -> String? {
        guard let cwd else { return nil }
        let name = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/").last ?? ""
        return name.isEmpty ? nil : name
    }

    /// yabai display → 屏标签（display 1=主屏，其余=副屏 n；未知 nil）。
    static func screenLabel(display: Int?) -> String? {
        guard let display, display > 0 else { return nil }
        return display == 1 ? "主屏" : "副屏\(display)"
    }

    /// 活动距今的紧凑文案（<60s=「刚刚」；<60m=「n 分钟前」；其余=「n 小时前」）。
    static func relativeAge(_ at: Date?, now: Date) -> String? {
        guard let at else { return nil }
        let seconds = max(0, now.timeIntervalSince(at))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        return "\(Int(seconds / 3600)) 小时前"
    }

    /// join + 派生 + 排序。无活动记录的绑定（app 刚重启、追踪器清零）退 .bound
    /// ——绑定存在即「已绑定」，诚实不编造运行态。排序：状态权重升序（等待输入
    /// 最前）→ 活动时间新→旧。
    static func buildRows(
        bindings: [WindowState],
        activities: [String: SessionActivity],
        geo: [UInt32: SessionWindowGeo],
        now: Date
    ) -> [SessionLiveRow] {
        let rows: [SessionLiveRow] = bindings.compactMap { (state: WindowState) -> SessionLiveRow? in
            guard let sessionID = state.sessionID, !sessionID.isEmpty else { return nil }
            let activity = activities[sessionID]
            let status = activity.map { SessionPanelLogic.deriveStatus(lastEvent: $0.lastEvent) } ?? .bound
            let g = geo[state.windowID]
            return SessionLiveRow(
                sessionID: sessionID,
                windowID: state.windowID,
                app: state.appName,
                project: projectLabel(cwd: state.cwd),
                screenLabel: screenLabel(display: g?.display),
                space: g?.space,
                status: status,
                lastActivityAt: activity?.at,
                isRemote: state.bindingType == .remote,
                lastCode: activity?.lastCode
            )
        }
        return rows.sorted { lhs, rhs in
            if lhs.status.sortPriority != rhs.status.sortPriority {
                return lhs.status.sortPriority < rhs.status.sortPriority
            }
            let lDate = lhs.lastActivityAt ?? .distantPast
            let rDate = rhs.lastActivityAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.sessionID < rhs.sessionID
        }
    }

    /// 从一次 `yabai query --windows` 输出聚合 [windowID: geo]。
    static func geoMap(fromWindows windows: [YabaiWindowInfo]) -> [UInt32: SessionWindowGeo] {
        var map: [UInt32: SessionWindowGeo] = [:]
        for w in windows {
            guard let id = w.id, id > 0 else { continue }
            map[UInt32(id)] = SessionWindowGeo(space: w.space, display: w.display)
        }
        return map
    }

    /// --diagnose / 面板共用渲染行（无行时给明确交代，不给空段）。
    static func reportLines(rows: [SessionLiveRow], now: Date) -> [String] {
        guard !rows.isEmpty else {
            return ["[会话面板] 暂无已绑定会话"]
        }
        var out = ["[会话面板] \(rows.count) 个会话（按 等待输入>运行中>其余 排序）"]
        for row in rows {
            var parts: [String] = []
            parts.append(row.status.label)
            parts.append("\(row.app ?? "未知应用")")
            if let project = row.project { parts.append(project) }
            if let screen = row.screenLabel {
                parts.append(screen)
                if let space = row.space { parts.append("space\(space)") }
            } else {
                parts.append("窗不可见/离屏")
            }
            parts.append("sess=\(row.sessionID.prefix(8))")
            if row.isRemote { parts.append("远程") }
            if let age = relativeAge(row.lastActivityAt, now: now) { parts.append(age) }
            out.append("  " + parts.joined(separator: " · "))
        }
        return out
    }
}
