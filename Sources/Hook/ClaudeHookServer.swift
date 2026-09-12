import Foundation
import Cocoa
@preconcurrency import GCDWebServer

// B156 按域拆分（逐字搬移零行为变更）：请求壳纯判定族 → +Pure，hook 请求编排
// （token 门→解码→事件分发→计数→响应构造）→ +Request；本文件保留状态、偏好同步与监听生命周期。

@MainActor
final class ClaudeHookServer: ObservableObject {
    static let shared = ClaudeHookServer()

    @Published private(set) var isRunning = false
    @Published private(set) var statusDescription = "未启动"
    @Published private(set) var lastErrorMessage: String?
    @Published var lastEventAt: Date?
    @Published var totalRequestCount = 0
    @Published var handledRequestCount = 0
    @Published var unmatchedSessionCount = 0

    private var server: GCDWebServer?
    private var activePort: Int?
    var configuredToken: String?
    /// 当前监听实例的绑定模式（true=仅本机）。纳入重启判定：运行中翻转「局域网模式」
    /// 必须重绑定，否则开 LAN 无效、关 LAN 继续暴露 0.0.0.0（2026-09-10 模块审计实锤）。
    private var configuredBindToLocalhost: Bool?

    private init() {}

    func applyPreferences() {
        // P-INST-77: hook 配置同步总耗时（启动 AppDelegate:71 + hook 偏好变更时；含 writeConfigFile + installHelperScript + installHookToClaudeSettings 三文件 I/O + server start；@MainActor 同步阻塞 UI；memory feedback_hook_toggle_sync 铁律要求 hook toggle 同步 settings.json）。
        let startedAt = Date()
        if ClaudeHookPreferences.isEnabled {
            ClaudeHookPreferences.ensureTokenGenerated()
            startIfNeeded(port: ClaudeHookPreferences.listenPort, token: ClaudeHookPreferences.authToken)
            // 确保辅助脚本的配置文件（端口 + token）与当前 UserDefaults 同步
            // 防止 app 重启后 token 重新生成导致 hook-config.json 中的旧 token 失效
            ClaudeHookPreferences.writeConfigFile()
            ClaudeHookPreferences.installHelperScript()
            _ = ClaudeHookPreferences.installHookToClaudeSettings()
        } else {
            stop()
        }
        // B171: 远程 spool 拉取器随 hook 开关同启停（VPN/单向网络下远程事件
        // 的唯一通道；无注册主机时内部自判定不轮询）。
        RemoteSpoolDrainer.shared.applyPreferences()
        logOperationDuration("[ClaudeHookServer] applyPreferences finished", startedAt: startedAt, warnThresholdMs: 200)
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        activePort = nil
        configuredToken = nil
        configuredBindToLocalhost = nil
        statusDescription = "未启动"
    }

    /// 测试注入缝（B154）：HTTP 壳回环直测须显式起服。⚠️ 生产入口是 applyPreferences()；
    /// 测试严禁调用 applyPreferences——它会写真实 ~/.vibefocus 配置与 settings.json。
    func startIfNeeded(port: Int, token: String?) {
        let bindToLocalhost = !LANHookPreferences.lanMode
        if !Self.serverNeedsRestart(
            isRunning: isRunning,
            activePort: activePort,
            configuredToken: configuredToken,
            configuredBindToLocalhost: configuredBindToLocalhost,
            port: port,
            token: token,
            bindToLocalhost: bindToLocalhost
        ) {
            return
        }
        stop()

        guard port >= 1024, port <= 65535 else {
            isRunning = false
            statusDescription = "端口无效"
            lastErrorMessage = "Invalid port: \(port)"
            return
        }

        let webServer = GCDWebServer()

        webServer.addHandler(
            forMethod: "POST",
            path: ClaudeHookPreferences.endpointPath,
            request: GCDWebServerDataRequest.self,
            asyncProcessBlock: { [weak self] request, completionBlock in
                Task { @MainActor in
                    guard let self else {
                        let body = Data("{\"ok\":false,\"code\":\"server_error\"}".utf8)
                        let r = GCDWebServerDataResponse(data: body, contentType: "application/json")
                        r.statusCode = 500
                        completionBlock(r)
                        return
                    }

                    guard let dataRequest = request as? GCDWebServerDataRequest else {
                        completionBlock(
                            self.makeJSONResponse(
                                statusCode: 400,
                                response: ClaudeHookResponse(
                                    ok: false, code: "bad_request",
                                    message: "Invalid request body",
                                    sessionID: nil, handled: false
                                )
                            )
                        )
                        return
                    }

                    let result = await self.handleHookRequest(
                        body: dataRequest.data,
                        query: request.query ?? [:],
                        headers: request.headers,
                        peerAddress: request.remoteAddressString as String?
                    )
                    completionBlock(
                        self.makeJSONResponse(statusCode: result.statusCode, response: result.response)
                    )
                }
            }
        )

        do {
            try webServer.start(options: [
                GCDWebServerOption_Port: UInt(port),
                GCDWebServerOption_BindToLocalhost: bindToLocalhost
            ])
            self.server = webServer
            self.activePort = port
            self.configuredToken = token
            self.configuredBindToLocalhost = bindToLocalhost
            self.isRunning = true
            let bindAddr = bindToLocalhost ? "127.0.0.1" : "0.0.0.0"
            self.statusDescription = "监听中 \(bindAddr):\(port)"
            self.lastErrorMessage = nil
            log("[ClaudeHookServer] listening on \(bindAddr):\(port)")
            NotificationCenter.default.post(name: .hookServerStateChanged, object: nil)
        } catch {
            isRunning = false
            statusDescription = "启动失败"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] failed to start: \(error.localizedDescription)")
        }
    }
}
