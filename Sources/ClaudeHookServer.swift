import Foundation
import Network

@MainActor
final class ClaudeHookServer: ObservableObject {
    static let shared = ClaudeHookServer()

    @Published private(set) var isRunning = false
    @Published private(set) var statusDescription = "未启动"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var totalRequestCount = 0
    @Published private(set) var handledRequestCount = 0
    @Published private(set) var unmatchedSessionCount = 0

    private var listener: NWListener?
    private var activePort: Int?
    private var configuredToken: String?
    private let maxRequestSize = 64 * 1024
    private let receiveChunkSize = 8 * 1024

    private init() {}

    func applyPreferences() {
        if ClaudeHookPreferences.isEnabled {
            startIfNeeded(port: ClaudeHookPreferences.listenPort, token: ClaudeHookPreferences.authToken)
        } else {
            stop()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        activePort = nil
        configuredToken = nil
        statusDescription = "未启动"
    }

    private func startIfNeeded(port: Int, token: String?) {
        if isRunning, activePort == port, configuredToken == token {
            return
        }
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            isRunning = false
            statusDescription = "端口无效"
            lastErrorMessage = "Invalid port: \(port)"
            return
        }

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state, port: port)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.activePort = port
            self.configuredToken = token
            self.statusDescription = "启动中..."
            self.lastErrorMessage = nil
        } catch {
            isRunning = false
            statusDescription = "启动失败"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] failed to start: \(error.localizedDescription)")
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready:
            isRunning = true
            statusDescription = "监听中 127.0.0.1:\(port)"
            lastErrorMessage = nil
            log("[ClaudeHookServer] listening on 127.0.0.1:\(port)")
        case .failed(let error):
            isRunning = false
            statusDescription = "监听失败"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] listener failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
            statusDescription = "未启动"
        case .waiting(let error):
            isRunning = false
            statusDescription = "等待中"
            lastErrorMessage = error.localizedDescription
            log("[ClaudeHookServer] listener waiting: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        guard isLoopbackEndpoint(connection.endpoint) else {
            log("[ClaudeHookServer] rejected non-loopback peer: \(connection.endpoint)")
            sendResponse(
                on: connection,
                statusCode: 403,
                response: ClaudeHookResponse(
                    ok: false,
                    code: "forbidden_remote",
                    message: "Only loopback connections are allowed",
                    sessionID: nil,
                    handled: false
                )
            )
            return
        }
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunkSize) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let error {
                    self.sendResponse(
                        on: connection,
                        statusCode: 500,
                        response: ClaudeHookResponse(
                            ok: false,
                            code: "connection_error",
                            message: error.localizedDescription,
                            sessionID: nil,
                            handled: false
                        )
                    )
                    return
                }

                var accumulated = buffer
                if let data, !data.isEmpty {
                    accumulated.append(data)
                }

                if accumulated.count > self.maxRequestSize {
                    self.sendResponse(
                        on: connection,
                        statusCode: 413,
                        response: ClaudeHookResponse(
                            ok: false,
                            code: "payload_too_large",
                            message: "Request payload exceeds limit",
                            sessionID: nil,
                            handled: false
                        )
                    )
                    return
                }

                switch self.parseRequest(accumulated) {
                case .complete(let request):
                    let result = self.handleRequest(request)
                    self.sendResponse(on: connection, statusCode: result.statusCode, response: result.response)

                case .needsMoreData:
                    if isComplete {
                        self.sendResponse(
                            on: connection,
                            statusCode: 400,
                            response: ClaudeHookResponse(
                                ok: false,
                                code: "incomplete_request",
                                message: "Incomplete HTTP request payload",
                                sessionID: nil,
                                handled: false
                            )
                        )
                    } else {
                        self.receiveRequest(on: connection, buffer: accumulated)
                    }

                case .invalid(let message):
                    self.sendResponse(
                        on: connection,
                        statusCode: 400,
                        response: ClaudeHookResponse(
                            ok: false,
                            code: "bad_request",
                            message: message,
                            sessionID: nil,
                            handled: false
                        )
                    )
                }
            }
        }
    }

    private func handleRequest(_ request: ParsedHTTPRequest) -> (statusCode: Int, response: ClaudeHookResponse) {
        let path = request.path.components(separatedBy: "?").first ?? request.path
        guard path == ClaudeHookPreferences.endpointPath else {
            return (
                404,
                ClaudeHookResponse(
                    ok: false,
                    code: "not_found",
                    message: "Unknown endpoint \(path)",
                    sessionID: nil,
                    handled: false
                )
            )
        }

        guard request.method == "POST" else {
            return (
                405,
                ClaudeHookResponse(
                    ok: false,
                    code: "method_not_allowed",
                    message: "Only POST is supported",
                    sessionID: nil,
                    handled: false
                )
            )
        }

        if let expectedToken = configuredToken, !expectedToken.isEmpty {
            let token = request.headers["x-vibefocus-token"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard token == expectedToken else {
                return (
                    401,
                    ClaudeHookResponse(
                        ok: false,
                        code: "unauthorized",
                        message: "Missing or invalid hook token",
                        sessionID: nil,
                        handled: false
                    )
                )
            }
        }

        totalRequestCount += 1

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(ClaudeHookPayload.self, from: request.body) else {
            return (
                400,
                ClaudeHookResponse(
                    ok: false,
                    code: "invalid_payload",
                    message: "JSON payload must contain event and session_id",
                    sessionID: nil,
                    handled: false
                )
            )
        }

        lastEventAt = Date()
        switch payload.event {
        case .sessionStart:
            guard let identity = WindowManager.shared.captureFocusedWindowIdentity() else {
                SessionWindowRegistry.shared.setLastEventDescription("SessionStart 失败：当前无可绑定窗口")
                return (
                    409,
                    ClaudeHookResponse(
                        ok: false,
                        code: "window_not_found",
                        message: "No focused window available for session binding",
                        sessionID: payload.sessionID,
                        handled: false
                    )
                )
            }
            SessionWindowRegistry.shared.bind(sessionID: payload.sessionID, windowIdentity: identity)
            handledRequestCount += 1
            return (
                200,
                ClaudeHookResponse(
                    ok: true,
                    code: "session_bound",
                    message: "Session bound to focused window",
                    sessionID: payload.sessionID,
                    handled: true
                )
            )

        case .sessionEnd:
            guard ClaudeHookPreferences.autoFocusOnSessionEnd else {
                SessionWindowRegistry.shared.touch(
                    sessionID: payload.sessionID,
                    message: "SessionEnd 收到（自动聚焦已关闭）"
                )
                handledRequestCount += 1
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true,
                        code: "auto_focus_disabled",
                        message: "SessionEnd received, auto focus disabled",
                        sessionID: payload.sessionID,
                        handled: false
                    )
                )
            }

            guard let binding = SessionWindowRegistry.shared.binding(for: payload.sessionID) else {
                unmatchedSessionCount += 1
                SessionWindowRegistry.shared.setLastEventDescription("SessionEnd 未命中绑定：\(payload.sessionID)")
                return (
                    404,
                    ClaudeHookResponse(
                        ok: false,
                        code: "binding_not_found",
                        message: "No bound window for session",
                        sessionID: payload.sessionID,
                        handled: false
                    )
                )
            }

            if binding.isCompleted {
                handledRequestCount += 1
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true,
                        code: "already_completed",
                        message: "Session already completed",
                        sessionID: payload.sessionID,
                        handled: false
                    )
                )
            }

            let moved = WindowManager.shared.moveWindowToMainScreen(
                identity: binding.windowIdentity,
                reason: .claudeSessionEnd,
                sessionID: payload.sessionID
            )
            if moved {
                SessionWindowRegistry.shared.markCompleted(sessionID: payload.sessionID)
                handledRequestCount += 1
                return (
                    200,
                    ClaudeHookResponse(
                        ok: true,
                        code: "window_focused",
                        message: "Window moved to main screen and maximized",
                        sessionID: payload.sessionID,
                        handled: true
                    )
                )
            }

            SessionWindowRegistry.shared.touch(
                sessionID: payload.sessionID,
                message: "SessionEnd 命中绑定，但移动窗口失败"
            )
            return (
                409,
                ClaudeHookResponse(
                    ok: false,
                    code: "window_move_failed",
                    message: "Found session binding but failed to move window",
                    sessionID: payload.sessionID,
                    handled: false
                )
            )
        }
    }

    private func sendResponse(on connection: NWConnection, statusCode: Int, response: ClaudeHookResponse) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = (try? encoder.encode(response)) ?? Data("{\"ok\":false}".utf8)
        let reason = statusReason(for: statusCode)
        let header = """
HTTP/1.1 \(statusCode) \(reason)\r
Content-Type: application/json\r
Content-Length: \(bodyData.count)\r
Connection: close\r
\r
"""

        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusReason(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        default: return "Internal Server Error"
        }
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private enum ParsedRequestResult {
        case complete(ParsedHTTPRequest)
        case needsMoreData
        case invalid(String)
    }

    private func parseRequest(_ data: Data) -> ParsedRequestResult {
        let separatorData = Data("\r\n\r\n".utf8)
        guard let splitRange = data.range(of: separatorData) else {
            return .needsMoreData
        }

        let headerData = data.subdata(in: 0..<splitRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .invalid("HTTP header is not valid UTF-8")
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return .invalid("Missing HTTP request line")
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return .invalid("Invalid HTTP request line")
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength: Int
        if let contentLengthRaw = headers["content-length"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contentLengthRaw.isEmpty {
            guard let parsedLength = Int(contentLengthRaw), parsedLength >= 0 else {
                return .invalid("Invalid Content-Length header")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        let bodyStart = splitRange.upperBound
        let availableBodyCount = data.count - bodyStart
        if availableBodyCount < contentLength {
            return .needsMoreData
        }

        let bodyEnd = bodyStart + contentLength
        let body = data.subdata(in: bodyStart..<bodyEnd)

        return .complete(ParsedHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        ))
    }

    private func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        let raw = String(describing: host)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return raw == "localhost"
            || raw == "::1"
            || raw == "0:0:0:0:0:0:0:1"
            || raw.hasPrefix("127.")
            || raw.contains("127.0.0.1")
    }
}
