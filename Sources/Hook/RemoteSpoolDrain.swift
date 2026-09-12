// RemoteSpoolDrain.swift
// VibeFocus — 远程事件兜底通道（B171 建通道，B172 VPN 健壮性加固）：spool 落盘 + Mac 主动 SSH 拉取
//
// 背景：VPN/单向 NAT 场景下远程机器回程不可达——hook-config.json 里的 Mac 地址
// 从服务端路由不通（2026-09-12 真机实锤：001 的 config 指向 10.9.0.2，curl 三路
// 地址全 000），且 001/002 的 sshd hardening `AllowTcpForwarding no` 把 ssh -R
// 反向隧道也堵死。唯一不依赖网络拓扑、不依赖 sshd 转发策略、只依赖「Mac 能 SSH
// 到服务器」（用户跑 Claude Code 的前提本身）的通道 = 拉模式：
//   1. forwarder 直投失败 → 事件 JSON 落盘远程 ~/.vibefocus/spool/（原子改名）；
//   2. Mac 侧定时器逐主机 ssh exec 读走 spool（旧于阈值先删、批限量），
//      逐行回灌 ClaudeHookServer.handleHookRequest —— 与 HTTP 事件同一管线。
// 代价：事件延迟 ≤ 拉取间隔（秒级），换来 LAN/VPN/任何单向网络全场景可用。

import Foundation

// MARK: - 纯判定层（Runner 直测）

/// spool 拉取通道的纯函数族：主机规范化 / 对端地址解析 / 事件注册决策 /
/// 拉取命令构建 / 输出行解析 / ssh argv 构建。全部无 IO、无隔离，Runner 真身直测。
enum RemoteSpoolDrainLogic {

    /// ssh 目标规范化："user@host" 或 "host"。拒绝：空串、含空白、前导 `-`
    ///（防 ssh 选项注入——target 走 argv 不走 shell，但 `-oProxyCommand=...`
    /// 形态的注入必须在前端堵死）、多个 `@`、超长。
    static func normalizeHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 255,
              !trimmed.hasPrefix("-"),
              !trimmed.contains(where: { $0.isWhitespace }),
              trimmed.filter({ $0 == "@" }).count <= 1
        else { return nil }
        return trimmed
    }

    /// GCDWebServer remoteAddressString → 对端 IP："ip:port" 取最后一个冒号前段，
    /// 裸 IP 原样返回（IPv6 形态 "::1:port" 同规则，够用于回环/局域网判定）。
    static func peerIP(fromRemoteAddress raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let idx = raw.lastIndex(of: ":") {
            let ip = String(raw[raw.startIndex..<idx])
            return ip.isEmpty ? nil : ip
        }
        return raw
    }

    /// 直投事件顺路自注册 drain 主机的决策（纯函数）：
    /// 仅当「远程事件（有 machine_label）+ forwarder 上报的 ssh 用户与服务器 IP
    /// 齐全 + 事件 TCP 对端 == 上报的服务器 IP（防伪造/代理错位）」时，
    /// 注册 "\(sshUser)@\(sshServerIP)"。任一条件不满足返回 nil（不注册，无害）。
    static func registrationTarget(
        machineLabel: String?,
        sshUser: String?,
        sshServerIP: String?,
        peerIP peer: String?
    ) -> String? {
        guard let label = machineLabel, !label.isEmpty,
              let user = sshUser, !user.isEmpty,
              let serverIP = sshServerIP, !serverIP.isEmpty,
              let peer, !peer.isEmpty,
              peer == serverIP
        else { return nil }
        return normalizeHost("\(user)@\(serverIP)")
    }

    /// 远程侧拉取命令（用户登录 shell 执行；zsh/bash/sh 兼容，避免 glob 空匹配
    /// 差异用 find 而非 for）。行为：目录不存在建之；先删超龄文件（Mac 失联过久
    /// 的陈旧事件——恢复类事件过时已无意义）；按文件名（epoch 前缀=时间序）取
    /// 最旧一批，逐个 cat + 删（cat 失败不删，下轮重试），JSONL 输出。
    static func drainCommand(stalenessMinutes: Int, batchLimit: Int) -> String {
        """
        mkdir -p "$HOME/.vibefocus/spool" 2>/dev/null || exit 0
        cd "$HOME/.vibefocus/spool" || exit 0
        find . -maxdepth 1 -name '*.json' -mmin +\(stalenessMinutes) -delete 2>/dev/null
        find . -maxdepth 1 -name '*.json' 2>/dev/null | sort | head -n \(batchLimit) | while IFS= read -r f; do
          cat "$f" 2>/dev/null && printf '\\n' && rm -f "$f" 2>/dev/null
        done
        exit 0
        """
    }

    /// 拉取输出 → 事件载荷行。跳过空行（文件间分隔产生的双换行），只留首字符
    /// 为 `{` 的行——ssh 杂音/半截写入不进计数器（400 计数污染）。
    /// 行尾按空白+换行整体修剪（容忍 CRLF）。
    static func parseDrainedLines(_ stdout: String) -> [String] {
        stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("{") }
    }

    /// ssh argv（target 已过 normalizeHost；`--` 后置目标防选项注入双保险；
    /// BatchMode 免交互挂死；复用用户全局 ControlMaster mux——exec 毫秒级）。
    static func sshArguments(target: String, command: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "--", target, command,
        ]
    }

    /// drain 超时后强制重置可疑 ControlMaster 的 argv（B172）。
    /// VPN 半开连接下死掉的 mux master 会让后续 exec 挂到 TCP keepalive
    ///（用户配置 15s×3≈45s）才自愈；`ssh -O exit` 立即清掉，下一 tick 走全新
    /// 连接。fire-and-forget：master 不存在/已死时该命令失败，无害。
    static func muxResetArguments(target: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-O", "exit", "--", target]
    }
}

