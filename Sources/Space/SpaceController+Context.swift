import AppKit
import Foundation

@MainActor
extension SpaceController {

    func captureSpaceContext(windowID: UInt32, operationID: String? = nil) -> SpaceContext {
        let op = operationID ?? "none"
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            return SpaceContext(
                sourceSpaceIndex: nil,
                targetSpaceIndex: nil,
                sourceDisplayIndex: nil,
                sourceDisplaySpaceIndex: nil
            )
        }

        let windowInfo = queryWindow(windowID: windowID)
        let windowSpace = windowInfo?.space
        let windowDisplay = windowInfo?.display
        let spaces = querySpaces()
        let visibleSpaceOnDisplay = visibleSpaceIndex(forDisplayIndex: windowDisplay, spaces: spaces)
        let sourceSpace = preferredSourceSpace(
            windowSpace: windowSpace,
            visibleSpace: visibleSpaceOnDisplay?.yabaiIndex,
            fallbackSpace: nil
        )
        let localSpace = displayLocalSpaceIndex(
            forGlobalSpaceIndex: sourceSpace,
            displayIndex: windowDisplay,
            spaces: spaces
        )

        log(
            "[SpaceController] capture space context",
            fields: [
                "op": op,
                "windowID": String(windowID),
                "sourceSpace": String(describing: sourceSpace),
                "windowSpace": String(describing: windowSpace),
                "visibleSpace": String(describing: visibleSpaceOnDisplay),
                "display": String(describing: windowDisplay),
                "localSpace": String(describing: localSpace)
            ]
        )

        return SpaceContext(
            sourceSpaceIndex: sourceSpace.map { .yabai($0) },
            targetSpaceIndex: visibleSpaceOnDisplay,
            sourceDisplayIndex: windowDisplay.map { .yabai($0) },
            sourceDisplaySpaceIndex: localSpace
        )
    }

    /// Pure logic for displayLocalSpaceIndex — extracted for testability.
    static func resolveDisplayLocalSpaceIndex(spaceIndex: Int?, displayIndex: Int?, spaces: [YabaiSpaceInfo]?) -> Int? {
        guard let spaceIndex, let displayIndex else { return nil }
        guard let spaces else { return nil }
        let spacesOnDisplay = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }
        for (offset, info) in spacesOnDisplay.enumerated() {
            if info.index == spaceIndex {
                return offset + 1
            }
        }
        return nil
    }

    func displayLocalSpaceIndex(forGlobalSpaceIndex spaceIndex: Int?, displayIndex: Int?, spaces: [YabaiSpaceInfo]? = nil) -> Int? {
        log(
            "[SpaceController] displayLocalSpaceIndex called",
            level: .debug,
            fields: [
                "spaceIndex": String(describing: spaceIndex),
                "displayIndex": String(describing: displayIndex),
                "hasSpaces": String(spaces != nil)
            ]
        )
        if let spaces {
            return Self.resolveDisplayLocalSpaceIndex(spaceIndex: spaceIndex, displayIndex: displayIndex, spaces: spaces)
        }
        guard let spaceIndex, let displayIndex else {
            log(
                "[SpaceController] displayLocalSpaceIndex: nil input",
                level: .debug
            )
            return nil
        }
        refreshAvailabilityIfNeeded()
        guard isEnabled, let queried = querySpaces() else {
            return nil
        }
        return Self.resolveDisplayLocalSpaceIndex(spaceIndex: spaceIndex, displayIndex: displayIndex, spaces: queried)
    }

    /// Pure logic for nativeSpaceID — extracted for testability.
    static func resolveNativeSpaceID(yabaiIndex: Int, spaces: [YabaiSpaceInfo]?) -> Int64? {
        guard let spaces else { return nil }
        guard let id = spaces.first(where: { $0.index == yabaiIndex })?.id else { return nil }
        return Int64(id)
    }

    func nativeSpaceID(forYabaiIndex index: Int) -> Int64? {
        let result = Self.resolveNativeSpaceID(yabaiIndex: index, spaces: querySpaces())
        if result == nil {
            log(
                "[SpaceController] nativeSpaceID: no match",
                level: .debug,
                fields: ["yabaiIndex": String(index)]
            )
        } else {
            log(
                "[SpaceController] nativeSpaceID resolved",
                level: .debug,
                fields: ["yabaiIndex": String(index), "nativeSpaceID": result.map { String($0) } ?? "unknown"]
            )
        }
        return result
    }

    func preferredSourceSpace(windowSpace: Int?, visibleSpace: Int?, fallbackSpace: Int?) -> Int? {
        if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
            log("[SpaceController] source space mismatch windowSpace=\(windowSpace) visibleSpace=\(visibleSpace); prefer windowSpace for accurate restore")
            return windowSpace
        }
        return windowSpace ?? visibleSpace ?? fallbackSpace
    }
}
