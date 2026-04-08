import Foundation

struct SpaceSnapshot: Equatable {
    let index: Int
    let isVisible: Bool
    let hasFocus: Bool
}

enum SpaceIndexResolver {
    static func chooseIndex(displaySpaces: [SpaceSnapshot], focusedSpaceIndex: Int?, screenCount: Int) -> Int? {
        let displayActive = activeDisplaySpaceIndex(in: displaySpaces)
        let displayIndices = Set(displaySpaces.map(\.index))

        // Single-display setups are most sensitive to stale display queries during swipe animations.
        if screenCount <= 1 {
            if let focusedSpaceIndex {
                if displayIndices.isEmpty || displayIndices.contains(focusedSpaceIndex) {
                    return focusedSpaceIndex
                }
            }
            return displayActive
        }

        if let displayActive {
            return displayActive
        }
        if let focusedSpaceIndex, displayIndices.contains(focusedSpaceIndex) {
            return focusedSpaceIndex
        }
        return nil
    }

    static func resolveStableIndex(samples: [Int]) -> Int? {
        guard !samples.isEmpty else {
            return nil
        }

        var counts: [Int: Int] = [:]
        for sample in samples {
            counts[sample, default: 0] += 1
        }
        guard let maxCount = counts.values.max() else {
            return nil
        }

        let candidates = Set(counts.compactMap { key, value in
            value == maxCount ? key : nil
        })

        for sample in samples.reversed() {
            if candidates.contains(sample) {
                return sample
            }
        }

        return samples.last
    }

    private static func activeDisplaySpaceIndex(in spaces: [SpaceSnapshot]) -> Int? {
        if let visible = spaces.first(where: { $0.isVisible }) {
            return visible.index
        }
        if let focused = spaces.first(where: { $0.hasFocus }) {
            return focused.index
        }
        return nil
    }
}
