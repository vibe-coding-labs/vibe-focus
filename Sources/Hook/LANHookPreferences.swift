import Foundation

/// Manages LAN hook remote machine binding preferences and persistence.
enum LANHookPreferences {
    static let lanModeKey = "claudeHookLanMode"
    static let remoteBindingsKey = "claudeHookRemoteBindings"

    static let defaultLanMode = false

    static var lanMode: Bool {
        get {
            // P-INST-144: lanMode UserDefaults 读耗时（CFPreferences 同步读；hook server 启动 ClaudeHookServer:105 bindToLocalHost 决策 + HookScriptGenerator/HookInstaller config 生成 + 设置 UI 读取；首次访问可能阻塞）。
            let lmgStart = Date()
            let value = UserDefaults.standard.object(forKey: lanModeKey) as? Bool ?? defaultLanMode
            log("[LANHookPreferences] lanMode get finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: lmgStart)),
                "value": String(value)
            ])
            return value
        }
        set {
            // P-INST-144: lanMode UserDefaults 写耗时（CFPreferences 同步写；LANSettingsView Toggle didSet 写）。
            let lmsStart = Date()
            UserDefaults.standard.set(newValue, forKey: lanModeKey)
            log("[LANHookPreferences] lanMode set finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: lmsStart))
            ])
        }
    }

    /// 远程机器 → 窗口ID 映射, 格式: ["machine-label": windowID]
    /// windowID 为 nil 表示已添加但尚未选择窗口
    /// 序列化为 JSON string 存入 UserDefaults
    static var remoteBindings: [String: UInt32?] {
        get {
            // P-INST-145: remoteBindings UserDefaults 读耗时（string(forKey:) + JSONDecoder.decode / dictionary(forKey:) 旧格式迁移 + 可能触发写回 set；hook remote 事件路径 HookEventHandler+Remote:19 activeRemoteBindings 委托 + 设置 UI 读取）。
            let rbgStart = Date()
            defer {
                log("[LANHookPreferences] remoteBindings get finished", level: .debug, fields: [
                    "durationMs": String(elapsedMilliseconds(since: rbgStart))
                ])
            }
            if let jsonStr = UserDefaults.standard.string(forKey: remoteBindingsKey),
               let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: UInt32].self, from: data) {
                return decoded.mapValues { Optional($0) }
            }
            guard let raw = UserDefaults.standard.dictionary(forKey: remoteBindingsKey) else { return [:] }
            var result: [String: UInt32?] = [:]
            for (key, value) in raw {
                if let id = value as? UInt32 {
                    result[key] = id
                } else if let id = value as? Int {
                    result[key] = UInt32(id)
                }
            }
            if !result.isEmpty {
                remoteBindings = result
            }
            return result
        }
        set {
            // P-INST-145: remoteBindings UserDefaults 写耗时（JSONEncoder.encode + CFPreferences 同步写；设置 UI bind/unbind/remap 写）。
            let rbsStart = Date()
            defer {
                log("[LANHookPreferences] remoteBindings set finished", level: .debug, fields: [
                    "durationMs": String(elapsedMilliseconds(since: rbsStart))
                ])
            }
            let active: [String: UInt32] = newValue.compactMapValues { $0 }
            if let data = try? JSONEncoder().encode(active),
               let jsonStr = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(jsonStr, forKey: remoteBindingsKey)
            }
        }
    }

    /// 获取所有已映射窗口的绑定（过滤掉 nil 值）
    static var activeRemoteBindings: [String: UInt32] {
        remoteBindings.compactMapValues { $0 }
    }

    /// 获取本机 en0 的 IPv4 地址
    static func currentLANIP() -> String {
        // P-INST-146: 本机 en0 IPv4 地址查询耗时（getifaddrs 链表遍历 + getnameinfo 反向解析 syscall + freeifaddrs；HookInstaller:33 写 config host + LANSettingsView 显示调用）。
        let clipStart = Date()
        defer {
            log("[LANHookPreferences] currentLANIP finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: clipStart))
            ])
        }
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