// MARK: - drain 主机注册表（UserDefaults 持久化）

/// drain 目标主机清单（"user@host" 数组，JSON 存 UserDefaults）。
/// 来源三通道：① 直投事件顺路自注册（registrationTarget，LAN 时期部署的主机
/// 永久记住）；② 设置页手动添加（VPN 先行部署场景的唯一入口）；③ 装机侧 defaults
/// 预置（自助闭环，不推给用户）。
enum RemoteSpoolHosts {
    static let hostsKey = "claudeHookRemoteHosts"

    static func loadHosts(defaults: UserDefaults = .standard) -> [String] {
        guard let raw = defaults.string(forKey: hostsKey),
              let data = raw.data(using: .utf8),
              let hosts = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return hosts.compactMap { RemoteSpoolDrainLogic.normalizeHost($0) }
    }

    static func saveHosts(_ hosts: [String], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(hosts),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: hostsKey)
    }

    /// 注册（去重、保持插入序）。返回是否真的新增（供日志/去抖）。
    @discardableResult
    static func registerHost(_ raw: String, defaults: UserDefaults = .standard) -> Bool {
        guard let host = RemoteSpoolDrainLogic.normalizeHost(raw) else { return false }
        var hosts = loadHosts(defaults: defaults)
        guard !hosts.contains(host) else { return false }
        hosts.append(host)
        saveHosts(hosts, defaults: defaults)
        return true
    }

    static func removeHost(_ raw: String, defaults: UserDefaults = .standard) {
        var hosts = loadHosts(defaults: defaults)
        hosts.removeAll { $0 == raw }
        saveHosts(hosts, defaults: defaults)
    }
}

// MARK: - Mac 侧拉取器（定时 ssh exec 逐主机读 spool 回灌事件管线）

@MainActor
final class RemoteSpoolDrainer: ObservableObject {
    static let shared = RemoteSpoolDrainer()

    struct HostStatus: Equatable {
        var lastDrainAt: Date?
        var lastEventCount: Int = 0
        var lastError: String?
    }

    @Published private(set) var statuses: [String: HostStatus] = [:]

    static let pollInterval: TimeInterval = 2.0
    static let drainTimeout: TimeInterval = 10.0
    /// spool 陈旧阈值：容忍服务器时钟偏差与 Mac 离线数十分钚——事件仍有恢复
    /// 语义；再老（>1h）恢复目标大概率已失效，删。
    static let stalenessMinutes = 60
    static let batchLimit = 20
    /// B178：单 tick 回灌预算。回灌的每个事件都在主线程同步执行（UPS 归位实测
    /// 0.2~2.3s/个），一次回灌 20 个曾把主线程连占 31~66s（打字卡死实锤）——
    /// 分批回灌，剩余顺延到下个 tick（事件缓冲在内存 pendingReplay，不丢）。
    static let maxReplaysPerTick = 4

