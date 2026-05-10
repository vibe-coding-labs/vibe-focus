import Foundation

struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

enum SpaceIndexResolver {
    static func chooseIndex(displaySpaces: [SpaceSnapshot], focusedSpaceIndex: Int?, screenCount: Int) -> Int? {
        log("SpaceIndexResolver.chooseIndex() entered", level: .debug, fields: [
            "displaySpacesCount": String(displaySpaces.count),
            "focusedSpaceIndex": focusedSpaceIndex.map(String.init) ?? "nil",
            "screenCount": String(screenCount)
        ])
        let displayActive = activeDisplaySpaceIndex(in: displaySpaces)
        let displayIndices = Set(displaySpaces.map(\.index))

        // Single-display setups are most sensitive to stale display queries during swipe animations.
        if screenCount <= 1 {
            log("SpaceIndexResolver.chooseIndex() single-display path", level: .debug)
            if let focusedSpaceIndex {
                if displayIndices.isEmpty || displayIndices.contains(focusedSpaceIndex) {
                    log("SpaceIndexResolver.chooseIndex() returning focusedSpaceIndex for single-display", level: .debug, fields: ["index": String(focusedSpaceIndex)])
                    return focusedSpaceIndex
                }
            }
            log("SpaceIndexResolver.chooseIndex() returning displayActive for single-display", level: .debug, fields: ["index": displayActive.map(String.init) ?? "nil"])
            return displayActive
        }

        if let displayActive {
            log("SpaceIndexResolver.chooseIndex() multi-display: returning displayActive", level: .debug, fields: ["index": String(displayActive)])
            return displayActive
        }
        if let focusedSpaceIndex, displayIndices.contains(focusedSpaceIndex) {
            log("SpaceIndexResolver.chooseIndex() multi-display: returning focusedSpaceIndex fallback", level: .debug, fields: ["index": String(focusedSpaceIndex)])
            return focusedSpaceIndex
        }
        log("SpaceIndexResolver.chooseIndex() returning nil, no suitable index found", level: .debug)
        return nil
    }

    static func resolveStableIndex(samples: [Int]) -> Int? {
        log("SpaceIndexResolver.resolveStableIndex() entered", level: .debug, fields: [
            "sampleCount": String(samples.count),
            "samples": samples.map(String.init).joined(separator: ",")
        ])
        guard !samples.isEmpty else {
            log("SpaceIndexResolver.resolveStableIndex() empty samples, returning nil", level: .debug)
            return nil
        }

        var counts: [Int: Int] = [:]
        for sample in samples {
            counts[sample, default: 0] += 1
        }
        guard let maxCount = counts.values.max() else {
            log("SpaceIndexResolver.resolveStableIndex() no max count found", level: .debug)
            return nil
        }

        let candidates = Set(counts.compactMap { key, value in
            value == maxCount ? key : nil
        })

        log("SpaceIndexResolver.resolveStableIndex() frequency analysis", level: .debug, fields: [
            "maxCount": String(maxCount),
            "candidateCount": String(candidates.count)
        ])

        for sample in samples.reversed() {
            if candidates.contains(sample) {
                log("SpaceIndexResolver.resolveStableIndex() returning stable index", level: .debug, fields: ["index": String(sample)])
                return sample
            }
        }

        log("SpaceIndexResolver.resolveStableIndex() falling back to last sample", level: .debug, fields: ["index": samples.last.map(String.init) ?? "nil"])
        return samples.last
    }

    private static func activeDisplaySpaceIndex(in spaces: [SpaceSnapshot]) -> Int? {
        if let visible = spaces.first(where: { $0.isVisible }) {
            log("SpaceIndexResolver.activeDisplaySpaceIndex() found visible space", level: .debug, fields: ["index": String(visible.index)])
            return visible.index
        }
        if let focused = spaces.first(where: { $0.hasFocus }) {
            log("SpaceIndexResolver.activeDisplaySpaceIndex() found focused space", level: .debug, fields: ["index": String(focused.index)])
            return focused.index
        }
        log("SpaceIndexResolver.activeDisplaySpaceIndex() no visible or focused space found", level: .debug)
        return nil
    }
}
