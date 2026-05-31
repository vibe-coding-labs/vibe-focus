import AppKit
import Foundation

@MainActor
extension SpaceController {

    func queryFocusedSpace() -> YabaiSpaceInfo? {
        guard let result = runYabai(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiSpaceInfo.self, from: result.stdout)
    }

    func querySpaces(caller: String = #function) -> [YabaiSpaceInfo]? {
        // 1. 检查缓存
        if let cached = spacesQueryCache, !isCacheExpired(cached.cachedAt) {
            return cached.result
        }

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
            spacesQueryCache = (result: nil, cachedAt: Date())
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
        spacesQueryCache = (result: spaces, cachedAt: Date())
        return spaces
    }

    func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        // 1. 检查缓存
        if let cached = windowQueryCache[windowID], !isCacheExpired(cached.cachedAt) {
            return cached.result
        }

        // 2. 直接查询
        if let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
           result.exitCode == 0 {
            let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
            if info != nil {
                windowQueryCache[windowID] = (result: info, cachedAt: Date())
                return info
            }
        }

        log(
            "[queryWindow] direct query failed, trying all-windows fallback",
            level: .warn,
            fields: ["windowID": String(windowID)]
        )
        guard let allResult = runYabai(arguments: ["-m", "query", "--windows"]),
              allResult.exitCode == 0 else {
            log("[queryWindow] all-windows fallback also failed", level: .warn, fields: ["windowID": String(windowID)])
            windowQueryCache[windowID] = (result: nil, cachedAt: Date())
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
        windowQueryCache[windowID] = (result: match, cachedAt: Date())
        return match
    }

    /// Pure logic for visibleSpaceIndex — extracted for testability.
    static func resolveVisibleSpaceIndex(displayIndex: Int?, spaces: [YabaiSpaceInfo]?) -> SpaceIdentifier? {
        guard let displayIndex else { return nil }
        return spaces?.first(where: { $0.display == displayIndex && $0.isVisible == true })?.index.map { .yabai($0) }
    }

    func visibleSpaceIndex(forDisplayIndex displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> SpaceIdentifier? {
        let resolvedSpaces = spaces ?? querySpaces()
        return Self.resolveVisibleSpaceIndex(displayIndex: displayIndex, spaces: resolvedSpaces)
    }

    func windowSpaceIndex(windowID: UInt32) -> SpaceIdentifier? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.space.map { .yabai($0) }
    }

    func windowDisplayIndex(windowID: UInt32) -> DisplayIdentifier? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let window = queryWindow(windowID: windowID) else {
            return nil
        }
        return window.display.map { .yabai($0) }
    }

    func currentSpaceIndex() -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled, let space = queryFocusedSpace() else {
            return nil
        }
        return space.index
    }
}
