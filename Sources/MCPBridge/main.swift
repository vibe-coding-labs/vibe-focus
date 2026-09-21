// VibeFocusMCP — MCP stdio 桥（design-agent-access.md 通道③）。
// 由 agent host（claude code / codex / ZCode）作为 MCP server 拉起：
// stdin 收 JSON-RPC（行分隔），翻译成对 VibeFocus app 命令 API 的 curl 调用，
// stdout 回包。协议与工具目录在 VibeFocusKit/MCPProtocol（Runner 直测），
// 本文件只做 stdio 循环与 HTTP 传输壳。

import Foundation
import VibeFocusKit

let connection = AgentCLIConnection.load()

/// curl 同步执行（桥进程私有，走 Process；与 Kit/ShellRunner 语义对齐但零耦合）。
private func runCurl(_ args: [String], timeout: TimeInterval) -> (exitCode: Int32, stdout: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = args
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
        try process.run()
    } catch {
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        if Date() > deadline, process.isRunning {
            process.terminate()
        }
    }
    defer { timer.invalidate() }
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: stdoutData, encoding: .utf8) ?? "")
}

/// 对 App 命令 API 的同步调用（curl 子进程，与 hook-forwarder.sh 同款通道）。
func performAPI(method: String, path: String, body: Data?) -> (httpStatus: Int, body: Data) {
    var args = [
        "-s", "--max-time", "40",
        "-X", method,
        "-H", "X-VibeFocus-Token: \(connection.token ?? "")",
        "-w", "\n%{http_code}"
    ]
    if let body {
        let text = String(data: body, encoding: .utf8) ?? "{}"
        args += ["-H", "Content-Type: application/json", "-d", text]
    }
    args.append("http://127.0.0.1:\(connection.port)\(path)")

    guard let result = runCurl(args, timeout: 45), result.exitCode == 0 else {
        let unreachable = "{\"ok\":false,\"code\":\"app_unreachable\",\"message\":\"VibeFocus app 不可达（未在运行或未启用 Agent 接入）\"}"
        return (0, Data(unreachable.utf8))
    }
    let output = result.stdout
    var jsonPart = output
    var statusPart = ""
    if let lastNewline = output.lastIndex(of: "\n") {
        statusPart = String(output[output.index(after: lastNewline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        jsonPart = String(output[..<lastNewline])
    }
    let status = Int(statusPart) ?? 500
    return (status, Data(jsonPart.utf8))
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    if let response = MCPProtocol.handleMessage(Data(line.utf8), performAPI: performAPI) {
        print(String(data: response, encoding: .utf8) ?? "{}")
        fflush(stdout)
    }
}