    private var timer: Timer?
    private var inFlight: Set<String> = []
    /// 已从远程 spool 取走、但超出本 tick 预算待回灌的事件（内存缓冲；app 退出即失，
    /// 与回灌中途崩溃的既有风险同级）。
    private var pendingReplay: [String] = []

    /// 与 hook 服务同生命周期：启用且有注册主机才轮询；主机清单变化无需重启
    /// （tick 每轮现读注册表），仅启停边界需重调用。
    func applyPreferences() {
        let shouldRun = ClaudeHookPreferences.isEnabled && !RemoteSpoolHosts.loadHosts().isEmpty
        if shouldRun {
            guard timer == nil else { return }
            let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            timer = t
            log("[RemoteSpoolDrainer] polling started", fields: [
                "hosts": RemoteSpoolHosts.loadHosts().joined(separator: ","),
                "intervalS": String(Self.pollInterval)
            ])
        } else {
            guard timer != nil else { return }
            timer?.invalidate()
            timer = nil
            log("[RemoteSpoolDrainer] polling stopped")
        }
    }

    /// 设置页「立即拉取」：确保在跑 + 立即 tick 一轮。
    func drainNow() {
        applyPreferences()
        tick()
    }

    func tick() {
        // B178：上一批取回的事件还有积压时，本 tick 优先消化积压、不再发起新的
        // ssh 拉取——主线程每 tick 只背一份窗口作业，事件不丢（顺延处理）。
        if !pendingReplay.isEmpty {
            let budget = Array(pendingReplay.prefix(Self.maxReplaysPerTick))
            pendingReplay.removeFirst(min(Self.maxReplaysPerTick, pendingReplay.count))
            log("[RemoteSpoolDrainer] replaying deferred events", fields: [
                "count": String(budget.count),
                "stillPending": String(pendingReplay.count)
            ])
            replayDeferred(budget)
            return
        }
        for host in RemoteSpoolHosts.loadHosts() where !inFlight.contains(host) {
            startDrain(host: host)
        }
    }

    /// 积压回灌（与 finishDrain 同管线同 token 门；事件已离开远程 spool，只能
    /// 内存顺延不能丢弃）。
    private func replayDeferred(_ lines: [String]) {
        guard ClaudeHookPreferences.isEnabled else {
            log("[RemoteSpoolDrainer] deferred events dropped (hook disabled)", level: .warn, fields: [
                "count": String(lines.count)
            ])
            return
        }
        var headers: [String: String] = [:]
        if let token = ClaudeHookPreferences.authToken, !token.isEmpty {
            headers["X-VibeFocus-Token"] = token
        }
        PerfMonitor.shared.beginSection("spool.replay.deferred", fields: ["count": String(lines.count)])
        defer { PerfMonitor.shared.endSection() }
        for line in lines {
            _ = ClaudeHookServer.shared.handleHookRequest(
                body: Data(line.utf8),
                query: [:],
                headers: headers,
                peerAddress: nil
            )
        }
    }

    private func startDrain(host: String) {
        inFlight.insert(host)
        let command = RemoteSpoolDrainLogic.drainCommand(
            stalenessMinutes: Self.stalenessMinutes,
            batchLimit: Self.batchLimit
        )
        let arguments = RemoteSpoolDrainLogic.sshArguments(target: host, command: command)
        let timeout = Self.drainTimeout
        log("[RemoteSpoolDrainer] drain start", level: .debug, fields: ["host": host])
        DispatchQueue.global(qos: .utility).async {
            let result = Self.runProcess(executable: "/usr/bin/ssh", arguments: arguments, timeout: timeout)
            if result == nil {
                // B172: 超时=连接疑似半开（VPN 撤销/切换常见）。强制重置共享
                // ControlMaster，防后续 exec 挂死等 TCP keepalive（~45s）。
                _ = Self.runProcess(
                    executable: "/usr/bin/ssh",
                    arguments: RemoteSpoolDrainLogic.muxResetArguments(target: host),
                    timeout: 8.0
                )
            }
            Task { @MainActor [weak self] in
                await self?.finishDrain(host: host, result: result)
            }
        }
    }

