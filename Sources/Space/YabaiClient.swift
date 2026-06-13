import Foundation

/// Client for communicating with yabai via its UNIX socket API.
@MainActor
enum YabaiClient {

    private static var cachedPath: String?

    static let commandTimeout: TimeInterval = 2.0

    /// 后台串行队列 — yabai 只读查询专用，避免阻塞主线程。
    /// 串行保证 query 顺序一致；仅用于只读（query --spaces/--displays/--space）。
    /// toggle 后 overlay force refresh 的 yabai 查询在此队列执行，space 切换后
    /// yabai 卡顿也不会冻结主线程（实测 restore 后 force refresh 阻塞主线程 ~2s 的根因）。
    private nonisolated static let yabaiExecutionQueue = DispatchQueue(
        label: "vibefocus.yabai.query",
        qos: .userInitiated
    )

    /// 获取 yabai 可执行文件路径（带缓存 + shell fallback）
    static func yabaiPath() -> String? {
        if let cached = cachedPath, FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        // 1. 检查常见安装路径
        let candidates = [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
            "/bin/yabai",
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

        // 2. Fallback: 通过用户 shell 环境查找
        if let shellPath = findViaUserShell() {
            cachedPath = shellPath
            return shellPath
        }

        // 3. Fallback: 通过 bash -l which 查找
        if let whichPath = findViaBashWhich() {
            cachedPath = whichPath
            return whichPath
        }

        return nil
    }

    private static func findViaUserShell() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["bash", "-l", "-c", "echo $SHELL"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let shell = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let shell, !shell.isEmpty else { return nil }
            let whichTask = Process()
            whichTask.launchPath = shell
            whichTask.arguments = ["-l", "-c", "which yabai"]
            let whichPipe = Pipe()
            whichTask.standardOutput = whichPipe
            whichTask.standardError = Pipe()
            try whichTask.run()
            whichTask.waitUntilExit()
            guard whichTask.terminationStatus == 0 else { return nil }
            let whichData = whichPipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: whichData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }

    private static func findViaBashWhich() -> String? {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-l", "-c", "which yabai"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }

    struct YabaiResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// 进程执行核心 — nonisolated，可在任意线程调用，不访问 @MainActor 状态。
    /// 调用方负责解析 yabaiPath 后传入（写操作走主线程 run，读路径走后台 runAsync）。
    private nonisolated static func execute(
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> YabaiResult? {
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
            let waitResult = sem.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
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

    /// 执行 yabai 命令（带超时）— 主线程同步，用于写操作
    /// （window --move/--focus/--space 等有时序依赖，[[space_switch_regression]]）。
    static func run(arguments: [String]) -> YabaiResult? {
        guard let path = yabaiPath() else { return nil }
        return execute(path: path, arguments: arguments, timeout: commandTimeout)
    }

    /// 异步执行 yabai 命令 — 在后台串行队列执行，不阻塞主线程。
    ///
    /// 仅用于**只读查询**（`query --spaces` / `query --displays` / `query --space`）。
    /// yabai 写操作有时序依赖，必须用同步 `run()`。
    /// 消除 toggle 后 overlay force refresh 的主线程阻塞：space 切换后 yabai 查询
    /// 可能卡顿接近 2s timeout，同步调用会冻结 UI（实测 restore 后阻塞 2.18s）。
    static func runAsync(arguments: [String]) async -> YabaiResult? {
        guard let path = yabaiPath() else { return nil }
        let timeout = commandTimeout
        return await withCheckedContinuation { continuation in
            yabaiExecutionQueue.async {
                let result = execute(path: path, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }

    /// 执行 yabai 命令并解码 JSON 输出（同步）
    static func queryJSON<T: Decodable>(_ type: T.Type, arguments: [String]) -> T? {
        guard let result = run(arguments: arguments), result.exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.stdout.utf8))
    }

    /// 异步执行 yabai 查询并解码 JSON — 用于读路径的 Space/Display 查询。
    static func queryJSONAsync<T: Decodable>(_ type: T.Type, arguments: [String]) async -> T? {
        guard let result = await runAsync(arguments: arguments), result.exitCode == 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(result.stdout.utf8))
    }
}
