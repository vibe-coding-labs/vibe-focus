import Foundation

/// yabai 进程调用统一抽象 — 单一 yabai 路径缓存和超时控制
@MainActor
enum YabaiClient {

    private static var cachedPath: String?

    static let commandTimeout: TimeInterval = 2.0

    /// 获取 yabai 可执行文件路径（带缓存）
    static func yabaiPath() -> String? {
        if let cached = cachedPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let candidates = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent("bin/yabai"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin/yabai")
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                cachedPath = path
                return path
            }
        }
        return nil
    }

    struct YabaiResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// 执行 yabai 命令（带超时）
    static func run(arguments: [String]) -> YabaiResult? {
        guard let path = yabaiPath() else { return nil }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            let sem = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in sem.signal() }
            let result = sem.wait(timeout: .now() + commandTimeout)
            if result == .timedOut {
                task.terminate()
                return nil
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return YabaiResult(
                exitCode: task.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return nil
        }
    }

    /// 执行 yabai 命令并解码 JSON 输出
    static func queryJSON<T: Decodable>(_ type: T.Type, arguments: [String]) -> T? {
        guard let result = run(arguments: arguments), result.exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.stdout.utf8))
    }
}
