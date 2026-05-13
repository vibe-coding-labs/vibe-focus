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
            visibleSpace: visibleSpaceOnDisplay,
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
            sourceSpaceIndex: sourceSpace,
            targetSpaceIndex: visibleSpaceOnDisplay,
            sourceDisplayIndex: windowDisplay,
            sourceDisplaySpaceIndex: localSpace
        )
    }

    func captureSpaceContext(for windowID: UInt32) -> SpaceContext {
        let sourceSpace = windowSpaceIndex(windowID: windowID)
        let displayIdx = windowDisplayIndex(windowID: windowID)
        // sourceSpace 为 nil 时不传 0（yabai index 0 不存在），直接传播 nil
        let displayLocal = displayIdx.flatMap { displayIdxVal in
            sourceSpace.flatMap { displayLocalSpaceIndex(forGlobalSpaceIndex: $0, displayIndex: displayIdxVal) }
        }
        return SpaceContext(
            sourceSpaceIndex: sourceSpace,
            targetSpaceIndex: nil,
            sourceDisplayIndex: displayIdx,
            sourceDisplaySpaceIndex: displayLocal
        )
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
        guard let spaceIndex, let displayIndex else {
            log(
                "[SpaceController] displayLocalSpaceIndex: nil input",
                level: .debug
            )
            return nil
        }
        let resolvedSpaces: [YabaiSpaceInfo]
        if let spaces {
            resolvedSpaces = spaces
        } else {
            refreshAvailabilityIfNeeded()
            guard isEnabled, let queried = querySpaces() else {
                return nil
            }
            resolvedSpaces = queried
        }

        let spacesOnDisplay = resolvedSpaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

        for (offset, info) in spacesOnDisplay.enumerated() {
            if info.index == spaceIndex {
                return offset + 1
            }
        }
        return nil
    }

    func globalSpaceIndex(displayIndex: Int, localSpaceIndex: Int) -> Int? {
        refreshAvailabilityIfNeeded()
        guard isEnabled else {
            log(
                "[SpaceController] globalSpaceIndex: not enabled",
                level: .debug
            )
            return nil
        }
        guard let spaces = querySpaces() else {
            log(
                "[SpaceController] globalSpaceIndex: querySpaces failed",
                level: .debug
            )
            return nil
        }

        log(
            "[SpaceController] globalSpaceIndex called",
            level: .debug,
            fields: [
                "displayIndex": String(displayIndex),
                "localSpaceIndex": String(localSpaceIndex)
            ]
        )

        let spacesOnDisplay = spaces
            .filter { $0.display == displayIndex }
            .sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

        guard localSpaceIndex > 0, localSpaceIndex <= spacesOnDisplay.count else {
            return nil
        }

        return spacesOnDisplay[localSpaceIndex - 1].index
    }

    func nativeSpaceID(forYabaiIndex index: Int) -> Int64? {
        guard let spaces = querySpaces() else {
            log(
                "[SpaceController] nativeSpaceID: querySpaces failed",
                level: .debug,
                fields: ["yabaiIndex": String(index)]
            )
            return nil
        }
        let matched = spaces.first { $0.index == index }
        guard let id = matched?.id else {
            log(
                "[SpaceController] nativeSpaceID: no matching space",
                level: .debug,
                fields: ["yabaiIndex": String(index)]
            )
            return nil
        }
        log(
            "[SpaceController] nativeSpaceID resolved",
            level: .debug,
            fields: ["yabaiIndex": String(index), "nativeSpaceID": String(id)]
        )
        return Int64(id)
    }

    func preferredSourceSpace(windowSpace: Int?, visibleSpace: Int?, fallbackSpace: Int?) -> Int? {
        if let windowSpace, let visibleSpace, windowSpace != visibleSpace {
            log("[SpaceController] source space mismatch windowSpace=\(windowSpace) visibleSpace=\(visibleSpace); prefer windowSpace for accurate restore")
            return windowSpace
        }
        return windowSpace ?? visibleSpace ?? fallbackSpace
    }
}
