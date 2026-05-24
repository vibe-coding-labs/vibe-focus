import Foundation

enum LANHookPreferences {
    static let lanModeKey = "claudeHookLanMode"
    static let remoteBindingsKey = "claudeHookRemoteBindings"

    static let defaultLanMode = false

    static var lanMode: Bool {
        get { UserDefaults.standard.object(forKey: lanModeKey) as? Bool ?? defaultLanMode }
        set {
            UserDefaults.standard.set(newValue, forKey: lanModeKey)
            PreferencesSync.persistToDisk()
        }
    }

    /// 远程机器 → 窗口ID 映射, 格式: ["machine-label": windowID]
    /// windowID 为 nil 表示已添加但尚未选择窗口
    static var remoteBindings: [String: UInt32?] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: remoteBindingsKey) else { return [:] }
            var result: [String: UInt32?] = [:]
            for (key, value) in raw {
                if let id = value as? UInt32 {
                    result[key] = id
                } else if let id = value as? Int {
                    result[key] = UInt32(id)
                }
            }
            return result
        }
        set {
            var storable: [String: Any] = [:]
            for (key, value) in newValue {
                if let id = value {
                    storable[key] = id
                }
            }
            UserDefaults.standard.set(storable, forKey: remoteBindingsKey)
            PreferencesSync.persistToDisk()
        }
    }

    /// 获取所有已映射窗口的绑定（过滤掉 nil 值）
    static var activeRemoteBindings: [String: UInt32] {
        remoteBindings.compactMapValues { $0 }
    }

    /// 获取本机 en0 的 IPv4 地址
    static func currentLANIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
