import Foundation

/// Manages LAN hook remote machine binding preferences and persistence.
enum LANHookPreferences {
    static let lanModeKey = "claudeHookLanMode"
    private static let remoteBindingsKey = "claudeHookRemoteBindings"

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

    /// 持久化 active 映射为 JSON string 到 UserDefaults（getter 迁移写回与 setter 共用）。
    private static func persistBindings(_ active: [String: UInt32]) {
        if let data = try? JSONEncoder().encode(active),
           let jsonStr = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(jsonStr, forKey: remoteBindingsKey)
        }
    }

    /// 旧格式（UserDefaults dictionary，Int/UInt32 混态）→ 绑定映射解析。
    /// B83 测试缝提纯：逻辑原内联在 remoteBindings getter 的迁移分支；非数值垃圾值跳过。
    static func parseLegacyBindings(from raw: [String: Any]) -> [String: UInt32?] {
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

    /// 远程机器 → 窗口ID 映射, 格式: ["machine-label": windowID]
    /// windowID 为 nil 表示已添加但尚未选择窗口
    /// 序列化为 JSON string 存入 UserDefaults
    static var remoteBindings: [String: UInt32?] {
        get {
            // P-INST-145: remoteBindings UserDefaults 读耗时（string(forKey:) + JSONDecoder.decode / dictionary(forKey:) 旧格式迁移 + 可能触发写回 set；hook remote 事件路径 HookEventHandler+Remote:19 activeRemoteBindings 委托 + 设置 UI 读取）。
            #if PERF_INSTRUMENT
            let rbgStart = Date()
            defer {
                log("[LANHookPreferences] remoteBindings get finished", level: .debug, fields: [
                    "durationMs": String(elapsedMilliseconds(since: rbgStart))
                ])
            }
            #endif
            if let jsonStr = UserDefaults.standard.string(forKey: remoteBindingsKey),
               let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: UInt32].self, from: data) {
                return decoded.mapValues { Optional($0) }
            }
            guard let raw = UserDefaults.standard.dictionary(forKey: remoteBindingsKey) else { return [:] }
            // 旧格式迁移写回（经辅助函数直接持久化，避免 getter 内访问自身）
            let result = parseLegacyBindings(from: raw)
            if !result.isEmpty {
                persistBindings(result.compactMapValues { $0 })
            }
            return result
        }
        set {
            // P-INST-145: remoteBindings UserDefaults 写耗时（JSONEncoder.encode + CFPreferences 同步写；设置 UI bind/unbind/remap 写）。
            #if PERF_INSTRUMENT
            let rbsStart = Date()
            defer {
                log("[LANHookPreferences] remoteBindings set finished", level: .debug, fields: [
                    "durationMs": String(elapsedMilliseconds(since: rbsStart))
                ])
            }
            #endif
            persistBindings(newValue.compactMapValues { $0 })
        }
    }

    /// 获取所有已映射窗口的绑定（过滤掉 nil 值）
    static var activeRemoteBindings: [String: UInt32] {
        remoteBindings.compactMapValues { $0 }
    }

    /// 获取本机对外可直达的 LAN IPv4 地址。
    /// 选择规则（B73）：优先 en0，其次其它物理网卡族 enX；排除 loopback 与
    /// utun/awdl 等 VPN/虚拟口（那些地址局域网对端不可达）；无合格候选 → 127.0.0.1。
    /// 旧行为硬编码只认 en0——Wi-Fi 不在 en0 的机器会拿到 127.0.0.1，
    /// 设置页显示与远程安装脚本随之失效。
    static func currentLANIP() -> String {
        // P-INST-146: 本机 en0 IPv4 地址查询耗时（getifaddrs 链表遍历 + getnameinfo 反向解析 syscall + freeifaddrs；HookInstaller:33 写 config host + LANSettingsView 显示调用）。
        #if PERF_INSTRUMENT
        let clipStart = Date()
        defer {
            log("[LANHookPreferences] currentLANIP finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: clipStart))
            ])
        }
        #endif
        var candidates: [(interface: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr != nil,
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: hostname)))
        }
        return selectLANIP(from: candidates) ?? "127.0.0.1"
    }

    /// 从 IPv4 候选（interface, ip）中选出对外 LAN IP 的纯判定：
    /// en0 最优先 → 其它 enX → 无合格候选返回 nil（调用方回退 127.0.0.1）。
    /// loopback 与非 en 前缀（utun/awdl/llw/bridge 等虚拟口）不参与。
    static func selectLANIP(from candidates: [(interface: String, ip: String)]) -> String? {
        let lan = candidates.filter { $0.interface.hasPrefix("en") && !$0.ip.hasPrefix("127.") }
        if let en0 = lan.first(where: { $0.interface == "en0" }) {
            return en0.ip
        }
        return lan.first?.ip
    }
}