    private func finishDrain(host: String, result: (exitCode: Int32, stdout: String, stderr: String)?) async {
        inFlight.remove(host)
        var status = statuses[host] ?? HostStatus()
        defer { statuses[host] = status }

        guard let result else {
            status.lastDrainAt = Date()
            status.lastError = "ssh 超时或启动失败"
            log("[RemoteSpoolDrainer] drain failed (timeout/spawn)", level: .warn, fields: ["host": host])
            return
        }
        status.lastDrainAt = Date()
        // ssh 自身错误用 255；拉取命令恒 exit 0（空目录/无事件都正常）。
        if result.exitCode == 255 {
            status.lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if status.lastError?.isEmpty == true { status.lastError = "ssh exit 255" }
            log("[RemoteSpoolDrainer] drain unreachable", level: .debug, fields: [
                "host": host,
                "stderr": String((status.lastError ?? "").prefix(200))
            ])
            return
        }
        status.lastError = nil

        let events = RemoteSpoolDrainLogic.parseDrainedLines(result.stdout)
        status.lastEventCount = events.count
        guard !events.isEmpty else { return }
        log("[RemoteSpoolDrainer] drained events", fields: [
            "host": host,
            "count": String(events.count)
        ])

        // B172: 回灌前复核 hook 开关——关开关瞬间在途拉取的事件不再驱动
        // 窗口动作（事件已从 spool 取走，无法回滚；丢弃并在日志交代）。
        guard ClaudeHookPreferences.isEnabled else {
            log("[RemoteSpoolDrainer] drained events dropped (hook disabled mid-flight)", level: .warn, fields: [
                "host": host,
                "count": String(events.count)
            ])
            return
        }

        // B178：分批回灌——超预算部分顺延到 pendingReplay（下个 tick 优先消化）。
        // 单次回灌曾把主线程连占 31~66s（打字卡死实锤），预算制让主线程每 tick
        // 只背最多 maxReplaysPerTick 个事件的窗口作业。
        let budget = Array(events.prefix(Self.maxReplaysPerTick))
        let deferred = Array(events.dropFirst(Self.maxReplaysPerTick))
        if !deferred.isEmpty {
            pendingReplay.append(contentsOf: deferred)
            log("[RemoteSpoolDrainer] deferred events to next tick", level: .warn, fields: [
                "host": host,
                "deferred": String(deferred.count),
                "budget": String(budget.count)
            ])
        }

        var headers: [String: String] = [:]
        if let token = ClaudeHookPreferences.authToken, !token.isEmpty {
            headers["X-VibeFocus-Token"] = token
        }
        // 与 HTTP 事件同一管线（token 门/解码/分发/计数全同）；spool 通道
        // 已经过注册表信任边界（本机 ssh 凭据拉取），对端传 nil 走 local 分类，
        // 远程语义由 payload 自带 machine_label 驱动，与来源分类解耦。
        PerfMonitor.shared.beginSection("spool.replay", fields: ["host": host, "count": String(budget.count)])
        defer { PerfMonitor.shared.endSection() }
        for line in budget {
            _ = ClaudeHookServer.shared.handleHookRequest(
                body: Data(line.utf8),
                query: [:],
                headers: headers,
                peerAddress: nil
            )
            // 让主队列插钥/UI 呼吸一拍——连续窗口作业之间主线程不再连续占用。
            await Task.yield()
        }
    }

    /// 进程执行：可读性边收边蓄（drain 输出可能超管道缓冲，exit 后再读会死锁
    /// 子进程），超时强杀返回 nil。
    nonisolated static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (exitCode: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 跨线程累积器（readabilityHandler 队列写 / 本线程读）：锁守护，
        // @unchecked Sendable 压掉闭包捕获告警——运行期竞态由锁排除。
        let outAccumulator = LockedDataAccumulator()
        let errAccumulator = LockedDataAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            outAccumulator.append(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            errAccumulator.append(chunk)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: outAccumulator.value, encoding: .utf8) ?? "",
            stderr: String(data: errAccumulator.value, encoding: .utf8) ?? ""
        )
    }
}

/// 跨线程 Data 累积器（锁守护；runProcess 的 readabilityHandler 专用）。
final class LockedDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
