import AppKit
import Foundation

@MainActor
extension SpaceController {

    func queryFocusedSpace() -> YabaiSpaceInfo? {
        // P-INST-57: queryFocusedSpace 耗时（runYabai query --spaces --space fork + decode；overlay refreshSpaceIndices P-INST-42 的 focused space 查询，底层 runYabai P-INST-27 已覆盖 fork，此埋点补顶层归因）。
        #if PERF_INSTRUMENT
        let qfsStart = Date()
        defer {
            log("[SpaceController] queryFocusedSpace finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: qfsStart))
            ])
        }
        #endif
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
        let result = runYabai(arguments: ["-m", "query", "--windows", "--window"])
        guard let result, result.exitCode == 0 else {
            let durationMs = elapsedMilliseconds(since: forkStart)
            // 区分预期失败和异常失败：
            // - "could not retrieve window details" = 无焦点窗口，正常场景（如用户点击桌面），降级为 debug
            // - 其他错误 = 需要关注的异常，保持 warn
            let stderr = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if stderr.contains("could not retrieve window details") {
                // 预期失败：无焦点窗口（如用户点击桌面、所有窗口最小化）
                log("[SpaceController] queryFocusedWindow: no focused window (expected)", level: .debug, fields: [
                    "durationMs": String(durationMs)
                ])
            } else {
                // 异常失败：其他错误（如 yabai 崩溃、权限问题）
                log("[SpaceController] queryFocusedWindow failed with unexpected error", level: .warn, fields: [
                    "durationMs": String(durationMs),
                    "stderr": stderr.isEmpty ? "-" : stderr
                ])
            }
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
            // 失败不写缓存：把"yabai 暂时不可用"缓存 2s 会让后续调用方把瞬时故障
            // 当成"无 space 信息"走错误分支（负缓存 bug，2026-09-01 修复）
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
        // 仅缓存成功解码的结果（decode 失败同样不缓存，见上）
        if let spaces {
            spacesQueryCache = (result: spaces, cachedAt: Date())
        }
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
        let directResult = runYabai(arguments: ["-m", "query", "--windows", "--window", "\(windowID)"])
        if let directResult, directResult.exitCode == 0 {
            let info = decodeSingleOrFirst(YabaiWindowInfo.self, from: directResult.stdout)
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

        // 直接查询失败，记录诊断并尝试 fallback
        // "could not locate window" = 窗口 ID 无效（窗口已关闭），预期场景，降级为 debug
        let stderr = directResult?.stderr ?? ""
        if stderr.contains("could not locate window") {
            log("[queryWindow] window not found (expected, window may have closed)", level: .debug, fields: [
                "windowID": String(windowID)
            ])
        } else {
            log("[queryWindow] direct query failed, trying all-windows fallback", level: .debug, fields: [
                "windowID": String(windowID),
                "stderr": stderr.isEmpty ? "-" : stderr
            ])
        }

        guard let allResult = runYabai(arguments: ["-m", "query", "--windows"]),
              allResult.exitCode == 0 else {
            log("[queryWindow] all-windows fallback also failed", level: .warn, fields: ["windowID": String(windowID)])
            // 命令失败不缓存（负缓存 bug 修复）；全量扫描成功但无此窗口的真负结果照常缓存
            return nil
        }
        let allWindows = decodeArray(YabaiWindowInfo.self, from: allResult.stdout) ?? []
        let match = allWindows.first { $0.id == Int(windowID) }
        log(
            "[queryWindow] fallback result",
            level: .debug,
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
