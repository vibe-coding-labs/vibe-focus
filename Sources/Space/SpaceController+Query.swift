import AppKit
import Foundation

@MainActor
extension SpaceController {

    func queryFocusedSpace() -> YabaiSpaceInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            log(
                "[SpaceController] queryFocusedSpace: yabai query failed",
                level: .debug
            )
            return nil
        }
        let space = decodeSingleOrFirst(YabaiSpaceInfo.self, from: result.stdout)
        log(
            "[SpaceController] queryFocusedSpace result",
            level: .debug,
            fields: [
                "spaceIndex": String(describing: space?.index),
                "spaceID": String(describing: space?.id),
                "display": String(describing: space?.display)
            ]
        )
        return space
    }

    func querySpaces(caller: String = #function) -> [YabaiSpaceInfo]? {
        let startedAt = Date()
        guard let result = runYabai(arguments: ["-m", "query", "--spaces"]),
              result.exitCode == 0 else {
            log(
                "[SpaceController] querySpaces failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
            return nil
        }
        let spaces = decodeArray(YabaiSpaceInfo.self, from: result.stdout)
        if spaces == nil, !result.stdout.isEmpty {
            log(
                "[SpaceController] querySpaces decode failed",
                level: .warn,
                fields: [
                    "caller": caller,
                    "stdoutLen": String(result.stdout.count),
                    "durationMs": String(elapsedMilliseconds(since: startedAt))
                ]
            )
        }
        return spaces
    }

    func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        log(
            "[queryWindow] called",
            level: .debug,
            fields: ["windowID": String(windowID)]
        )
        // 先尝试精确查询
        if let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
           result.exitCode == 0 {
            let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
            if info != nil {
                log(
                    "[queryWindow] direct query succeeded",
                    level: .debug,
                    fields: [
                        "windowID": String(windowID),
                        "space": String(describing: info?.space),
                        "display": String(describing: info?.display)
                    ]
                )
                return info
            }
        }

        // 精确查询失败 — 用全量窗口列表 fallback
        log(
            "[queryWindow] direct query failed, trying all-windows fallback",
            level: .warn,
            fields: ["windowID": String(windowID)]
        )
        guard let allResult = runYabai(arguments: ["-m", "query", "--windows"]),
              allResult.exitCode == 0 else {
            log("[queryWindow] all-windows fallback also failed", level: .warn, fields: ["windowID": String(windowID)])
            return nil
        }
        let allWindows = decodeArray(YabaiWindowInfo.self, from: allResult.stdout) ?? []
        let match = allWindows.first { $0.id == Int(windowID) }
        log(
            "[queryWindow] fallback result",
            level: .warn,
            fields: [
                "windowID": String(windowID),
                "found": String(match != nil),
                "space": String(describing: match?.space),
                "display": String(describing: match?.display),
                "totalWindows": String(allWindows.count)
            ]
        )
        return match
    }

    func visibleSpaceIndex(forDisplayIndex displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> Int? {
        guard let displayIndex else {
            log(
                "[SpaceController] visibleSpaceIndex: nil displayIndex",
                level: .debug
            )
            return nil
        }
        let resolvedSpaces = spaces ?? querySpaces()
        let visible = resolvedSpaces?.first(where: { $0.display == displayIndex && $0.isVisible == true })?.index
        log(
            "[SpaceController] visibleSpaceIndex result",
            level: .debug,
            fields: [
                "displayIndex": String(displayIndex),
                "visibleSpaceIndex": String(describing: visible)
            ]
        )
        return visible
    }

    func windowSpaceIndex(windowID: UInt32) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            log(
                "[SpaceController] windowSpaceIndex: unavailable",
                level: .debug,
                fields: ["windowID": String(windowID), "isEnabled": String(isEnabled)]
            )
            return nil
        }
        log(
            "[SpaceController] windowSpaceIndex result",
            level: .debug,
            fields: ["windowID": String(windowID), "space": String(describing: window.space)]
        )
        return window.space
    }

    func windowDisplayIndex(windowID: UInt32) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            log(
                "[SpaceController] windowDisplayIndex: unavailable",
                level: .debug,
                fields: ["windowID": String(windowID), "isEnabled": String(isEnabled)]
            )
            return nil
        }
        log(
            "[SpaceController] windowDisplayIndex result",
            level: .debug,
            fields: ["windowID": String(windowID), "display": String(describing: window.display)]
        )
        return window.display
    }

    func currentSpaceIndex() -> Int? {
        log(
            "[currentSpaceIndex] called",
            level: .debug,
            fields: ["isEnabled": String(isEnabled)]
        )
        refreshAvailabilityIfNeeded()
        guard isEnabled, let space = queryFocusedSpace() else {
            log(
                "[SpaceController] currentSpaceIndex: unavailable",
                level: .debug,
                fields: ["isEnabled": String(isEnabled)]
            )
            return nil
        }
        log(
            "[SpaceController] currentSpaceIndex result",
            level: .debug,
            fields: ["spaceIndex": String(describing: space.index)]
        )
        return space.index
    }
}
