import AppKit
import Foundation

@MainActor
extension SpaceController {

    func queryFocusedSpace() -> YabaiSpaceInfo? {
        // P-INST-57: queryFocusedSpace 耗时（runYabai query --spaces --space fork + decode；overlay refreshSpaceIndices P-INST-42 的 focused space 查询，底层 runYabai P-INST-27 已覆盖 fork，此埋点补顶层归因）。
        let qfsStart = Date()
        defer {
            log("[SpaceController] queryFocusedSpace finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: qfsStart))
            ])
        }
        guard let result = runYabai(arguments: ["-m", "query", "--spaces", "--space"]),
              result.exitCode == 0 else {
            return nil
        }
        return decodeSingleOrFirst(YabaiSpaceInfo.self, from: result.stdout)
    }

    /// yabai query focused window（无 window ID 参数 = 系统焦点窗口）。
    /// 返回焦点窗口的 YabaiWindowInfo（id=CGWindowID，pid，app，frame，space，display）。
    /// 非 AX —— 焦点窗口在副屏 Space 时也不阻塞（AX focusedWindow(for:) 同场景阻塞 1.5s，
    /// toggle-00000541 focusedWindowAxMs=1501）。这是 move_to_main 路径绕过 toggle 入口
    /// AX 阻塞的关键（P2 机制变更：toggle 入口用此拿 windowID，move_to_main 改 yabai space move 先行）。
    /// 不缓存：焦点窗口变化快，每次 fork ~30-50ms（未切 space）可接受（替代 AX 1.5s）。
    func queryFocusedWindow() -> YabaiWindowInfo? {
        // P-INST-6: queryFocusedWindow fork 耗时（副屏焦点窗口 ~635ms 是 move_to_main ctx 主因；
        // 总是 fork，无缓存读，但写 windowQueryCache 供后续 queryWindow 命中）。
        let forkStart = Date()
        guard let result = runYabai(arguments: ["-m", "query", "--windows", "--window"]),
              result.exitCode == 0 else {
            log("[SpaceController] queryFocusedWindow fork failed", level: .warn, fields: [
                "durationMs": String(elapsedMilliseconds(since: forkStart))
            ])
            return nil
        }
        let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
        // 写 windowQueryCache：toggle 入口已 fork 拿焦点窗口，后续 captureSpaceContext / moveWindow
        // 的 queryWindow(同 windowID) 缓存命中省 fork（移动前窗口 space/display/floating 一致）。
        // 缓存 windowID 由 has-focus 窗口的 id 决定，与 toggle 入口 resolvedWindowID 一致。
        if let info, let winID = info.id, let windowID = UInt32(exactly: winID) {
            windowQueryCache[windowID] = (result: info, cachedAt: Date())
        }
        log("[SpaceController] queryFocusedWindow", fields: [
            "durationMs": String(elapsedMilliseconds(since: forkStart)),
            "cacheHit": "false",
            "found": String(info != nil)
        ])
        return info
    }

    func querySpaces(caller: String = #function) -> [YabaiSpaceInfo]? {
        // P-INST-15: querySpaces cacheHit + durationMs（高频调用，cache hit 用 debug 减少噪音）。
        let qsStart = Date()
        // 1. 检查缓存
        if let cached = spacesQueryCache, !isCacheExpired(cached.cachedAt) {
            log("[SpaceController] querySpaces cache hit", level: .debug, fields: [
                "caller": caller,
                "durationMs": String(elapsedMilliseconds(since: qsStart)),
                "cacheHit": "true"
            ])
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
        log("[SpaceController] querySpaces fork", fields: [
            "caller": caller,
            "durationMs": String(elapsedMilliseconds(since: qsStart)),
            "cacheHit": "false",
            "spacesCount": String(spaces?.count ?? 0)
        ])
        return spaces
    }

    func queryWindow(windowID: UInt32) -> YabaiWindowInfo? {
        // P-INST-6: queryWindow fork 耗时 + cacheHit（toggle 入口 queryFocusedWindow 预填缓存，命中应 ~0ms）。
        let qwStart = Date()
        // 1. 检查缓存
        if let cached = windowQueryCache[windowID], !isCacheExpired(cached.cachedAt) {
            log("[SpaceController] queryWindow cache hit", fields: [
                "windowID": String(windowID),
                "durationMs": String(elapsedMilliseconds(since: qwStart)),
                "cacheHit": "true"
            ])
            return cached.result
        }

        // 2. 直接查询
        if let result = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"]),
           result.exitCode == 0 {
            let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: result.stdout)
            if info != nil {
                windowQueryCache[windowID] = (result: info, cachedAt: Date())
                log("[SpaceController] queryWindow direct", fields: [
                    "windowID": String(windowID),
                    "durationMs": String(elapsedMilliseconds(since: qwStart)),
                    "cacheHit": "false"
                ])
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
                "totalWindows": String(allWindows.count),
                "durationMs": String(elapsedMilliseconds(since: qwStart)),
                "cacheHit": "false"
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
