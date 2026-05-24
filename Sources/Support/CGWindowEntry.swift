import CoreGraphics
import Foundation

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
    guard let rawList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return rawList.compactMap { CGWindowEntry(from: $0) }
}
